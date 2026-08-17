# frozen_string_literal: true

require "json"
require "time"
require "date"

require_relative "database"
require_relative "investment_context"
require_relative "digest_html_renderer"

module VCTools
  module Podcast
    class DigestBuilder

      def initialize
        @db        = VCTools::Podcast::Database.connect
        @episodes  = @db[:episodes]
        @podcasts  = @db[:podcasts]
        @analyses  = @db[:episode_analyses]
        @insights  = @db[:episode_insights]
        @digests   = @db[:daily_digests]
      end

      def run(date: Date.today)
        puts "[Digest] Building digest for #{date}"

        analyzed = fetch_analyzed_episodes(date)
        if analyzed.empty?
          puts "[Digest] No analyzed episodes for #{date}"
          return nil
        end

        # Check if we'd be sending the same episodes as the last digest
        new_titles = analyzed.map { |ep| ep[:title] }.sort
        last_sent  = @digests.where(delivery_status: "sent").order(:digest_date).last
        if last_sent && last_sent[:episode_titles]
          old_titles = JSON.parse(last_sent[:episode_titles]) rescue []
          if new_titles == old_titles.sort
            puts "[Digest] Same episodes as last sent digest — skipping"
            return nil
          end
        end

        featured     = select_diverse(analyzed, count: 2)
        also_covered = (analyzed - featured).select { |ep| published_today_or_yesterday?(ep, date) }

        markdown = build_markdown(date, analyzed, featured, also_covered)
        store_digest(date, markdown, analyzed.length, new_titles)
        send_email(date, analyzed, featured, also_covered)

        puts "[Digest] Done — #{analyzed.length} episodes, email sent"
        markdown
      end

      private

      # Also Covered Today should only show episodes actually from today or
      # yesterday — an episode can get analyzed today while having been
      # published further back (processing backlog), which shouldn't count
      # as "today's" news for that section.
      def published_today_or_yesterday?(ep, date)
        return false unless ep[:published_at]
        published_date = ep[:published_at].to_date
        published_date >= (date - 1) && published_date <= date
      end

      def fetch_analyzed_episodes(date)
        # Get episodes analyzed today (since midnight UTC of the digest date)
        cutoff = Time.new(date.year, date.month, date.day, 0, 0, 0).utc

        analyzed_ids = @episodes
          .where(status: "analyzed")
          .where { updated_at >= cutoff }
          .select_map(:id)

        # Fallback: if nothing was analyzed today, look back 24h
        if analyzed_ids.empty?
          cutoff = cutoff - 86400
          analyzed_ids = @episodes
            .where(status: "analyzed")
            .where { updated_at >= cutoff }
            .select_map(:id)
        end

        return [] if analyzed_ids.empty?

        analyzed_ids.map do |ep_id|
          episode  = @episodes.where(id: ep_id).first
          podcast  = @podcasts.where(id: episode[:podcast_id]).first
          analysis = @analyses.where(episode_id: ep_id).first
          next unless analysis

          {
            episode_id:         ep_id,
            podcast_name:       podcast[:name],
            title:              episode[:title],
            published_at:       episode[:published_at],
            analyzed_at:        episode[:updated_at],
            summary:            analysis[:summary_md],
            prompt_version:     analysis[:prompt_version],
            thirty_second_take: analysis[:thirty_second_take],
            sections:           parse_sections(analysis[:sections_json]),
            key_takeaways:      JSON.parse(analysis[:key_takeaways_json] || "[]") || [],
            investment_signals: JSON.parse(analysis[:investment_signals_json] || "[]") || [],
            risks:              JSON.parse(analysis[:risks_json] || "[]") || [],
            action_items:       JSON.parse(analysis[:action_items_json] || "[]") || []
          }
        end.compact
      end

      def parse_sections(sections_json)
        return nil unless sections_json
        JSON.parse(sections_json)
      rescue JSON::ParserError
        nil
      end

      # Highest-ranked insights across ALL episodes analyzed today, not just the
      # featured 3 — so a strong signal never gets dropped just because its podcast
      # lost the "one per show" featured slot.
      def top_signals(analyzed, limit: 5)
        return [] if analyzed.empty?

        episode_ids = analyzed.map { |ep| ep[:episode_id] }
        podcast_by_episode = analyzed.each_with_object({}) { |ep, h| h[ep[:episode_id]] = ep[:podcast_name] }

        @insights
          .where(episode_id: episode_ids)
          .exclude(ranking_score: nil)
          .order(Sequel.desc(:ranking_score))
          .limit(limit)
          .all
          .map do |insight|
            {
              podcast_name:  podcast_by_episode[insight[:episode_id]],
              claim:         insight[:claim],
              implication:   insight[:implication],
              ranking_score: insight[:ranking_score],
              timestamp:     ms_to_mmss(insight[:timestamp_start_ms])
            }
          end
      end

      def ms_to_mmss(ms)
        return "" unless ms
        total_seconds = (ms / 1000).to_i
        h = total_seconds / 3600
        m = (total_seconds % 3600) / 60
        s = total_seconds % 60
        h.positive? ? format("%d:%02d:%02d", h, m, s) : format("%02d:%02d", m, s)
      end

      # Select 3 episodes for the digest, one per podcast (most recently analyzed first)
      def select_diverse(episodes, count: 2)
        episodes
          .sort_by { |ep| ep[:analyzed_at] || ep[:published_at] }
          .reverse
          .group_by { |ep| ep[:podcast_name] }
          .flat_map { |_name, eps| eps.first(1) }
          .first(count)
      end

      def build_markdown(date, analyzed, featured, also_covered)
        lines = []

        # Header
        lines << "# VC Podcast Digest — #{date}"
        lines << ""
        lines << "**#{analyzed.length} episodes** | Generated #{Time.now.utc.strftime('%Y-%m-%d %H:%M UTC')}"
        lines << ""
        lines << "---"
        lines << ""

        # Top Signals — pulled from every analyzed episode today, not just the featured 3
        signals = top_signals(analyzed)
        unless signals.empty?
          lines << "### Top Signals Today"
          lines << ""
          signals.each do |sig|
            ts = sig[:timestamp].to_s.empty? ? "" : ", ⏱ #{sig[:timestamp]}"
            lines << "- **[#{sig[:ranking_score].to_i}] #{sig[:podcast_name]}#{ts}** — #{sig[:claim]} → #{sig[:implication]}"
          end
          lines << ""
          lines << "---"
          lines << ""
        end

        # Full writeup for each featured episode
        featured.each_with_index do |ep, i|
          pub_date = ep[:published_at]&.strftime("%-m/%-d/%Y") || "Unknown"
          lines << "## #{i + 1}. #{ep[:podcast_name]}: #{ep[:title]} (#{pub_date})"
          lines << ""

          if ep[:prompt_version] == "atomic-v1"
            # summary_md is already fully sectioned (30-Second Take, Top Insights, etc.)
            lines << ep[:summary].to_s.rstrip
            lines << ""
          else
            # Legacy (pre-rework) rendering, kept for episodes analyzed before this change
            summary = ep[:summary] || ""
            summary = summary.sub(/\n*###?\s*Bottom Line.*\z/mi, "").rstrip
            lines << summary unless summary.empty?
            lines << ""

            unless ep[:key_takeaways].empty?
              lines << "### Key Takeaways"
              ep[:key_takeaways].first(5).each { |t| lines << "- #{t}" }
              lines << ""
            end

            unless ep[:investment_signals].empty?
              lines << "### Investment Signals"
              ep[:investment_signals].each do |sig|
                sig = sig.is_a?(Hash) ? sig : JSON.parse(sig) rescue next
                lines << "- **[#{sig['sector']}]** #{sig['signal']} — #{sig['why_it_matters']}"
              end
              lines << ""
            end
          end

          lines << "---"
          lines << ""
        end

        # One-line mention for anything analyzed today but not featured, so nothing
        # silently disappears
        unless also_covered.empty?
          lines << "### Also Covered Today"
          lines << ""
          also_covered.each do |ep|
            take = ep[:thirty_second_take].to_s.strip
            line = "- **#{ep[:podcast_name]}**: #{ep[:title]}"
            line += " — #{take}" unless take.empty?
            lines << line
          end
          lines << ""
          lines << "---"
          lines << ""
        end

        # Footer
        lines << "_Crosslink Focus: #{VCTools::Podcast::CROSSLINK_SECTORS.join(' | ')}_"
        lines << ""
        lines << "---"
        lines << ""
        lines << "**Built by Marcello Battista**"
        lines << ""
        lines << "[Twitter](https://x.com/marc3llob) | [LinkedIn](https://www.linkedin.com/in/marcello-battista/)"

        lines.join("\n")
      end

      def store_digest(date, markdown, episode_count, titles = [])
        titles_json = titles.to_json
        existing = @digests.where(digest_date: date).first
        if existing
          @digests.where(id: existing[:id]).update(
            content_md:      markdown,
            episode_count:   episode_count,
            episode_titles:  titles_json,
            delivery_status: "pending"
          )
        else
          @digests.insert(
            digest_date:     date,
            content_md:      markdown,
            episode_count:   episode_count,
            episode_titles:  titles_json,
            delivery_status: "pending"
          )
        end
      end

      def send_email(date, analyzed, featured, also_covered)
        require "resend"
        require "dotenv/load"

        return puts "[Digest] No RESEND_API_KEY, skipping email" unless ENV["RESEND_API_KEY"]

        Resend.api_key = ENV["RESEND_API_KEY"]

        recipients = ENV.fetch("ALERT_TO_EMAIL", "marcellobattista@outlook.com")
                       .split(",").map(&:strip)

        html = VCTools::Podcast::DigestHtmlRenderer.new(
          date:          date,
          episode_count: analyzed.length,
          top_signals:   top_signals(analyzed),
          featured:      featured,
          also_covered:  also_covered
        ).render

        Resend::Emails.send({
          from:    "VC Signal Tools <onboarding@resend.dev>",
          to:      recipients,
          subject: "VC/Tech Podcast Digest - #{date}",
          html:    html
        })

        @digests.where(digest_date: date).update(
          sent_at:         Time.now.utc,
          delivery_status: "sent"
        )

      rescue => e
        puts "[Digest] Email error: #{e.message}"
        @digests.where(digest_date: date).update(delivery_status: "failed")
      end

    end
  end
end
