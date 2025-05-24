class InventoryHealthCheckJob < ApplicationJob
  queue_as :monitoring

  # Run this job every 15 minutes for active monitoring
  def perform
    Rails.logger.info "Starting scheduled inventory health check"

    # Check health for all shops
    Shop.active.find_each do |shop|
      begin
        health_summary = InventoryMonitoringService.check_inventory_health(shop.id)

        # Log summary for each shop
        Rails.logger.info "Health check completed for shop_id=#{shop.id}: #{health_summary[:overall_status]} " \
                         "(#{health_summary[:total_alerts]} alerts)"

        # Store health metrics in cache for dashboard
        Rails.cache.write(
          "inventory_health:#{shop.id}",
          health_summary,
          expires_in: 20.minutes
        )

      rescue => e
        Rails.logger.error "Failed health check for shop_id=#{shop.id}: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")

        # Create error notification
        Notification.create!(
          shop_id: shop.id,
          title: "Health Check Error",
          message: "Failed to perform inventory health check: #{e.message}",
          category: "system",
          status: "error",
          metadata: {
            error: e.message,
            error_class: e.class.name,
            timestamp: Time.current
          }
        )
      end
    end

    Rails.logger.info "Completed scheduled inventory health check"
  end
end
