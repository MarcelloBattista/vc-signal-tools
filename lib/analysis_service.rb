# frozen_string_literal: true

require "json"
require "faraday"
require "time"

require_relative "database"

module VCTools
  module Podcast
    class AnalysisService

      GEMINI_URL   = "https://generativelanguage.googleapis.com"
      GEMINI_MODEL = "gemini-2.5-flash"

      CROSSLINK_CONTEXT = <<~CTX
        You are an AI assistant helping a first-year analyst at an early-stage venture firm.
        The firm invests $1-9M into AI, dev tools, infrastructure, marketplaces, consumer, vertical SaaS, and health tech.
        They do NOT invest in biotech or crypto. Focus on insights relevant to early-stage investing and emerging technology.
      CTX

      def initialize
        @db          = VCTools::Podcast::Database.connect
        @episodes    = @db[:episodes]
        @transcripts = @db[:transcripts]
        @chunks      = @db[:transcript_chunks]
        @analyses    = @db[:episode_analyses]

        require "dotenv/load"
        @api_key = ENV["GEMINI_API_KEY"]

        @client = Faraday.new(url: GEMINI_URL) do |f|
          f.request  :json
          f.response :json
          f.options.timeout      = 120
          f.options.open_timeout = 10
        end
      end

      def run(limit: nil)
        unless @api_key
          puts "[Analysis] No GEMINI_API_KEY set — skipping"
          return
        end

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

        result.sort_by { |ep| ep[:published_at] }.reverse.first(limit)
      end

      def analyze_episode(episode)
        puts "[Analysis] Analyzing: #{episode[:title]}"

        transcript = @transcripts.where(episode_id: episode[:id]).first
        unless transcript
          puts "[Analysis] No transcript for episode #{episode[:id]}"
          return update_status(episode[:id], "failed")
        end

        # Get the full transcript text from chunks
        chunks = @chunks.where(transcript_id: transcript[:id]).order(:chunk_index).all
        if chunks.empty?
          puts "[Analysis] No chunks for transcript #{transcript[:id]}"
          return update_status(episode[:id], "failed")
        end

        full_text = chunks.map { |c| c[:text] }.join("\n\n")
        puts "[Analysis]   Transcript: #{chunks.length} chunks, #{full_text.length} chars"

        # Single Gemini call with the full transcript
        puts "[Analysis]   Sending to Gemini..."
        analysis = synthesize(episode[:title], full_text)
        return update_status(episode[:id], "failed") unless analysis

        store_analysis(episode[:id], analysis)
        update_status(episode[:id], "analyzed")
        puts "[Analysis] Done: #{episode[:title]}"

      rescue => e
        puts "[Analysis] Error (#{episode[:title]}): #{e.message}"
        update_status(episode[:id], "failed")
      end

      def synthesize(episode_title, transcript_text)
        prompt = <<~PROMPT
          #{CROSSLINK_CONTEXT}

          You have the full transcript of the podcast episode: "#{episode_title}"

          Write a thorough analysis as a JSON object. The "summary_md" field should be a markdown writeup (400-650 words MAX) with this EXACT structure:

          ### Overview
          2-3 sentences describing what the episode covered, who the guest/speakers were, and the main theme.

          ### Major Talking Points
          #### [Talking Point 1 Title]
          Detailed paragraph about this talking point with specific names, numbers, and arguments.

          #### [Talking Point 2 Title]
          Detailed paragraph about this talking point with specific names, numbers, and arguments.

          (Continue for each major talking point — typically 3-4 per episode)

          Rules for the writeup:
          - Every sentence must contain a specific fact, name, number, or argument from the episode
          - Include the speakers' actual arguments and reasoning, not just topics
          - Note any disagreements or contrarian takes
          - Do NOT write generic statements. If you cannot be specific, leave it out.
          - Do NOT include any concluding section (no "Bottom Line", "Conclusion", "Summary", etc.)
          - End after the last talking point sub-section

          CRITICAL — DO NOT HALLUCINATE:
          - ONLY reference names, companies, titles, and affiliations that appear in the transcript.
          - Do NOT add people or organizations from your general knowledge.
          - If unsure who said something, write "a speaker" or "the host" — never guess a name.
          - Accuracy is more important than completeness.

          Return ONLY valid JSON with this exact structure. ALL fields are REQUIRED — never use null:
          {
            "summary_md": "YOUR 400-650 WORD MARKDOWN ANALYSIS",
            "key_takeaways": ["takeaway 1", "takeaway 2", "takeaway 3", "takeaway 4", "takeaway 5"],
            "investment_signals": [
              {"signal": "description", "sector": "AI|DevTools|Infra|Marketplace|Consumer|VerticalSaaS|HealthTech", "why_it_matters": "reason"}
            ],
            "risks": ["risk 1", "risk 2"],
            "action_items": ["action 1"]
          }

          IMPORTANT: You MUST populate every field with real content. Do NOT return null for any field.

          Full transcript:
          #{transcript_text}
        PROMPT

        raw = gemini_generate(prompt)
        return nil unless raw

        result = parse_json_response(raw)

        # Retry up to 2 times on failure
        2.times do |attempt|
          break if result
          puts "[Analysis]   Retry #{attempt + 1}..."
          raw = gemini_generate(prompt)
          result = parse_json_response(raw) if raw
        end

        result
      end

      def gemini_generate(prompt)
        response = @client.post(
          "/v1beta/models/#{GEMINI_MODEL}:generateContent?key=#{@api_key}",
          {
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: {
              temperature: 0.3,
              maxOutputTokens: 16384,
              thinkingConfig: { thinkingBudget: 1024 }
            }
          }
        )

        body = response.body
        if body.is_a?(Hash) && body["candidates"]
          text = body.dig("candidates", 0, "content", "parts", 0, "text")
          return text.strip if text
        end

        error = body.dig("error", "message") if body.is_a?(Hash)
        puts "[Analysis] Gemini error: #{error || body.inspect[0..200]}"
        nil

      rescue => e
        puts "[Analysis] Gemini request error: #{e.class} — #{e.message}"
        nil
      end

      def parse_json_response(raw)
        return nil unless raw

        # Extract the JSON block even if the model adds surrounding text
        json_match = raw.match(/\{.*\}/m)
        return nil unless json_match

        json_str = json_match[0]

        # Clean up common LLM JSON issues
        json_str = json_str
          .gsub(/[\x00-\x1F]/) { |c| c == "\n" || c == "\t" ? c : "" }
          .gsub(/,\s*([}\]])/, '\1')

        result = JSON.parse(json_str)

        # Validate summary is real content
        summary = result["summary_md"].to_s
        if summary.length < 100
          puts "[Analysis] Summary too short (#{summary.length} chars)"
          return nil
        end

        result

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
          engine:                  "gemini",
          model:                   GEMINI_MODEL,
          created_at:              now
        )
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