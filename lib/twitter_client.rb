require "x"
require "dotenv/load"

module VCTools
  def self.twitter_client
    @client ||= X::Client.new(bearer_token: ENV.fetch("X_BEARER_TOKEN"))
  end
end
