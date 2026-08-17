# frozen_string_literal: true

require "json"
require "time"

require_relative "database"
require_relative "episode_selection"
require_relative "gemini_client"

module VCTools
  module Podcast
    # Stage 2 of 4: scores each atomic insight extracted by InsightExtractionService.
    #
    # The 0-5 sub-scores are already self-assigned by Gemini during extraction. This
    # stage asks Gemini only for the qualitative judgment calls the doc's ranking
    # system needs (is this contrarian? firsthand? generic filler?) — the arithmetic
    # (weighted formula, normalization, bonus/penalty application, capping at 100) is
    # computed deterministically in Ruby so it can't drift from run to run or be
    # miscalculated by the model.
    class RankingService

      GEMINI_MODEL = "gemini-2.5-flash"
      RANKING_VERSION = "v1"

      WEIGHTS = { importance: 0.30, novelty: 0.20, specificity: 0.20, actionability: 0.20, credibility: 0.10 }.freeze
      QUANTITATIVE_BONUS = 5
      CONTRARIAN_BONUS    = 5
      FIRSTHAND_BONUS     = 5
      NAMED_COMPANY_BONUS = 2
      PREDICTION_BONUS    = 5
      GENERIC_PENALTY_RANGE = (10..25)

      def initialize
        @db       = VCTools::Podcast::Database.connect
        @episodes = @db[:episodes]
        @insights = @db[:episode_insights]

        require "dotenv/load"
        @gemini = VCTools::Podcast::GeminiClient.new(model: GEMINI_MODEL)
      end

      def run(limit: nil)
        unless @gemini.api_key?
          puts "[Ranking] No GEMINI_API_KEY set — skipping"
          return
        end

        pending = VCTools::Podcast::EpisodeSelection.diverse(@episodes, status: "insights_extracted", limit: limit)
        puts "[Ranking] #{pending.length} episodes to process"

        pending.each { |episode| rank_episode(episode) }
      end

      private

      def rank_episode(episode)
        puts "[Ranking] Ranking: #{episode[:title]}"

        insights = @insights.where(episode_id: episode[:id]).all
        if insights.empty?
          puts "[Ranking] No insights for episode #{episode[:id]}"
          return update_status(episode[:id], "failed", "ranked")
        end

        judgments = judge(episode[:title], insights)
        return update_status(episode[:id], "failed", "ranked") unless judgments

        apply_rankings(insights, judgments["rankings"])
        update_status(episode[:id], "ranked", nil)
        puts "[Ranking] Done: #{episode[:title]}"

      rescue => e
        puts "[Ranking] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed", "ranked")
      end

      def judge(episode_title, insights)
        observations = insights.map do |i|
          {
            id: i[:insight_uid],
            type: i[:insight_type],
            claim: i[:claim],
            evidence: i[:evidence],
            metrics: JSON.parse(i[:metrics_json] || "[]"),
            scores: {
              importance: i[:score_importance], novelty: i[:score_novelty],
              specificity: i[:score_specificity], actionability: i[:score_actionability],
              credibility: i[:score_credibility]
            }
          }
        end

        prompt = <<~PROMPT
          You are ranking atomic observations extracted from the VC podcast episode "#{episode_title}".

          For each observation below, judge (relative to this episode — a rating of "true" should
          be reserved for observations that genuinely earn it, not applied liberally):

          - has_quantitative_evidence: does it include a meaningful metric or number?
          - is_contrarian: does the speaker clearly disagree with an established consensus, substantively (not just a mild opinion)?
          - is_firsthand_knowledge: does the speaker have direct operational or investment experience with the claim (e.g. a founder on their own company, an investor on observed portfolio data)?
          - has_named_company: does it contain a meaningful named-company example (not incidental name-dropping)?
          - is_falsifiable_prediction: is it a clear prediction with an identifiable time horizon?
          - is_generic: does it sound insightful but contain little real information (e.g. "AI is moving fast", "distribution matters", "great founders are resilient") — no supporting mechanism, evidence, example, or novel framing?
          - generic_penalty: if is_generic is true, a number 10-25 for how severely generic it is; otherwise 0

          Return ONLY valid JSON:
          {"rankings": [{"id": "obs_001", "has_quantitative_evidence": bool, "is_contrarian": bool, "is_firsthand_knowledge": bool, "has_named_company": bool, "is_falsifiable_prediction": bool, "is_generic": bool, "generic_penalty": 0}]}

          Observations:
          #{observations.to_json}
        PROMPT

        @gemini.generate_json(prompt, max_output_tokens: 16_384) do |result|
          result["rankings"].is_a?(Array) && !result["rankings"].empty?
        end
      end

      def apply_rankings(insights, rankings)
        by_uid = insights.group_by { |i| i[:insight_uid] }.transform_values(&:first)

        rankings.each do |r|
          insight = by_uid[r["id"]]
          next unless insight

          base = weighted_base_score(insight)

          bonuses = {}
          bonuses["quantitative_evidence"] = QUANTITATIVE_BONUS if r["has_quantitative_evidence"]
          bonuses["contrarian"]            = CONTRARIAN_BONUS    if r["is_contrarian"]
          bonuses["firsthand_knowledge"]   = FIRSTHAND_BONUS     if r["is_firsthand_knowledge"]
          bonuses["named_company"]         = NAMED_COMPANY_BONUS if r["has_named_company"]
          bonuses["falsifiable_prediction"] = PREDICTION_BONUS   if r["is_falsifiable_prediction"]

          penalties = {}
          if r["is_generic"]
            penalties["generic"] = r["generic_penalty"].to_i.clamp(GENERIC_PENALTY_RANGE)
          end

          final_score = (base + bonuses.values.sum - penalties.values.sum).clamp(0, 100)

          @insights.where(id: insight[:id]).update(
            ranking_score:          final_score,
            ranking_bonuses_json:   bonuses.to_json,
            ranking_penalties_json: penalties.to_json,
            ranking_version:        RANKING_VERSION
          )
        end
      end

      def weighted_base_score(insight)
        weighted = WEIGHTS.sum do |dimension, weight|
          weight * (insight[:"score_#{dimension}"] || 0)
        end
        (weighted / 5.0 * 100).round(1)
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
