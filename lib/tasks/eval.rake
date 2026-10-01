# frozen_string_literal: true

# The accuracy benchmark. NOT part of RSpec: every claim spends real Claude and
# SerpApi calls, while the test suite is offline by construction.
#
#   bin/rails eval:run                      # localhost:3000, whole dataset
#   EVAL_BASE_URL=... EVAL_LIMIT=5 ...      # somewhere else, first 5 claims
#   EVAL_CLEAR_CACHE=1 bin/rails eval:run   # empty the local cache first
namespace :eval do
  desc "Score SerpGuard against eval/claims.yml (makes paid live calls)"
  task run: :environment do
    require_relative "../../eval/runner"

    DEV_DATABASE = "serpguard_development"

    database = Mongoid.default_client.database.name
    unless database == DEV_DATABASE
      abort "eval:run refuses to run against #{database.inspect}. " \
            "It is meant for #{DEV_DATABASE.inspect} with an empty cache - " \
            "blank MONGODB_URI in .env and try again."
    end

    if Claim.count.positive?
      if ENV["EVAL_CLEAR_CACHE"] == "1"
        deleted = Claim.collection.delete_many({}).deleted_count
        puts "Cleared #{deleted} cached verdict(s) from #{database}."
      else
        abort "#{database} already holds #{Claim.count} cached verdict(s), which would " \
              "answer some claims without a search and make the numbers meaningless. " \
              "Re-run with EVAL_CLEAR_CACHE=1 to empty it."
      end
    end

    api_key = ENV["EVAL_API_KEY"].presence ||
              ENV["SERPGUARD_API_KEYS"].to_s.split(",").first&.strip
    abort "No API key. Set EVAL_API_KEY, or SERPGUARD_API_KEYS in .env." if api_key.blank?

    runner = SerpGuard::EvalRunner.new(
      base_url: ENV["EVAL_BASE_URL"].presence || "http://localhost:3000",
      api_key: api_key,
      # Only used to read the balance from account.json, which is not a search.
      serpapi_key: ENV["SERPAPI_KEY"],
      limit: ENV["EVAL_LIMIT"].presence&.to_i
    )

    runner.call
  end
end
