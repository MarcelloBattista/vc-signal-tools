# frozen_string_literal: true

module VCTools
  module Podcast
    module EpisodeSelection
      # Pick episodes evenly across podcasts so one feed doesn't dominate a run,
      # always preferring each podcast's most recently published pending episode
      # first — a fresh episode should never wait behind older backlog at any
      # pipeline stage.
      def self.diverse(dataset, status:, limit: nil)
        all = dataset.where(status: status).order(:published_at).all
        return all unless limit && all.length > limit

        grouped = all.group_by { |ep| ep[:podcast_id] }
        result  = []
        per_pod = (limit / grouped.keys.length.to_f).ceil

        grouped.each_value { |eps| result.concat(eps.last(per_pod)) }

        result.sort_by { |ep| ep[:published_at] }.reverse.first(limit)
      end
    end
  end
end
