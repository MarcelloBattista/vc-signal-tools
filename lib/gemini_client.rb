# frozen_string_literal: true

require "json"
require "faraday"

module VCTools
  module Podcast
    # Shared Gemini HTTP + JSON-hardening logic used by every pipeline stage.
    class GeminiClient
      GEMINI_URL = "https://generativelanguage.googleapis.com"

      # Token usage from the most recent #generate call (Gemini's usageMetadata,
      # normalized to {prompt_tokens:, completion_tokens:, total_tokens:}), so
      # callers that want cost data (e.g. bin/compare_extraction_providers) can
      # read it without changing the return contract every pipeline stage relies on.
      attr_reader :last_usage

      def initialize(model:, api_key: ENV["GEMINI_API_KEY"], timeout: 120)
        @model   = model
        @api_key = api_key
        @last_usage = nil

        @client = Faraday.new(url: GEMINI_URL) do |f|
          f.request  :json
          f.response :json
          f.options.timeout      = timeout
          f.options.open_timeout = 10
        end
      end

      def api_key?
        !@api_key.nil? && !@api_key.empty?
      end

      # Sends prompt, retries until `validate` accepts the parsed result (or retries run out).
      # `validate` receives the parsed Hash and returns true/false. Returns nil if every
      # attempt fails to produce a raw response, valid JSON, or a result validate accepts.
      def generate_json(prompt, temperature: 0.3, max_output_tokens: 16384, thinking_budget: 1024, retries: 2, &validate)
        attempts = retries + 1

        attempts.times do |attempt|
          raw = generate(prompt, temperature: temperature, max_output_tokens: max_output_tokens, thinking_budget: thinking_budget)
          result = raw && parse_json(raw)

          return result if result && (validate.nil? || validate.call(result))

          puts "[Gemini]   Retry #{attempt + 1}/#{attempts}..." if attempt < attempts - 1
        end

        nil
      end

      def generate(prompt, temperature: 0.3, max_output_tokens: 16384, thinking_budget: 1024)
        response = @client.post(
          "/v1beta/models/#{@model}:generateContent?key=#{@api_key}",
          {
            contents: [{ parts: [{ text: prompt }] }],
            generationConfig: {
              temperature: temperature,
              maxOutputTokens: max_output_tokens,
              thinkingConfig: { thinkingBudget: thinking_budget }
            }
          }
        )

        body = response.body
        if body.is_a?(Hash) && body["candidates"]
          usage = body["usageMetadata"]
          @last_usage = usage && {
            prompt_tokens:     usage["promptTokenCount"],
            completion_tokens: usage["candidatesTokenCount"],
            total_tokens:      usage["totalTokenCount"]
          }

          text = body.dig("candidates", 0, "content", "parts", 0, "text")
          return text.strip if text
        end

        error = body.dig("error", "message") if body.is_a?(Hash)
        puts "[Gemini] Error: #{error || body.inspect[0..200]}"
        nil

      rescue => e
        puts "[Gemini] Request error: #{e.class} — #{e.message}"
        nil
      end

      # Extracts the first top-level {...} object from the raw text and parses it,
      # tolerating common LLM JSON mistakes (control chars, trailing commas).
      def parse_json(raw)
        return nil unless raw

        json_match = raw.match(/\{.*\}/m)
        return nil unless json_match

        json_str = json_match[0]
          .gsub(/[\x00-\x1F]/) { |c| c == "\n" || c == "\t" ? c : "" }
          .gsub(/,\s*([}\]])/, '\1')

        JSON.parse(json_str)

      rescue JSON::ParserError => e
        puts "[Gemini] JSON parse error: #{e.message}"
        nil
      end
    end
  end
end
