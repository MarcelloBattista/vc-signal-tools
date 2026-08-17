# frozen_string_literal: true

require_relative "transcript_service"
require_relative "insight_extraction_service"
require_relative "ranking_service"
require_relative "clustering_service"
require_relative "analysis_service"

module VCTools
  module Podcast
    # Runs the full transcribe -> extract -> rank -> cluster -> analyze chain for
    # up to `limit` episodes at each stage. Shared by bin/run_podcast_pipeline's main
    # flow and its backfill loop so the two call sites can't drift out of sync as
    # stages are added/changed.
    class PipelineRunner
      def self.run_stage_chain(limit:)
        puts "--- Transcribe ---"
        TranscriptService.new.run(limit: limit)

        puts "--- Extract Insights ---"
        InsightExtractionService.new.run(limit: limit)

        puts "--- Rank Insights ---"
        RankingService.new.run(limit: limit)

        puts "--- Cluster Insights ---"
        ClusteringService.new.run(limit: limit)

        puts "--- Generate Summaries ---"
        AnalysisService.new.run(limit: limit)
      end
    end
  end
end
