# frozen_string_literal: true

require "json"
require "time"

require_relative "database"
require_relative "episode_selection"
require_relative "gemini_client"
require_relative "investment_context"
require_relative "insight_extraction_prompt"

module VCTools
  module Podcast
    # Stage 1 of 4: pulls atomic, individually-scored observations out of a transcript.
    # Deliberately does NOT decide what's worth surfacing in the final digest — that's
    # RankingService/ClusteringService/AnalysisService's job. See vc_podcast_summarizer_ranking_system.md.
    class InsightExtractionService

      GEMINI_MODEL = "gemini-2.5-flash"
      VALID_TYPES  = InsightExtractionPrompt::VALID_TYPES

      def initialize
        @db          = VCTools::Podcast::Database.connect
        @episodes    = @db[:episodes]
        @transcripts = @db[:transcripts]
        @chunks      = @db[:transcript_chunks]
        @insights    = @db[:episode_insights]
        @companies   = @db[:companies]
        @sectors     = @db[:sectors]
        @insight_companies = @db[:episode_insight_companies]
        @insight_sectors   = @db[:episode_insight_sectors]

        require "dotenv/load"
        # Longest input (full transcript) and largest output (up to 60 structured
        # observations) of any stage — long episodes can exceed the default timeout.
        @gemini = VCTools::Podcast::GeminiClient.new(model: GEMINI_MODEL, timeout: 240)
      end

      def run(limit: nil)
        unless @gemini.api_key?
          puts "[Insights] No GEMINI_API_KEY set — skipping"
          return
        end

        pending = VCTools::Podcast::EpisodeSelection.diverse(@episodes, status: "transcribed", limit: limit)
        puts "[Insights] #{pending.length} episodes to process"

        pending.each { |episode| extract_episode(episode) }
      end

      private

      def extract_episode(episode)
        puts "[Insights] Extracting: #{episode[:title]}"

        transcript = @transcripts.where(episode_id: episode[:id]).first
        unless transcript
          puts "[Insights] No transcript for episode #{episode[:id]}"
          return update_status(episode[:id], "failed", "insights_extracted")
        end

        chunks = @chunks.where(transcript_id: transcript[:id]).order(:chunk_index).all
        if chunks.empty?
          puts "[Insights] No chunks for transcript #{transcript[:id]}"
          return update_status(episode[:id], "failed", "insights_extracted")
        end

        full_text = chunks.map { |c| c[:text] }.join("\n\n")

        result = extract(episode[:title], full_text)
        return update_status(episode[:id], "failed", "insights_extracted") unless result

        store_insights(episode[:id], result["insights"])
        update_status(episode[:id], "insights_extracted", nil)
        puts "[Insights] Done: #{episode[:title]} (#{result['insights'].length} observations)"

      rescue => e
        puts "[Insights] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed", "insights_extracted")
      end

      def extract(episode_title, transcript_text)
        prompt = InsightExtractionPrompt.build(episode_title: episode_title, transcript_text: transcript_text)

        @gemini.generate_json(prompt, max_output_tokens: 32_768) do |result|
          result["insights"].is_a?(Array) && !result["insights"].empty?
        end
      end

      def store_insights(episode_id, insights)
        now = Time.now.utc

        insights.each do |obs|
          next unless obs.is_a?(Hash)

          claim = obs["claim"].to_s
          next if claim.strip.empty?

          insight_type = VALID_TYPES.include?(obs["type"]) ? obs["type"] : "insight"

          insight_id = @insights.insert(
            episode_id:            episode_id,
            insight_uid:           obs["id"].to_s,
            insight_type:          insight_type,
            speaker_label:         obs["speaker"],
            category:              obs["category"],
            claim:                 claim,
            evidence:              obs["evidence"],
            implication:           obs["implication"],
            timestamp_start_ms:    parse_timestamp(obs["timestamp_start"]),
            timestamp_end_ms:      parse_timestamp(obs["timestamp_end"]),
            people_json:           Array(obs["people"]).to_json,
            metrics_json:          Array(obs["metrics"]).to_json,
            score_importance:      clamp_score(obs["importance"]),
            score_novelty:         clamp_score(obs["novelty"]),
            score_specificity:     clamp_score(obs["specificity"]),
            score_actionability:   clamp_score(obs["actionability"]),
            score_credibility:     clamp_score(obs["credibility"]),
            created_at:            now
          )

          link_companies(insight_id, Array(obs["companies"]))
          link_sectors(insight_id, Array(obs["sectors"]))
        end
      end

      def link_companies(insight_id, names)
        names.each do |name|
          next if name.to_s.strip.empty?
          company_id = find_or_create(@companies, name)
          @insight_companies.insert(insight_id: insight_id, company_id: company_id)
        end
      end

      def link_sectors(insight_id, names)
        names.each do |name|
          next if name.to_s.strip.empty?
          sector_id = find_or_create(@sectors, name)
          @insight_sectors.insert(insight_id: insight_id, sector_id: sector_id)
        end
      end

      def find_or_create(table, name)
        normalized = normalize(name)
        return nil if normalized.empty?

        existing = table.where(normalized_name: normalized).first
        return existing[:id] if existing

        now = Time.now.utc
        table.insert(name: name.to_s.strip, normalized_name: normalized, created_at: now, updated_at: now)
      end

      def normalize(name)
        name.to_s.downcase.strip.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
      end

      def parse_timestamp(ts)
        return nil if ts.nil?
        parts = ts.to_s.strip.split(":")
        return nil if parts.empty? || parts.any? { |p| p !~ /\A\d+(\.\d+)?\z/ }

        parts = parts.map(&:to_f)
        seconds = case parts.length
                  when 1 then parts[0]
                  when 2 then parts[0] * 60 + parts[1]
                  when 3 then parts[0] * 3600 + parts[1] * 60 + parts[2]
                  else return nil
                  end
        (seconds * 1000).round
      end

      def clamp_score(value)
        return nil unless value.is_a?(Numeric)
        value.to_i.clamp(0, 5)
      end

      def update_status(episode_id, status, failed_stage)
        @episodes.where(id: episode_id).update(
          status:       status,
          failed_stage: failed_stage,
          updated_at:   Time.now.utc
        )
      end

    end
  end
end
