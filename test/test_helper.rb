ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/fake_facebook_client"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    fixtures :all

    # Nessun test parla davvero con Facebook: ogni test ha il suo client finto.
    setup do
      @facebook = FakeFacebookClient.new
      SocialPublishers::Facebook.client_builder = ->(_page) { @facebook }
    end
  end
end

# I file caricati durante i test (Active Storage del test, in tmp/storage) non servono dopo: via a fine esecuzione.
Minitest.after_run { FileUtils.rm_rf(Dir.glob(Rails.root.join("tmp/storage/*"))) }
