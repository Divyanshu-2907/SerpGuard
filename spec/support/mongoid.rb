# frozen_string_literal: true

# These specs talk to a real MongoDB (config/mongoid.yml, test block), because
# the cache behaviour they cover - a unique index, a hash lookup, a second
# request hitting a stored row - is exactly the part a stubbed datastore would
# not prove.
RSpec.configure do |config|
  config.before(:suite) do
    # Declaring an index in the model does not build it; without this the
    # uniqueness guarantee is only the Ruby-side validation.
    Claim.create_indexes
  rescue Mongo::Error => error
    abort <<~MESSAGE
      Could not reach MongoDB for the test suite (#{error.class}: #{error.message}).

      Start a local mongod, or point MONGODB_URI_TEST at one:
        docker run -d -p 27017:27017 --name serpguard-mongo mongo:7
    MESSAGE
  end

  # No transactions to roll back, so state is cleared explicitly. Without this a
  # cache hit from an earlier example would silently satisfy a later one.
  config.before(:each) { Claim.delete_all }
end
