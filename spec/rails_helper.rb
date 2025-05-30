# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
require 'rspec/rails'

# Add additional requires below this line. Rails is not loaded until this point!
require 'factory_bot_rails'
require 'webmock/rspec'
require 'vcr'
require 'database_cleaner/active_record'
require 'timecop'
# require 'simplecov'

# Start SimpleCov for code coverage (temporarily disabled)
# SimpleCov.start 'rails' do
#   add_filter '/spec/'
#   add_filter '/config/'
#   add_filter '/vendor/'
#
#   add_group 'Models', 'app/models'
#   add_group 'Controllers', 'app/controllers'
#   add_group 'Services', 'app/services'
#   add_group 'Jobs', 'app/jobs'
#   add_group 'Helpers', 'app/helpers'
#
#   # Set minimum coverage threshold
#   minimum_coverage 70
# end

# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories.
Dir[Rails.root.join('spec', 'support', '**', '*.rb')].sort.each { |f| require f }

# Checks for pending migrations and applies them before tests are run.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # Include FactoryBot methods
  config.include FactoryBot::Syntax::Methods

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # RSpec Rails can automatically mix in different behaviours to your tests
  # based on their file location, for example enabling you to call `get` and
  # `post` in specs under `spec/controllers`.
  config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!

  # Database Cleaner configuration (temporarily disabled)
  # config.before(:suite) do
  #   if Rails.env.test?
  #     DatabaseCleaner.clean_with(:deletion)
  #   end
  # end

  # config.before(:each) do
  #   DatabaseCleaner.strategy = :transaction
  #   DatabaseCleaner.start
  # end

  # config.before(:each, type: :feature) do
  #   DatabaseCleaner.strategy = :deletion
  #   DatabaseCleaner.start
  # end

  # config.after(:each) do
  #   DatabaseCleaner.clean
  # end

  # Redis cleanup for inventory system
  config.before(:each) do
    # Clear Redis cache before each test
    Rails.cache.clear if Rails.cache.respond_to?(:clear)

    # Clear any Redis locks
    if defined?(Redis) && Rails.env.test?
      begin
        redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
        redis.flushdb
      rescue Redis::CannotConnectError
        # Redis not available in test, skip
      end
    end
  end

  # Clean up background jobs
  config.before(:each) do
    # Clear Sidekiq jobs in test mode
    if defined?(Sidekiq)
      begin
        Sidekiq::Queue.new.clear
        Sidekiq::RetrySet.new.clear
        Sidekiq::ScheduledSet.new.clear
        Sidekiq::DeadSet.new.clear
      rescue => e
        # If Sidekiq isn't running or configured, just skip
        Rails.logger.debug "Sidekiq cleanup skipped: #{e.message}" if Rails.logger
      end
    end
  end

  # Time travel cleanup
  config.after(:each) do
    Timecop.return
  end

  # WebMock configuration
  config.before(:each) do
    WebMock.reset!
    WebMock.disable_net_connect!(
      allow_localhost: true,
      allow: [
        'chromedriver.storage.googleapis.com',
        'github.com/mozilla/geckodriver/releases',
        'selenium-release.storage.googleapis.com'
      ]
    )
  end
end

# VCR Configuration for API testing
VCR.configure do |config|
  config.cassette_library_dir = 'spec/vcr_cassettes'
  config.hook_into :webmock
  config.default_cassette_options = {
    record: :new_episodes,
    allow_unused_http_interactions: false
  }

  # Filter sensitive data
  config.filter_sensitive_data('<SHOPIFY_API_KEY>') { ENV['SHOPIFY_API_KEY'] }
  config.filter_sensitive_data('<SHOPIFY_SECRET>') { ENV['SHOPIFY_SECRET'] }
  config.filter_sensitive_data('<EBAY_APP_ID>') { ENV['EBAY_APP_ID'] }
  config.filter_sensitive_data('<EBAY_CERT_ID>') { ENV['EBAY_CERT_ID'] }
  config.filter_sensitive_data('<EBAY_DEV_ID>') { ENV['EBAY_DEV_ID'] }
  config.filter_sensitive_data('<OPENAI_API_KEY>') { ENV['OPENAI_API_KEY'] }

  # Ignore localhost
  config.ignore_localhost = true

  # Configure for different environments
  config.configure_rspec_metadata!
end

# Shoulda Matchers configuration
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
