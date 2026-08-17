# frozen_string_literal: true

require_relative "investment_context"

module VCTools
  module Podcast
    # The Stage 1 atomic-insight-extraction prompt, factored out of
    # InsightExtractionService so it can be run identically against multiple
    # providers (e.g. lib/deepseek_client.rb) for a fair side-by-side comparison.
    module InsightExtractionPrompt
      VALID_TYPES = %w[
        insight contrarian_view prediction data_point company_mention
        framework founder_advice investor_advice market_signal question quote
      ].freeze

      def self.build(episode_title:, transcript_text:)
        <<~PROMPT
          #{VCTools::Podcast::CROSSLINK_CONTEXT}

          You have the timestamped transcript of the podcast episode: "#{episode_title}"
          Each line is prefixed with a "[MM:SS]" or "[H:MM:SS]" marker showing when that
          line was spoken.

          Extract individual ATOMIC observations from this transcript — each one a single,
          self-contained idea. Do not combine unrelated claims into the same object, and do
          not simply recap the episode chronologically. Extract up to 60 of the
          highest-signal observations, prioritizing:

          - Important investment insights
          - Contrarian or non-consensus views
          - Market and sector intelligence
          - Companies and products mentioned
          - Quantitative data points
          - Predictions
          - Reusable frameworks and mental models
          - Founder takeaways
          - Investor takeaways
          - Follow-up research questions
          - High-value, specific moments worth citing directly

          For each observation, return an object with:
          {
            "id": "obs_001",
            "type": "one of: #{VALID_TYPES.join('|')}",
            "speaker": "who said it",
            "timestamp_start": "MM:SS or H:MM:SS, from the nearest preceding marker in the transcript",
            "timestamp_end": "MM:SS or H:MM:SS, from the nearest marker at/after the observation ends",
            "category": "short free-text category",
            "claim": "the core assertion, one or two sentences",
            "evidence": "what the speaker offered in support, if anything",
            "implication": "why this matters for an early-stage VC",
            "companies": ["company names mentioned in this observation"],
            "people": ["people mentioned, other than the speaker"],
            "sectors": ["AI|DevTools|Infra|Marketplace|Consumer|VerticalSaaS|HealthTech, or another sector if clearly not one of these"],
            "metrics": ["any hard numbers/metrics referenced, as short strings, e.g. '$5M ARR in 18 months'"],
            "importance": 0-5,
            "novelty": 0-5,
            "specificity": 0-5,
            "actionability": 0-5,
            "credibility": 0-5
          }

          Scoring guidance — do NOT reward eloquence. Score based on information value:
          - importance: 0=filler, 3=meaningful insight, 5=central thesis or decision-changing
          - novelty: 0=extremely generic, 3=interesting perspective, 5=highly surprising/differentiated
          - specificity: 0=vague statement, 3=specific mechanism/example, 5=precise/falsifiable/well-supported
          - actionability: 0=no practical consequence, 3=suggests a research direction, 5=could directly affect an investment decision
          - credibility: 0=unsupported speculation, 3=supported by reasoning/experience, 5=strong evidence from a firsthand source
          A score of 5 on any dimension should be rare — reserve it for observations that are
          genuinely among the most important/differentiated/useful in the episode. Generic,
          polished, or motivational statements with no mechanism, evidence, or novel framing
          (e.g. "AI is moving fast", "distribution matters") should score low across the board
          and are usually not worth extracting at all.

          CRITICAL — DO NOT HALLUCINATE:
          - ONLY reference names, companies, titles, and affiliations that appear in the transcript.
          - Do NOT add people or organizations from your general knowledge.
          - If unsure who said something, write "a speaker" or "the host" — never guess a name.
          - Use "timestamp_start"/"timestamp_end" values that actually appear as markers in the
            transcript — never invent a timestamp.
          - Accuracy is more important than completeness.

          Return ONLY valid JSON: {"insights": [ ...observations as described above... ]}

          Timestamped transcript:
          #{transcript_text}
        PROMPT
      end
    end
  end
end
