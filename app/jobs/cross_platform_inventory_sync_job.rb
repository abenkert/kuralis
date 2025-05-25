require "net/http"

class CrossPlatformInventorySyncJob < ApplicationJob
  queue_as :inventory

  # Retry configuration with polynomial backoff
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  retry_on InventoryService::PlatformSyncError, wait: :polynomially_longer, attempts: 3

  # Specific handling for network-related errors
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: 30.seconds, attempts: 3
  retry_on OpenSSL::SSL::SSLError, wait: 10.seconds, attempts: 2

  def perform(shop_id, kuralis_product_id, skip_platform = nil)
    @shop = Shop.find(shop_id)
    @kuralis_product = @shop.kuralis_products.find(kuralis_product_id)
    @skip_platform = skip_platform&.downcase

    Rails.logger.info "Starting cross-platform sync for product_id=#{kuralis_product_id}, skip_platform=#{skip_platform}"

    # Track sync results
    sync_results = {}
    errors = []

    # Sync with Shopify if connected and not skipped
    if should_sync_shopify?
      sync_results[:shopify] = sync_shopify_inventory
      errors << sync_results[:shopify][:error] if sync_results[:shopify][:error]
    end

    # Sync with eBay if connected and not skipped
    if should_sync_ebay?
      sync_results[:ebay] = sync_ebay_inventory
      errors << sync_results[:ebay][:error] if sync_results[:ebay][:error]
    end

    # Mark all unprocessed transactions as processed if sync was successful
    if errors.empty?
      mark_transactions_processed
      Rails.logger.info "Successfully synced product_id=#{kuralis_product_id} across platforms"
    else
      # Create notification for sync failures
      create_sync_failure_notification(errors, sync_results)
      Rails.logger.error "Failed to sync product_id=#{kuralis_product_id}: #{errors.join(', ')}"
    end

    # Update internal platform records regardless of API success
    update_internal_platform_records

    sync_results
  end

  private

  def should_sync_shopify?
    @kuralis_product.shopify_product.present? && @skip_platform != "shopify"
  end

  def should_sync_ebay?
    @kuralis_product.ebay_listing.present? && @skip_platform != "ebay"
  end

  def sync_shopify_inventory
    begin
      Rails.logger.info "Syncing Shopify inventory for product_id=#{@kuralis_product.id}"

      service = Shopify::InventoryService.new(
        @kuralis_product.shopify_product,
        @kuralis_product
      )

      success = service.update_inventory

      if success
        { success: true, platform: "shopify" }
      else
        error_msg = "Shopify inventory update failed for product_id=#{@kuralis_product.id}"
        Rails.logger.error error_msg
        { success: false, platform: "shopify", error: error_msg }
      end

    rescue => e
      error_msg = "Shopify sync error for product_id=#{@kuralis_product.id}: #{e.message}"
      Rails.logger.error error_msg
      Rails.logger.error e.backtrace.join("\n")
      { success: false, platform: "shopify", error: error_msg }
    end
  end

  def sync_ebay_inventory
    begin
      Rails.logger.info "Syncing eBay inventory for product_id=#{@kuralis_product.id}"

      service = Ebay::InventoryService.new(
        @kuralis_product.ebay_listing,
        @kuralis_product
      )

      success = service.update_inventory

      if success
        { success: true, platform: "ebay" }
      else
        error_msg = "eBay inventory update failed for product_id=#{@kuralis_product.id}"
        Rails.logger.error error_msg
        { success: false, platform: "ebay", error: error_msg }
      end

    rescue => e
      error_msg = "eBay sync error for product_id=#{@kuralis_product.id}: #{e.message}"
      Rails.logger.error error_msg
      Rails.logger.error e.backtrace.join("\n")
      { success: false, platform: "ebay", error: error_msg }
    end
  end

  def mark_transactions_processed
    # Mark all unprocessed inventory transactions as processed
    unprocessed_count = @kuralis_product.inventory_transactions
                                        .where(processed: false)
                                        .update_all(processed: true)

    Rails.logger.info "Marked #{unprocessed_count} inventory transactions as processed for product_id=#{@kuralis_product.id}"
  end

  def update_internal_platform_records
    # Update internal Shopify product record
    if @kuralis_product.shopify_product.present?
      @kuralis_product.shopify_product.update!(
        quantity: @kuralis_product.base_quantity,
        price: @kuralis_product.base_price,
        status: @kuralis_product.status == "active" ? "active" : "archived"
      )
    end

    # Update internal eBay listing record
    if @kuralis_product.ebay_listing.present?
      ebay_listing = @kuralis_product.ebay_listing

      # Calculate the new total_quantity to maintain the validation constraint
      # quantity = total_quantity - quantity_sold
      # Therefore: total_quantity = quantity + quantity_sold
      new_total_quantity = @kuralis_product.base_quantity + ebay_listing.quantity_sold

      ebay_listing.update!(
        quantity: @kuralis_product.base_quantity,
        total_quantity: new_total_quantity,
        sale_price: @kuralis_product.base_price,
        ebay_status: @kuralis_product.status == "active" ? "active" : "completed"
      )
    end
  end

  def create_sync_failure_notification(errors, sync_results)
    failed_platforms = sync_results.select { |_, result| !result[:success] }.keys

    Notification.create!(
      shop_id: @shop.id,
      title: "Platform Sync Failure",
      message: "Failed to sync inventory for '#{@kuralis_product.title}' on #{failed_platforms.join(', ')}",
      category: "inventory",
      status: "error",
      metadata: {
        product_id: @kuralis_product.id,
        failed_platforms: failed_platforms,
        errors: errors,
        sync_results: sync_results
      }
    )
  end
end
