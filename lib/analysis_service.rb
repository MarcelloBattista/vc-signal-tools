# frozen_string_literal: true

require "json"
require "faraday"
require "time"

require_relative "database"

module VCTools
  module Podcast
    class AnalysisService

      OLLAMA_URL  = "http://localhost:11434"
      CHUNK_MODEL = "llama3.2"      # fast per-chunk summarization
      SYNTH_MODEL = "deepseek-r1:8b" # higher quality synthesis + signal extraction

      CROSSLINK_CONTEXT = <<~CTX
        You are an AI assistant helping a first-year analyst at Crosslink Capital, an early-stage venture firm.
        Crosslink invests $1-9M into AI, dev tools, infrastructure, marketplaces, consumer, vertical SaaS, and health tech.
        They do NOT invest in biotech or crypto. Focus on insights relevant to early-stage investing and emerging technology.
      CTX

      def initialize
        @db          = VCTools::Podcast::Database.connect
        @episodes    = @db[:episodes]
        @transcripts = @db[:transcripts]
        @chunks      = @db[:transcript_chunks]
        @analyses    = @db[:episode_analyses]
        @client      = Faraday.new(url: OLLAMA_URL) do |f|
          f.request  :json
          f.response :json
          f.options.timeout      = 300  # 5 min — synthesis can be slow
          f.options.open_timeout = 10
        end
      end

      def run(limit: nil)
        pending = diverse_episodes("transcribed", limit)
        puts "[Analysis] #{pending.length} episodes to analyze"

        pending.each { |episode| analyze_episode(episode) }
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

      def analyze_episode(episode)
        puts "[Analysis] Analyzing: #{episode[:title]}"

        transcript = @transcripts.where(episode_id: episode[:id]).first
        unless transcript
          puts "[Analysis] No transcript for episode #{episode[:id]}"
          return update_status(episode[:id], "failed")
        end

        chunks = @chunks.where(transcript_id: transcript[:id]).order(:chunk_index).all
        if chunks.empty?
          puts "[Analysis] No chunks for transcript #{transcript[:id]}"
          return update_status(episode[:id], "failed")
        end

        # Map: summarize each chunk individually
        chunk_summaries = chunks.map.with_index do |chunk, i|
          puts "[Analysis]   Chunk #{i + 1}/#{chunks.length}..."
          summarize_chunk(chunk[:text], episode[:title])
        end

        # Mid-reduce: collapse chunk summaries into 4 groups, preserving specifics
        group_size    = (chunk_summaries.length / 4.0).ceil
        group_summaries = chunk_summaries.each_slice(group_size).map.with_index do |group, i|
          puts "[Analysis]   Group summary #{i + 1}..."
          consolidate_notes(group.join("\n\n"), episode[:title])
        end

        # Reduce: synthesize group summaries into final structured analysis
        puts "[Analysis]   Synthesizing final analysis..."
        analysis = synthesize(episode[:title], group_summaries)
        return update_status(episode[:id], "failed") unless analysis

        store_analysis(episode[:id], analysis)
        update_status(episode[:id], "analyzed")
        puts "[Analysis] Done: #{episode[:title]}"

      rescue => e
        puts "[Analysis] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed")
      end

      def summarize_chunk(text, episode_title)
        prompt = <<~PROMPT
          #{CROSSLINK_CONTEXT}

          You are reading a section of the podcast episode: "#{episode_title}"

          Extract SPECIFIC details from this excerpt. Do NOT generalize. Include:
          - Exact names of people, companies, products, and funds mentioned
          - Specific numbers: revenue figures, valuations, round sizes, growth rates, headcounts
          - Direct arguments or opinions stated by speakers — paraphrase closely
          - Concrete strategies, tactics, or frameworks described (not vague references)
          - Any disagreements, debates, or contrarian takes

          Do NOT write generic statements like "AI is important" or "startups need product-market fit."
          Instead write things like "Vlad Tenev said Robinhood's prediction markets hit $1B in volume within 3 months of launch."

          Excerpt:
          #{text}

          Detailed notes:
        PROMPT

        ollama_generate(CHUNK_MODEL, prompt) || ""
      end

      def consolidate_notes(notes_text, episode_title)
        prompt = <<~PROMPT
          #{CROSSLINK_CONTEXT}

          You are consolidating notes from multiple sections of: "#{episode_title}"

          Merge these notes into a clean summary. KEEP all specific details:
          - Preserve every company name, person name, dollar amount, percentage, and metric
          - Keep direct quotes or close paraphrases of speaker opinions
          - Maintain specific examples and anecdotes — do not abstract them away
          - Remove only pure duplicates

          Notes to consolidate:
          #{notes_text}

          Consolidated notes (keep all specifics):
        PROMPT

        ollama_generate(CHUNK_MODEL, prompt) || ""
      end

      def synthesize(episode_title, chunk_summaries)
        combined = chunk_summaries.join("\n\n---\n\n")

        prompt = <<~PROMPT
          #{CROSSLINK_CONTEXT}

          You have detailed notes from the full podcast episode: "#{episode_title}"

          Write a thorough analysis as a JSON object. The "summary_md" field should be a LONG markdown writeup (500-1000 words) structured as follows:

          1. Start with a 2-3 sentence overview of what the episode covered and who was speaking.
          2. Then break the episode into its major TALKING POINTS (use markdown ### headers for each).
             For each talking point:
             - Describe what was discussed with SPECIFIC details (names, numbers, examples)
             - Include the speakers' actual arguments and reasoning, not just topics
             - Note any disagreements or contrarian takes
             - Connect relevant points to early-stage investing where natural
          IMPORTANT: Do NOT write generic statements. Every sentence should contain a specific fact, name, number, or argument from the episode. If you cannot be specific, leave it out.
          STRICTLY FORBIDDEN: Do NOT include any concluding section such as "Bottom Line", "Bottom Line for Crosslink", "Conclusion", "Summary", or "Key Takeaways" at the end of summary_md. End the writeup after the last talking point. Any conclusion paragraph will be rejected.

          Return ONLY valid JSON with this exact structure (no extra text before or after):
          {
            "summary_md": "The full 500-1000 word markdown writeup described above",
            "key_takeaways": ["specific takeaway 1 with names/numbers", "specific takeaway 2", "specific takeaway 3", "specific takeaway 4", "specific takeaway 5"],
            "investment_signals": [
              {"signal": "specific signal", "sector": "AI|DevTools|Infra|Marketplace|Consumer|VerticalSaaS|HealthTech", "why_it_matters": "specific reason"}
            ],
            "risks": ["specific risk 1", "specific risk 2"],
            "action_items": ["specific follow-up action for a VC analyst"]
          }

          Detailed notes from the episode:
          #{combined}

          JSON:
        PROMPT

        raw = ollama_generate(SYNTH_MODEL, prompt)
        return nil unless raw

        # Extract the JSON block even if the model adds surrounding text
        json_match = raw.match(/\{.*\}/m)
        return nil unless json_match

        JSON.parse(json_match[0])

      rescue JSON::ParserError => e
        puts "[Analysis] JSON parse error: #{e.message}"
        nil
      end

      def store_analysis(episode_id, analysis)
        now = Time.now.utc
        @analyses.insert(
          episode_id:              episode_id,
          summary_md:              analysis["summary_md"],
          key_takeaways_json:      analysis["key_takeaways"].to_json,
          investment_signals_json: analysis["investment_signals"].to_json,
          risks_json:              analysis["risks"].to_json,
          action_items_json:       analysis["action_items"].to_json,
          engine:                  "local",
          model:                   SYNTH_MODEL,
          created_at:              now
        )
      end

      def ollama_generate(model, prompt)
        response = @client.post("/api/generate", {
          model:  model,
          prompt: prompt,
          stream: false
        })

        if response.body.is_a?(Hash) && response.body["response"]
          response.body["response"].strip
        else
          puts "[Analysis] Unexpected Ollama response: #{response.body.inspect[0..200]}"
          nil
        end

      rescue => e
        puts "[Analysis] Ollama error: #{e.class} — #{e.message}"
        nil
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
