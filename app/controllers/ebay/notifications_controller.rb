module Ebay
  class NotificationsController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      # Log the raw request for debugging
      Rails.logger.info "eBay Notification Received"
      Rails.logger.info "Headers: #{request.headers.to_h.select { |k, _| k.start_with?('HTTP_') }}"
      Rails.logger.info "Body: #{request.raw_post}"

      # Parse the XML notification
      notification = Hash.from_xml(request.raw_post)
      Rails.logger.info "Parsed Notification: #{notification.inspect}"

      # Acknowledge receipt
      head :ok
    rescue => e
      Rails.logger.error "Error processing eBay notification: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      head :internal_server_error
    end
  end
end
