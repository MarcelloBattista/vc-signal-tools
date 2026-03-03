# frozen_string_literal: true

require "yaml"
require "rss"
require "open-uri"
require "time"
require "json"

require_relative "database"

module VCTools
  module Podcast
    class Ingestor

        FEEDS_PATH = File.expand_path("../config/podcast_feeds.yml", __dir__)

        def initialize
            @db = VCTools::Podcast::Database.connect
            @podcasts = @db[:podcasts]
            @episodes = @db[:episodes]
        end

        def run
            feeds = load_feeds
            puts "[Ingestor] Loaded #{feeds.length} feeds"

            feeds.each do |feed|
                ingest_feed(feed)
            end
        end
        
        private

        def load_feeds
            config = YAML.load_file(FEEDS_PATH)
            config.fetch("podcasts")
        end

        def ingest_feed(feed)
            puts "[Ingestor] Processing: #{feed["name"]}"

            rss = fetch_rss(feed["url"])

            return false if rss.nil?

            podcast = upsert_podcast(feed)

            max = feed["max_episodes_per_run"] || 5
            count = 0
            rss.items.each do |item|
                break if count >= max
                count += 1 if upsert_episode(podcast[:id], item)
            end

            return count

        end

        def fetch_rss(url)
            f = URI.open(url)
            RSS::Parser.parse(f, false)

            rescue => e
            
            puts "[Ingestion] Failed to fetch/parse RSS #{e.message}"
            nil
            
        end

        def upsert_podcast(feed)
          exists = @podcasts.where(rss_url: feed["url"]).first
          now = Time.now.utc
          
          if exists
            @podcasts.where(id: exists[:id]).update(updated_at: now) # update existing row

            return exists # return existing row
            
          else # row doesnt exist, insert a new row
            id = @podcasts.insert(
            name: feed["name"],
            rss_url: feed["url"],
            category_tags: Array(feed["tags"]).join(","),
            active: true,
            created_at: now,
            updated_at: now
            )  

            return @podcasts.where(id: id).first # return new row
          end
        
        end
        
        def upsert_episode(podcast_id, item)
            guid = item.guid&.content || item.link
            return false if guid.nil?

            return false if @episodes.where(guid: guid).count > 0

            now = Time.now.utc
            pub_time = item.pubDate ? Time.parse(item.pubDate.to_s).utc : now
            audio_url = item.enclosure&.url

            @episodes.insert(
                podcast_id:   podcast_id,
                guid:         guid,
                title:        item.title.to_s.strip,
                published_at: pub_time,
                audio_url:    audio_url,
                duration_sec: nil,
                status:       "new",
                created_at:   now,
                updated_at:   now
            )
            true

        rescue => e
            puts "[Ingestor] Episode insert error (#{item.title}): #{e.message}"
            false
        end

    end
  end
end