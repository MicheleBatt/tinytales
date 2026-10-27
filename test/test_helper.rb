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
