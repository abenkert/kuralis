require 'openai'

# Configure the OpenAI client
OpenAI.configure do |config|
  config.access_token = ENV.fetch('OPENAI_API_KEY', nil)
  config.organization_id = ENV.fetch('OPENAI_ORGANIZATION_ID', nil) # Optional, only needed for organization accounts
end

# Log OpenAI configuration status on startup
Rails.logger.info "OpenAI API Key configured: #{ENV['OPENAI_API_KEY'].present? ? 'Yes' : 'No'}"
Rails.logger.info "OpenAI Organization ID configured: #{ENV['OPENAI_ORGANIZATION_ID'].present? ? 'Yes' : 'No'}" 