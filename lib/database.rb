# frozen_string_literal: true

require "sequel" # same as import in python
require "json"

module VCTools # consistent naming
    module Podcast # this file belongs to podcast module
        class Database # implementation of the database class
            DB_PATH = File.expand_path("../db/signals.sqlite3", __dir__) # Upper case means a constant, dir return current file directory

            def self.connect
                @db ||= Sequel.sqlite(DB_PATH)
            end

            def self.setup!
                db = connect

                db.create_table?(:podcasts) do
                    primary_key :id
                    String :name, null: false
                    String :rss_url, null: false, unique: true
                    String :category_tags, text: true
                    TrueClass :active, default: true, null: false
                    DateTime :created_at, null: false
                    DateTime :updated_at, null: false
                end

                db.create_table?(:episodes) do
                    primary_key :id
                    foreign_key :podcast_id, :podcasts, null:false
                    String :guid, null: false, unique: true
                    String :title, null: false
                    DateTime :published_at
                    String :audio_url
                    Integer :duration_sec
                    String :status, null: false, default: "new"
                    DateTime :created_at, null: false
                    DateTime :updated_at, null: false
                end
                
                db.create_table?(:transcripts) do
                    primary_key :id
                    foreign_key :episode_id, :episodes, null:false, unique: true
                    String :provider, null: false
                    String :engine, null: false, default: "local"
                    String :model, null: false
                    String :model_version
                    String :language
                    String :raw_text, text: true, null: false
                    Integer :token_estimate, null: false, default: 0
                    Integer :input_seconds
                    Float :confidence_score
                    Float :processing_seconds
                    DateTime :created_at, null: false
                end

                db.create_table?(:transcript_chunks) do
                    primary_key :id
                    foreign_key :transcript_id, :transcripts, null: false
                    Integer :chunk_index, null: false
                    String :text, text: true, null: false
                    Integer :token_estimate, null: false, default: 0
                    index [:transcript_id, :chunk_index], unique: true
                end

                db.create_table?(:episode_analyses) do
                    primary_key :id
                    foreign_key :episode_id, :episodes, null: false, unique: true
                    String :summary_md, text: true
                    String :key_takeaways_json, text: true
                    String :investment_signals_json, text: true
                    String :risks_json, text: true
                    String :action_items_json, text: true
                    String :engine, null: false, default: "local"
                    String :model, null: false
                    String :model_version
                    String :prompt_version
                    Float :temperature
                    Integer :token_input_estimate
                    Integer :token_output_estimate
                    Float :processing_seconds
                    DateTime :created_at, null: false
                end

                db.create_table?(:daily_digests) do
                    primary_key :id
                    Date :digest_date, null: false, unique: true
                    String :content_md, text: true, null: false
                    Integer :episode_count, null: false, default: 0
                    DateTime :sent_at
                    String :delivery_status, null: false, default: "pending"
                end

                db.create_table?(:processing_jobs) do
                    primary_key :id
                    String :job_type, null: false
                    String :entity_type, null: false
                    Integer :entity_id, null: false
                    String :provider
                    String :engine
                    String :model
                    String :worker_host
                    String :run_metadata_json, text: true
                    String :status, null: false, default: "queued"
                    String :error_message, text: true
                    Integer :attempts, null: false, default: 0
                    DateTime :started_at
                    DateTime :finished_at
                    DateTime :created_at, null: false
                    DateTime :updated_at, null: false
                end
            end #self.setup end
        end # database end
    end # podcast end
end # VC Tools end
