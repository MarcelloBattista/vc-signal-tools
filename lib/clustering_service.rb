# frozen_string_literal: true

require "json"
require "time"

require_relative "database"
require_relative "episode_selection"
require_relative "gemini_client"

module VCTools
  module Podcast
    # Stage 3 of 4: clusters semantically similar ranked insights into higher-level
    # themes, so near-duplicate observations don't each surface individually in the
    # final summary just because each scored well on its own.
    class ClusteringService

      GEMINI_MODEL = "gemini-2.5-flash"

      def initialize
        @db       = VCTools::Podcast::Database.connect
        @episodes = @db[:episodes]
        @insights = @db[:episode_insights]
        @clusters = @db[:episode_insight_clusters]

        require "dotenv/load"
        @gemini = VCTools::Podcast::GeminiClient.new(model: GEMINI_MODEL)
      end

      def run(limit: nil)
        unless @gemini.api_key?
          puts "[Clustering] No GEMINI_API_KEY set — skipping"
          return
        end

        pending = VCTools::Podcast::EpisodeSelection.diverse(@episodes, status: "ranked", limit: limit)
        puts "[Clustering] #{pending.length} episodes to process"

        pending.each { |episode| cluster_episode(episode) }
      end

      private

      def cluster_episode(episode)
        puts "[Clustering] Clustering: #{episode[:title]}"

        insights = @insights.where(episode_id: episode[:id]).order(Sequel.desc(:ranking_score)).all
        if insights.empty?
          puts "[Clustering] No insights for episode #{episode[:id]}"
          return update_status(episode[:id], "failed", "clustered")
        end

        result = cluster(episode[:title], insights)
        return update_status(episode[:id], "failed", "clustered") unless result

        store_clusters(episode[:id], insights, result["clusters"])
        update_status(episode[:id], "clustered", nil)
        puts "[Clustering] Done: #{episode[:title]}"

      rescue => e
        puts "[Clustering] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed", "clustered")
      end

      def cluster(episode_title, insights)
        observations = insights.map do |i|
          { id: i[:insight_uid], type: i[:insight_type], claim: i[:claim], ranking_score: i[:ranking_score] }
        end

        prompt = <<~PROMPT
          You have a ranked list of atomic observations extracted from the VC podcast
          episode "#{episode_title}".

          Group semantically similar observations into higher-level themes. For example,
          three separate observations about AI coding tools reducing boilerplate, engineers
          reviewing more AI-generated code, and engineering shifting from production to
          supervision could become one theme: "AI coding is shifting engineering from
          production toward supervision and review."

          Do NOT force every observation into a cluster — a strong standalone observation
          with no similar peers should simply not appear in any cluster's member_ids.
          Do NOT create a cluster of size 1.

          For each theme, pick the single strongest member observation (by ranking_score
          and how well it represents the theme) as primary_id.

          Return ONLY valid JSON:
          {"clusters": [{"theme": "short theme title", "theme_summary": "1-2 sentence synthesis", "member_ids": ["obs_001", "obs_004"], "primary_id": "obs_001"}]}

          Observations (highest-ranked first):
          #{observations.to_json}
        PROMPT

        @gemini.generate_json(prompt, max_output_tokens: 16_384) do |result|
          result["clusters"].is_a?(Array)
        end
      end

      def store_clusters(episode_id, insights, clusters)
        by_uid = insights.group_by { |i| i[:insight_uid] }.transform_values(&:first)
        now = Time.now.utc

        Array(clusters).each do |cluster|
          member_uids = Array(cluster["member_ids"]).uniq
          members = member_uids.filter_map { |uid| by_uid[uid] }
          next if members.length < 2

          primary = by_uid[cluster["primary_id"]] || members.first

          cluster_id = @clusters.insert(
            episode_id:               episode_id,
            theme:                    cluster["theme"],
            theme_summary:            cluster["theme_summary"],
            representative_insight_id: primary[:id],
            member_count:             members.length,
            created_at:               now
          )

          members.each { |m| @insights.where(id: m[:id]).update(cluster_id: cluster_id) }
        end
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
