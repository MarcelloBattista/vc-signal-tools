# frozen_string_literal: true

require "json"

module VCTools
  module Podcast
    # Renders the digest as real email-safe HTML (table-based layout, inline
    # styles) instead of converting markdown via regex. Design language —
    # serif masthead, warm accent color, generous whitespace, subtle dividers,
    # off-white page / white card — is borrowed from a newsletter the user
    # referenced; no branding, links, or content of that newsletter appear here.
    class DigestHtmlRenderer
      ACCENT     = "#1e3a5f"
      INK        = "#1a1a1a"
      BODY_TEXT  = "#333333"
      MUTED      = "#767676"
      FAINT      = "#999999"
      BORDER     = "rgba(0,0,0,0.08)"
      HAIRLINE   = "rgba(0,0,0,0.06)"
      SERIF      = "Georgia, 'Times New Roman', serif"
      SANS       = "-apple-system, Helvetica, Arial, sans-serif"

      def initialize(date:, episode_count:, top_signals:, featured:, also_covered:)
        @date          = date
        @episode_count = episode_count
        @top_signals   = top_signals
        @featured      = featured
        @also_covered  = also_covered
      end

      def render
        <<~HTML
          <div style="background-color:#f9f9f9;padding:24px 0;font-family:#{SANS};">
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
              <tr><td align="center">
                <table role="presentation" cellpadding="0" cellspacing="0" width="680" style="max-width:680px;width:100%;background-color:#ffffff;">
                  <tr><td style="padding:40px 40px 24px 40px;border-bottom:1px solid #{BORDER};">
                    #{masthead}
                  </td></tr>
                  <tr><td style="padding:32px 40px;font-size:1.05rem;line-height:1.65;color:#{BODY_TEXT};">
                    #{top_signals_block}
                    #{featured_block}
                    #{also_covered_block}
                  </td></tr>
                  <tr><td style="padding:24px 40px 32px 40px;border-top:1px solid #{BORDER};text-align:center;font-size:0.8rem;color:#{FAINT};">
                    #{footer}
                  </td></tr>
                </table>
              </td></tr>
            </table>
          </div>
        HTML
      end

      private

      def masthead
        <<~HTML
          <div style="font-family:#{SERIF};font-size:2.1rem;color:#{INK};line-height:1.2;">VC Signal Digest</div>
          <div style="font-size:0.9rem;color:#{MUTED};margin-top:6px;">#{@date} &middot; #{@episode_count} episodes</div>
        HTML
      end

      def eyebrow(text)
        %(<div style="font-size:0.72rem;font-weight:600;letter-spacing:1.2px;text-transform:uppercase;color:#{ACCENT};margin-bottom:12px;">#{text}</div>)
      end

      def divider
        %(<div style="border-top:1px solid #{HAIRLINE};margin:14px 0;"></div>)
      end

      def top_signals_block
        return "" if @top_signals.empty?

        rows = @top_signals.map do |sig|
          meta = [sig[:podcast_name], sig[:timestamp].to_s.empty? ? nil : sig[:timestamp]].compact.join(" &middot; ")
          <<~HTML
            <div style="padding-bottom:14px;margin-bottom:14px;border-bottom:1px solid #{HAIRLINE};">
              <div style="font-size:0.8rem;color:#{FAINT};margin-bottom:4px;">#{meta}</div>
              <div style="color:#{INK};">#{sig[:claim]} <span style="color:#{MUTED};">&rarr; #{sig[:implication]}</span></div>
            </div>
          HTML
        end.join

        <<~HTML
          <div style="margin-bottom:36px;">
            #{eyebrow('Top Signals Today')}
            #{rows}
          </div>
        HTML
      end

      def featured_block
        @featured.each_with_index.map do |ep, i|
          top_border = i.zero? ? "" : "padding-top:32px;border-top:1px solid #{BORDER};"
          pub_date = ep[:published_at]&.strftime("%-m/%-d/%Y") || "Unknown"

          <<~HTML
            <div style="margin-bottom:40px;#{top_border}">
              <div style="font-family:#{SERIF};font-size:1.5rem;color:#{INK};margin-bottom:4px;">#{ep[:podcast_name]}: #{ep[:title]}</div>
              <div style="font-size:0.85rem;color:#{FAINT};margin-bottom:20px;">#{pub_date}</div>
              #{episode_body(ep)}
            </div>
          HTML
        end.join
      end

      def episode_body(ep)
        return fallback_summary(ep) unless ep[:sections]

        s = ep[:sections]
        [
          text_section("30-Second Take", s["thirty_second_take"]),
          list_section("Top Insights", s["top_insights"]) { |i| "<strong>#{i['insight']}</strong> — #{i['evidence']} &rarr; #{i['implication']}#{ts_suffix(i['timestamp'])}" },
          list_section("Contrarian Takes", s["contrarian_takes"]) { |c| "<strong>#{c['claim']}</strong> — vs. consensus (#{c['consensus_view']}): #{c['reason_for_disagreement']} &rarr; #{c['implication']}" },
          list_section("Markets & Investment Theses", s["markets_theses"]) { |m| "<strong>[#{m['sector']}]</strong> #{m['signal']} — #{m['why_it_matters']} (#{m['direction']})" },
          list_section("Companies Mentioned", s["companies"]) { |c| "<strong>#{c['name']}</strong> — #{c['context']} (#{c['sentiment']}) — #{c['why_it_matters']}" },
          list_section("Predictions", s["predictions"]) { |p| "#{p['prediction']} — #{p['speaker']}, #{p['time_horizon']}#{ts_suffix(p['timestamp'])}" },
          list_section("Frameworks", s["frameworks"]) { |f| "<strong>#{f['name']}</strong>: #{f['description']} — #{f['investment_relevance']}" },
          list_section("Numbers That Matter", s["numbers"]) { |n| "<strong>#{n['metric']}</strong>: #{n['value']} — #{n['context']}" },
          list_section("What to Watch", s["watch"]) { |w| w.to_s },
          list_section("Best Moments", s["best_moments"]) { |b| "#{b['timestamp']} — #{b['description']}" }
        ].compact.join
      end

      def ts_suffix(ts)
        ts.to_s.empty? ? "" : " (#{ts})"
      end

      def fallback_summary(ep)
        %(<div style="color:#{BODY_TEXT};white-space:pre-wrap;">#{ep[:summary]}</div>)
      end

      def text_section(label, text)
        return nil if text.to_s.strip.empty?

        <<~HTML
          <div style="margin-bottom:24px;">
            #{eyebrow(label)}
            <div style="color:#{INK};">#{text}</div>
          </div>
        HTML
      end

      def list_section(label, items)
        items = Array(items)
        return nil if items.empty?

        rows = items.map { |item| %(<div style="margin-bottom:8px;color:#{BODY_TEXT};">#{yield(item)}</div>) }.join

        <<~HTML
          <div style="margin-bottom:24px;">
            #{eyebrow(label)}
            #{rows}
          </div>
        HTML
      end

      def also_covered_block
        return "" if @also_covered.empty?

        rows = @also_covered.map do |ep|
          take = ep[:thirty_second_take].to_s.strip
          suffix = take.empty? ? "" : " — #{take}"
          %(<div style="margin-bottom:10px;color:#{BODY_TEXT};"><strong style="color:#{INK};">#{ep[:podcast_name]}</strong>: #{ep[:title]}#{suffix}</div>)
        end.join

        <<~HTML
          <div style="padding-top:24px;border-top:1px solid #{BORDER};">
            #{eyebrow('Also Covered Today')}
            #{rows}
          </div>
        HTML
      end

      def footer
        <<~HTML
          Built by Marcello Battista<br>
          <a href="https://x.com/marc3llob" style="color:#{FAINT};text-decoration:underline;text-decoration-color:#{ACCENT};">Twitter</a>
          <span style="color:#cccccc;margin:0 6px;">|</span>
          <a href="https://www.linkedin.com/in/marcello-battista/" style="color:#{FAINT};text-decoration:underline;text-decoration-color:#{ACCENT};">LinkedIn</a>
        HTML
      end
    end
  end
end
