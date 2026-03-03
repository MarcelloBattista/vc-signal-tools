# frozen_string_literal: true

require "tempfile"
require "open-uri"
require "shellwords"
require "time"

require_relative "database"

module VCTools
  module Podcast
    class TranscriptService

      WHISPER_MODEL = File.expand_path("~/.whisper/models/ggml-base.en.bin")
      WHISPER_CMD   = "whisper-cli"
      CHUNK_WORDS   = 350  # ~500 tokens per chunk

      def initialize
        @db          = VCTools::Podcast::Database.connect
        @episodes    = @db[:episodes]
        @transcripts = @db[:transcripts]
        @chunks      = @db[:transcript_chunks]
      end

      def run(limit: nil)
        pending = diverse_episodes("new", limit)
        puts "[Transcript] #{pending.length} episodes to process"

        pending.each { |episode| process_episode(episode) }
      end

      private

      # Pick episodes evenly across podcasts so one feed doesn't dominate
      def diverse_episodes(status, limit)
        all = @episodes.where(status: status).order(:published_at).all
        return all unless limit && all.length > limit

        grouped = all.group_by { |ep| ep[:podcast_id] }
        result  = []
        per_pod = (limit / grouped.keys.length.to_f).ceil

        grouped.each_value do |eps|
          result.concat(eps.first(per_pod))
        end

        result.sort_by { |ep| ep[:published_at] }.first(limit)
      end

      def process_episode(episode)
        puts "[Transcript] Processing: #{episode[:title]}"
        audio_path = nil
        wav_path   = nil

        audio_path = download_audio(episode[:audio_url])
        return update_status(episode[:id], "failed") unless audio_path

        wav_path = convert_to_wav(audio_path)
        return update_status(episode[:id], "failed") unless wav_path

        raw_text = transcribe(wav_path)
        return update_status(episode[:id], "failed") unless raw_text

        store_transcript(episode[:id], raw_text)
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

      def transcribe(wav_path)
        cmd    = "#{WHISPER_CMD} -m #{WHISPER_MODEL.shellescape} #{wav_path.shellescape} 2>/dev/null"
        output = `#{cmd}`
        return nil if output.nil? || output.strip.empty?

        # Strip timestamp prefix from each line: [00:00:00.000 --> 00:00:05.000]   Text
        output.lines
              .map  { |line| line.sub(/^\[[\d:\.]+\s*-->\s*[\d:\.]+\]\s*/, "").strip }
              .reject(&:empty?)
              .join(" ")

      rescue => e
        puts "[Transcript] Transcription failed: #{e.message}"
        nil
      end

      def store_transcript(episode_id, raw_text)
        now            = Time.now.utc
        token_estimate = (raw_text.length / 4.0).ceil

        transcript_id = @transcripts.insert(
          episode_id:     episode_id,
          provider:       "local",
          engine:         "local",
          model:          "whisper-base.en",
          language:       "en",
          raw_text:       raw_text,
          token_estimate: token_estimate,
          created_at:     now
        )

        store_chunks(transcript_id, raw_text)
      end

      def store_chunks(transcript_id, text)
        words = text.split
        words.each_slice(CHUNK_WORDS).with_index do |chunk_words, index|
          chunk_text = chunk_words.join(" ")
          @chunks.insert(
            transcript_id:  transcript_id,
            chunk_index:    index,
            text:           chunk_text,
            token_estimate: (chunk_text.length / 4.0).ceil
          )
        end
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
