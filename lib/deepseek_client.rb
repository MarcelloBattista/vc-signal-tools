# frozen_string_literal: true

require "json"
require "faraday"

module VCTools
  module Podcast
    # Thin client for DeepSeek's OpenAI-compatible chat completions endpoint.
    # Mirrors GeminiClient's interface (generate_json/parse_json) so the same
    # extraction prompt can run against either provider with minimal duplication.
    class DeepSeekClient
      DEEPSEEK_URL = "https://api.deepseek.com"

      # Token usage from the most recent #generate call, normalized to the same
      # shape as GeminiClient#last_usage so comparison code can treat both alike.
      attr_reader :last_usage

      def initialize(model:, api_key: ENV["DEEPSEEK_API_KEY"], timeout: 120)
        @model   = model
        @api_key = api_key
        @last_usage = nil

        @client = Faraday.new(url: DEEPSEEK_URL) do |f|
          f.request  :json
          f.response :json
          f.options.timeout      = timeout
          f.options.open_timeout = 10
        end
      end

      def api_key?
        !@api_key.nil? && !@api_key.empty?
      end

      # Same contract as GeminiClient#generate_json: retries until `validate`
      # accepts the parsed result. Returns bare `result` (or nil) — read
      # #last_usage afterward for token counts.
      def generate_json(prompt, temperature: 0.3, max_tokens: 8192, retries: 2, &validate)
        attempts = retries + 1

        attempts.times do |attempt|
          raw = generate(prompt, temperature: temperature, max_tokens: max_tokens)
          result = raw && parse_json(raw)

          return result if result && (validate.nil? || validate.call(result))

          puts "[DeepSeek]   Retry #{attempt + 1}/#{attempts}..." if attempt < attempts - 1
        end

        nil
      end

      def generate(prompt, temperature: 0.3, max_tokens: 8192)
        response = @client.post("/chat/completions") do |req|
          req.headers["Authorization"] = "Bearer #{@api_key}"
          req.body = {
            model: @model,
            messages: [{ role: "user", content: prompt }],
            temperature: temperature,
            max_tokens: max_tokens
          }
        end

        body = response.body
        if body.is_a?(Hash) && body["choices"]
          usage = body["usage"]
          @last_usage = usage && {
            prompt_tokens:     usage["prompt_tokens"],
            completion_tokens: usage["completion_tokens"],
            total_tokens:      usage["total_tokens"]
          }

          text = body.dig("choices", 0, "message", "content")
          return text&.strip if text
        end

        error = body.dig("error", "message") if body.is_a?(Hash)
        puts "[DeepSeek] Error: #{error || body.inspect[0..200]}"
        nil

      rescue => e
        puts "[DeepSeek] Request error: #{e.class} — #{e.message}"
        nil
      end

      # Same hardening as GeminiClient#parse_json — DeepSeek's OpenAI-compatible
      # output can carry the same surrounding-text/trailing-comma issues.
      def parse_json(raw)
        return nil unless raw

        json_match = raw.match(/\{.*\}/m)
        return nil unless json_match

        json_str = json_match[0]
          .gsub(/[\x00-\x1F]/) { |c| c == "\n" || c == "\t" ? c : "" }
          .gsub(/,\s*([}\]])/, '\1')

        JSON.parse(json_str)

      rescue JSON::ParserError => e
        puts "[DeepSeek] JSON parse error: #{e.message}"
        nil
      end
    end
  end
end
