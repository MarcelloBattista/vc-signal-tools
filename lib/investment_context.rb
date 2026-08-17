# frozen_string_literal: true

module VCTools
  module Podcast
    # Shared firm-context framing injected into every Gemini prompt across all
    # pipeline stages, so extraction/ranking/clustering/synthesis all reason about
    # relevance the same way.
    CROSSLINK_CONTEXT = <<~CTX.freeze
      You are an AI assistant helping a first-year analyst at an early-stage venture firm.
      The firm invests $1-9M into AI, dev tools, infrastructure, marketplaces, consumer, vertical SaaS, and health tech.
      They do NOT invest in biotech or crypto. Focus on insights relevant to early-stage investing and emerging technology.
    CTX

    CROSSLINK_SECTORS = ["AI", "DevTools", "Infra", "Marketplace", "Consumer", "Vertical SaaS", "Health Tech"].freeze
  end
end
