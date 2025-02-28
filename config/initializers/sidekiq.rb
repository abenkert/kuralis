Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
  config.queues = ['default', 'images']
  # config.periodic do |mgr|
  #   mgr.register('*/5 * * * *', 'FetchEbayOrdersJob', retry: false)
  #   mgr.register('*/5 * * * *', 'FetchShopifyOrdersJob', retry: false)
  # end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0') }
end 