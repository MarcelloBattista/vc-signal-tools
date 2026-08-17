# frozen_string_literal: true

require "tempfile"
require "open-uri"
require "shellwords"
require "time"

require_relative "database"
require_relative "episode_selection"

module VCTools
  module Podcast
    class TranscriptService

      WHISPER_MODEL = File.expand_path("~/.whisper/models/ggml-base.en.bin")
      WHISPER_CMD   = "whisper-cli"
      CHUNK_WORDS   = 350  # ~500 tokens per chunk
      SEGMENT_RE    = /^\[(?<start>[\d:.]+)\s*-->\s*(?<end>[\d:.]+)\]\s*(?<text>.*)$/

      def initialize
        @db          = VCTools::Podcast::Database.connect
        @episodes    = @db[:episodes]
        @transcripts = @db[:transcripts]
        @chunks      = @db[:transcript_chunks]
      end

      def run(limit: nil)
        pending = VCTools::Podcast::EpisodeSelection.diverse(@episodes, status: "new", limit: limit)
        puts "[Transcript] #{pending.length} episodes to process"

        pending.each { |episode| process_episode(episode) }
      end

      private

      def process_episode(episode)
        puts "[Transcript] Processing: #{episode[:title]}"
        audio_path = nil
        wav_path   = nil

        audio_path = download_audio(episode[:audio_url])
        return update_status(episode[:id], "failed") unless audio_path

        wav_path = convert_to_wav(audio_path)
        return update_status(episode[:id], "failed") unless wav_path

        segments = transcribe(wav_path)
        return update_status(episode[:id], "failed") unless segments && !segments.empty?

        store_transcript(episode[:id], segments)
        update_status(episode[:id], "transcribed")
        puts "[Transcript] Done: #{episode[:title]}"

      rescue => e
        puts "[Transcript] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed")
      ensure
        File.delete(audio_path) if audio_path && File.exist?(audio_path)
        File.delete(wav_path)   if wav_path   && File.exist?(wav_path)
      end

      def download_audio(url)
        return nil if url.nil?

        tmp = Tempfile.new(["episode", ".mp3"])
        tmp.binmode
        URI.open(url) { |f| tmp.write(f.read) }
        tmp.close
        tmp.path

      rescue => e
        puts "[Transcript] Download failed: #{e.message}"
        nil
      end

      def convert_to_wav(mp3_path)
        wav_path = mp3_path.sub(/\.\w+$/, ".wav")
        cmd = "ffmpeg -y -i #{mp3_path.shellescape} -ar 16000 -ac 1 #{wav_path.shellescape} 2>/dev/null"
        system(cmd)
        File.exist?(wav_path) ? wav_path : nil

      rescue => e
        puts "[Transcript] Conversion failed: #{e.message}"
        nil
      end

      # Returns whisper-cli's output as an array of {start_ms:, end_ms:, text:} segments,
      # preserving timestamps instead of discarding them, so downstream stages can ground
      # claims/insights in real audio offsets.
      def transcribe(wav_path)
        cmd    = "#{WHISPER_CMD} -m #{WHISPER_MODEL.shellescape} #{wav_path.shellescape} 2>/dev/null"
        output = `#{cmd}`
        return nil if output.nil? || output.strip.empty?

        output.lines.filter_map do |line|
          m = line.match(SEGMENT_RE)
          next unless m
          text = m[:text].strip
          next if text.empty?

          { start_ms: timestamp_to_ms(m[:start]), end_ms: timestamp_to_ms(m[:end]), text: text }
        end

      rescue => e
        puts "[Transcript] Transcription failed: #{e.message}"
        nil
      end

      # "00:12:34.500" -> milliseconds
      def timestamp_to_ms(ts)
        h, m, s = ts.split(":")
        ((h.to_i * 3600 + m.to_i * 60 + s.to_f) * 1000).round
      end

      def store_transcript(episode_id, segments)
        now      = Time.now.utc
        raw_text = segments.map { |s| s[:text] }.join(" ")

        transcript_id = @transcripts.insert(
          episode_id:     episode_id,
          provider:       "local",
          engine:         "local",
          model:          "whisper-base.en",
          language:       "en",
          raw_text:       raw_text,
          token_estimate: (raw_text.length / 4.0).ceil,
          created_at:     now
        )

        store_chunks(transcript_id, segments)
      end

      # Groups whole segments (not raw words) into ~CHUNK_WORDS-sized chunks so chunk
      # boundaries land on segment boundaries. Each chunk's text keeps inline [MM:SS]
      # timestamp markers so later stages can cite real offsets without re-deriving them.
      def store_chunks(transcript_id, segments)
        groups = []
        current = []
        current_words = 0

        segments.each do |seg|
          current << seg
          current_words += seg[:text].split.length

          if current_words >= CHUNK_WORDS
            groups << current
            current = []
            current_words = 0
          end
        end
        groups << current unless current.empty?

        groups.each_with_index do |group, index|
          chunk_text = group.map { |s| "[#{format_mmss(s[:start_ms])}] #{s[:text]}" }.join(" ")

          @chunks.insert(
            transcript_id:  transcript_id,
            chunk_index:    index,
            text:           chunk_text,
            token_estimate: (chunk_text.length / 4.0).ceil,
            start_ms:       group.first[:start_ms],
            end_ms:         group.last[:end_ms]
          )
        end
      end

      # milliseconds -> "MM:SS" (or "H:MM:SS" past an hour)
      def format_mmss(ms)
        total_seconds = (ms / 1000).to_i
        h = total_seconds / 3600
        m = (total_seconds % 3600) / 60
        s = total_seconds % 60
        h.positive? ? format("%d:%02d:%02d", h, m, s) : format("%02d:%02d", m, s)
      end

      def update_status(episode_id, status)
        @episodes.where(id: episode_id).update(
          status:     status,
          updated_at: Time.now.utc
        )
      end

    end
  end
end
