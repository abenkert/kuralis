module Ebay
  class NotificationsController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      # Log ALL request details
      Rails.logger.info "========== eBay Notification Received =========="
      Rails.logger.info "Request Method: #{request.method}"
      Rails.logger.info "Request URL: #{request.url}"
      Rails.logger.info "Remote IP: #{request.remote_ip}"
      Rails.logger.info "Content Type: #{request.content_type}"
      Rails.logger.info "All Headers: #{request.headers.to_h}"
      Rails.logger.info "Raw Body: #{request.raw_post}"
      Rails.logger.info "Params: #{params.inspect}"

      begin
        # Parse the SOAP XML
        doc = Nokogiri::XML(request.raw_post)
        Rails.logger.info "Parsed XML: #{doc}"

        # Extract notification details
        notification_type = doc.at_xpath('//*[contains(local-name(), "Notification")]')&.name
        event_time = doc.at_xpath("//EventTime")&.text
        item_id = doc.at_xpath("//Item/ItemID")&.text

        # Log structured notification data
        Rails.logger.info "Notification Type: #{notification_type}"
        Rails.logger.info "Event Time: #{event_time}"
        Rails.logger.info "Item ID: #{item_id}"
        Rails.logger.info "========== End eBay Notification =========="

        # Create a dedicated notifications log file
        FileUtils.mkdir_p(Rails.root.join("log"))
        notification_logger = Logger.new(Rails.root.join("log", "ebay_notifications.log"))
        notification_logger.info({
          notification_type: notification_type,
          event_time: event_time,
          item_id: item_id,
          raw_body: request.raw_post,
          headers: request.headers.to_h.select { |k, _| k.start_with?("HTTP_") },
          timestamp: Time.current
        }.to_json)

        # Always respond with 200 OK to acknowledge receipt
        head :ok
      rescue => e
        Rails.logger.error "Error processing eBay notification: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        Rails.logger.error "Raw request body was: #{request.raw_post}"
        head :internal_server_error
      end
    end

    # Test endpoint to verify the controller is accessible
    def test
      Rails.logger.info "eBay Notifications test endpoint accessed at #{Time.current}"

      host = ENV["APPLICATION_HOST"] || request.host_with_port

      response_data = {
        status: "success",
        message: "eBay notifications endpoint is accessible",
        timestamp: Time.current,
        current_url: request.original_url,
        notification_url: host.present? ? "https://#{host}/ebay/notifications" : "URL cannot be determined (APPLICATION_HOST not set)"
      }

      render json: response_data
    end
  end
end
