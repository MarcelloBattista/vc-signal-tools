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

                db.create_table?(:companies) do
                    primary_key :id
                    String :name, null: false
                    String :normalized_name, null: false, unique: true
                    DateTime :created_at, null: false
                    DateTime :updated_at, null: false
                end

                db.create_table?(:sectors) do
                    primary_key :id
                    String :name, null: false
                    String :normalized_name, null: false, unique: true
                    DateTime :created_at, null: false
                    DateTime :updated_at, null: false
                end

                db.create_table?(:episode_insights) do
                    primary_key :id
                    foreign_key :episode_id, :episodes, null: false
                    String :insight_uid, null: false
                    String :insight_type, null: false
                    String :speaker_label
                    String :category
                    String :claim, text: true
                    String :evidence, text: true
                    String :implication, text: true
                    Integer :timestamp_start_ms
                    Integer :timestamp_end_ms
                    String :people_json, text: true
                    String :metrics_json, text: true
                    Integer :score_importance
                    Integer :score_novelty
                    Integer :score_specificity
                    Integer :score_actionability
                    Integer :score_credibility
                    Float :ranking_score
                    String :ranking_bonuses_json, text: true
                    String :ranking_penalties_json, text: true
                    String :ranking_version
                    foreign_key :cluster_id, :episode_insight_clusters
                    DateTime :created_at, null: false
                    index [:episode_id]
                    index [:insight_type]
                    index [:ranking_score]
                    index [:insight_type, :ranking_score]
                    index [:episode_id, :insight_uid], unique: true
                end

                db.create_table?(:episode_insight_clusters) do
                    primary_key :id
                    foreign_key :episode_id, :episodes, null: false
                    String :theme, text: true
                    String :theme_summary, text: true
                    Integer :representative_insight_id
                    Integer :member_count, null: false, default: 0
                    DateTime :created_at, null: false
                    index [:episode_id]
                end

                db.create_table?(:episode_insight_companies) do
                    primary_key :id
                    foreign_key :insight_id, :episode_insights, null: false
                    foreign_key :company_id, :companies, null: false
                    index [:insight_id]
                    index [:company_id]
                end

                db.create_table?(:episode_insight_sectors) do
                    primary_key :id
                    foreign_key :insight_id, :episode_insights, null: false
                    foreign_key :sector_id, :sectors, null: false
                    index [:insight_id]
                    index [:sector_id]
                end
            end #self.setup end

            # Additive-only schema changes for tables that already exist in production.
            # create_table? is a no-op on existing tables, so column/index additions to
            # already-created tables must go through explicit, idempotent checks here.
            def self.migrate!
                db = connect

                add_column_if_missing(db, :transcript_chunks, :start_ms, Integer)
                add_column_if_missing(db, :transcript_chunks, :end_ms, Integer)

                add_column_if_missing(db, :episodes, :failed_stage, String)
                add_index_if_missing(db, :episodes, :podcast_id)

                add_column_if_missing(db, :episode_analyses, :thirty_second_take, String, text: true)
                add_column_if_missing(db, :episode_analyses, :insight_count, Integer)
                add_column_if_missing(db, :episode_analyses, :cluster_count, Integer)
                add_column_if_missing(db, :episode_analyses, :sections_json, String, text: true)

                # Pre-existing production drift: this column was added directly against
                # the live DB and used by digest_builder.rb, but was never declared here.
                add_column_if_missing(db, :daily_digests, :episode_titles, String, text: true)
            end

            def self.add_column_if_missing(db, table, column, type, **opts)
                return unless db.table_exists?(table)
                return if db.schema(table).map(&:first).include?(column)
                db.alter_table(table) { add_column column, type, **opts }
            end

            def self.add_index_if_missing(db, table, column)
                return unless db.table_exists?(table)
                return if db.indexes(table).values.any? { |idx| idx[:columns] == [column] }
                db.alter_table(table) { add_index column }
            end
        end # database end
    end # podcast end
end # VC Tools end
