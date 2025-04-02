require "sidekiq"
require "sidekiq-scheduler"

Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
  config.queues = [ "default", "images", "ebay", "shopify" ]

  # Load the schedule
  schedule_file = File.expand_path("../../sidekiq.yml", __FILE__)
  if File.exist?(schedule_file)
    schedule = YAML.load_file(schedule_file)
    Sidekiq::Scheduler.enabled = true
    Sidekiq::Scheduler.dynamic = true
    Sidekiq.schedule = schedule[:scheduler][:schedule]
  end
  # config.periodic do |mgr|
  #   mgr.register('*/5 * * * *', 'FetchEbayOrdersJob', retry: false)
  #   mgr.register('*/5 * * * *', 'FetchShopifyOrdersJob', retry: false)
  # end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
