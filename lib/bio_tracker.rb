require "sequel"
require "json"
require_relative "twitter_client"
require_relative "notifier"

module VCTools
  class BioTracker
    DB_PATH = File.expand_path("../../db/signals.sqlite3", __FILE__)
    BATCH_SIZE = 100
    TRACKED_FIELDS = %w[name description location url].freeze

    def initialize
      @db = Sequel.sqlite(DB_PATH)
      setup_db
    end

    def run
      usernames = load_watchlist
      puts "[#{Time.now}] Checking #{usernames.size} users..."

      usernames.each_slice(BATCH_SIZE) do |batch|
        check_batch(batch)
        sleep 1 # be polite to the API
      end

      puts "[#{Time.now}] Done."
    end

    private

    def setup_db
      @db.create_table?(:profile_snapshots) do
        String :username, primary_key: true
        String :data, text: true       # JSON blob of tracked fields
        DateTime :updated_at
      end

      @db.create_table?(:profile_changes) do
        primary_key :id
        String :username
        String :field
        String :old_value, text: true
        String :new_value, text: true
        DateTime :detected_at
      end
    end

    def load_watchlist
      watchlist_path = File.expand_path("../../config/watchlist.yml", __FILE__)
      require "yaml"
      YAML.load_file(watchlist_path)["usernames"]
    end

    def check_batch(usernames)
      usernames_param = usernames.join(",")
      response = VCTools.twitter_client.get(
        "users/by?usernames=#{usernames_param}&user.fields=name,description,location,url,entities"
      )

      users = response["data"] || []
      users.each { |user| compare_and_store(user) }

    rescue => e
      puts "[ERROR] Batch failed: #{e.message}"
    end

    def compare_and_store(user)
      username = user["name"] # display name — use login for lookup
      login    = user["username"]
      snapshot_table = @db[:profile_snapshots]

      current = extract_fields(user)
      existing = snapshot_table.where(username: login).first

      if existing
        old = JSON.parse(existing[:data])
        changes = detect_changes(login, old, current)
        Notifier.alert(changes) if changes.any?
      end

      snapshot_table.insert_conflict(target: :username, update: {
        data: current.to_json,
        updated_at: Time.now
      }).insert(username: login, data: current.to_json, updated_at: Time.now)
    end

    def extract_fields(user)
      url = user.dig("entities", "url", "urls", 0, "expanded_url") ||
            user.dig("url")
      {
        "name"        => user["name"],
        "description" => user["description"],
        "location"    => user["location"],
        "url"         => url
      }
    end

    def detect_changes(login, old, current)
      changes = []
      TRACKED_FIELDS.each do |field|
        next if old[field] == current[field]
        change = {
          username:    login,
          field:       field,
          old_value:   old[field],
          new_value:   current[field],
          detected_at: Time.now
        }
        @db[:profile_changes].insert(change)
        changes << change
        puts "[CHANGE] @#{login} changed #{field}: #{old[field].inspect} → #{current[field].inspect}"
      end
      changes
    end
  end
end
