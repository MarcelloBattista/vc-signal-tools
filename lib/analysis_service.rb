# frozen_string_literal: true

require "json"
require "time"

require_relative "database"
require_relative "episode_selection"
require_relative "gemini_client"
require_relative "investment_context"

module VCTools
  module Podcast
    # Stage 4 of 4: generates the reader-facing episode summary from the ranked,
    # clustered insights produced by the earlier stages — not from the raw transcript.
    # Class/file name kept as AnalysisService (not renamed) so bin/podcast_analyze,
    # bin/run_podcast_pipeline, and bin/scheduler need no call-site changes.
    class AnalysisService

      GEMINI_MODEL = "gemini-2.5-flash"
      PROMPT_VERSION = "atomic-v1"

      # Kept for backward compatibility — nothing outside this file references it anymore,
      # but it's the same constant name previously exported here.
      CROSSLINK_CONTEXT = VCTools::Podcast::CROSSLINK_CONTEXT

      def initialize
        @db        = VCTools::Podcast::Database.connect
        @episodes  = @db[:episodes]
        @insights  = @db[:episode_insights]
        @clusters  = @db[:episode_insight_clusters]
        @analyses  = @db[:episode_analyses]

        require "dotenv/load"
        @gemini = VCTools::Podcast::GeminiClient.new(model: GEMINI_MODEL)
      end

      def run(limit: nil)
        unless @gemini.api_key?
          puts "[Analysis] No GEMINI_API_KEY set — skipping"
          return
        end

        pending = VCTools::Podcast::EpisodeSelection.diverse(@episodes, status: "clustered", limit: limit)
        puts "[Analysis] #{pending.length} episodes to analyze"

        pending.each { |episode| analyze_episode(episode) }
      end

      private

      def analyze_episode(episode)
        puts "[Analysis] Analyzing: #{episode[:title]}"

        insights = @insights.where(episode_id: episode[:id]).order(Sequel.desc(:ranking_score)).all
        if insights.empty?
          puts "[Analysis] No insights for episode #{episode[:id]}"
          return update_status(episode[:id], "failed", "analyzed")
        end

        clusters = @clusters.where(episode_id: episode[:id]).all

        sections = synthesize(episode[:title], insights, clusters)
        return update_status(episode[:id], "failed", "analyzed") unless sections

        store_analysis(episode[:id], sections, insights.length, clusters.length)
        update_status(episode[:id], "analyzed", nil)
        puts "[Analysis] Done: #{episode[:title]}"

      rescue => e
        puts "[Analysis] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed", "analyzed")
      end

      def synthesize(episode_title, insights, clusters)
        themes = clusters.map do |c|
          members = insights.select { |i| i[:cluster_id] == c[:id] }
          {
            theme: c[:theme],
            theme_summary: c[:theme_summary],
            supporting_claims: members.map { |m| m[:claim] }
          }
        end

        standalone = insights.reject { |i| i[:cluster_id] }.map { |i| insight_payload(i) }
        clustered_members = insights.select { |i| i[:cluster_id] }.map { |i| insight_payload(i) }

        prompt = <<~PROMPT
          #{VCTools::Podcast::CROSSLINK_CONTEXT}

          You are writing the reader-facing summary for the VC podcast episode
          "#{episode_title}", from already-ranked and deduplicated observations — not
          from the raw transcript. Write from this structured data only.

          Synthesized themes (each already consolidates several similar observations):
          #{themes.to_json}

          Individual observations that belong to a theme above (for extra detail/citation):
          #{clustered_members.to_json}

          Standalone observations not part of any theme (each stands on its own):
          #{standalone.to_json}

          Produce a JSON object with these fields. Every sentence must be grounded in the
          data above — do not add facts, names, or companies not present in it. Omit a
          field (return an empty array) if the episode genuinely has nothing for it; do not
          pad with generic filler to populate a section.

          BE CONCISE. Every field should be as short as possible while staying specific and
          grounded — prefer one tight clause over a full sentence, and one sentence over two.
          This is a scannable digest, not a report.

          {
            "thirty_second_take": "AT MOST 2 sentences on why this episode matters",
            "top_insights": [{"insight": "...", "evidence": "...", "implication": "...", "timestamp": "MM:SS or empty string"}],
            "contrarian_takes": [{"claim": "...", "consensus_view": "...", "reason_for_disagreement": "...", "implication": "..."}],
            "markets_theses": [{"sector": "AI|DevTools|Infra|Marketplace|Consumer|VerticalSaaS|HealthTech|other", "signal": "...", "why_it_matters": "...", "direction": "Bullish|Bearish|Neutral|Mixed"}],
            "companies": [{"name": "...", "context": "...", "sentiment": "positive|negative|neutral|mixed", "why_it_matters": "..."}],
            "predictions": [{"prediction": "...", "speaker": "...", "time_horizon": "...", "timestamp": "MM:SS or empty string"}],
            "frameworks": [{"name": "...", "description": "...", "investment_relevance": "..."}],
            "numbers": [{"metric": "...", "value": "...", "context": "..."}],
            "watch": ["short signal/risk/open-question strings"],
            "best_moments": [{"timestamp": "MM:SS", "description": "..."}]
          }

          Cap top_insights at 3, best_moments at 3. Order top_insights by importance. Keep
          "evidence" and "implication" to one short clause each, not full sentences.

          CRITICAL — DO NOT HALLUCINATE: only use names/companies/timestamps present in the
          data above. If unsure who said something, write "a speaker" or "the host".

          Return ONLY the JSON object described above.
        PROMPT

        @gemini.generate_json(prompt, max_output_tokens: 16_384) do |result|
          result["thirty_second_take"].to_s.length >= 20 &&
            Array(result["top_insights"]).any?
        end
      end

      def insight_payload(i)
        {
          type: i[:insight_type], speaker: i[:speaker_label], claim: i[:claim],
          evidence: i[:evidence], implication: i[:implication],
          timestamp_start: ms_to_mmss(i[:timestamp_start_ms]), ranking_score: i[:ranking_score]
        }
      end

      def ms_to_mmss(ms)
        return "" unless ms
        total_seconds = (ms / 1000).to_i
        h = total_seconds / 3600
        m = (total_seconds % 3600) / 60
        s = total_seconds % 60
        h.positive? ? format("%d:%02d:%02d", h, m, s) : format("%02d:%02d", m, s)
      end

      def store_analysis(episode_id, sections, insight_count, cluster_count)
        now = Time.now.utc
        markdown = render_summary_markdown(sections)

        key_takeaways = Array(sections["top_insights"]).first(3).map { |t| t["insight"] }
        investment_signals = Array(sections["markets_theses"]).map do |m|
          { "signal" => m["signal"], "sector" => m["sector"], "why_it_matters" => m["why_it_matters"] }
        end

        @analyses.insert(
          episode_id:              episode_id,
          summary_md:              markdown,
          key_takeaways_json:      key_takeaways.to_json,
          investment_signals_json: investment_signals.to_json,
          risks_json:              Array(sections["watch"]).to_json,
          action_items_json:       [].to_json,
          thirty_second_take:      sections["thirty_second_take"],
          sections_json:           sections.to_json,
          insight_count:           insight_count,
          cluster_count:           cluster_count,
          engine:                  "gemini",
          model:                   GEMINI_MODEL,
          prompt_version:          PROMPT_VERSION,
          created_at:              now
        )
      end

      def render_summary_markdown(s)
        lines = []

        lines << "### 30-Second Take"
        lines << s["thirty_second_take"].to_s
        lines << ""

        render_list(lines, "Top Insights", Array(s["top_insights"]).first(3)) do |i|
          ts = i["timestamp"].to_s.empty? ? "" : " (#{i['timestamp']})"
          "**#{i['insight']}** — #{i['evidence']} → #{i['implication']}#{ts}"
        end

        render_list(lines, "Contrarian Takes", Array(s["contrarian_takes"])) do |c|
          "**#{c['claim']}** — vs. consensus (#{c['consensus_view']}): #{c['reason_for_disagreement']} → #{c['implication']}"
        end

        render_list(lines, "Markets & Investment Theses", Array(s["markets_theses"])) do |m|
          "**[#{m['sector']}]** #{m['signal']} — #{m['why_it_matters']} (#{m['direction']})"
        end

        render_list(lines, "Companies Mentioned", Array(s["companies"])) do |c|
          "**#{c['name']}** — #{c['context']} (#{c['sentiment']}) — #{c['why_it_matters']}"
        end

        render_list(lines, "Predictions", Array(s["predictions"])) do |p|
          ts = p["timestamp"].to_s.empty? ? "" : " (#{p['timestamp']})"
          "#{p['prediction']} — #{p['speaker']}, #{p['time_horizon']}#{ts}"
        end

        render_list(lines, "Frameworks", Array(s["frameworks"])) do |f|
          "**#{f['name']}**: #{f['description']} — #{f['investment_relevance']}"
        end

        render_list(lines, "Numbers That Matter", Array(s["numbers"])) do |n|
          "**#{n['metric']}**: #{n['value']} — #{n['context']}"
        end

        render_list(lines, "What to Watch", Array(s["watch"])) { |w| w.to_s }

        render_list(lines, "Best Moments", Array(s["best_moments"])) do |b|
          "#{b['timestamp']} — #{b['description']}"
        end

        lines.join("\n").rstrip
      end

      def render_list(lines, heading, items)
        return if items.empty?

        lines << "### #{heading}"
        items.each { |item| lines << "- #{yield(item)}" }
        lines << ""
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
