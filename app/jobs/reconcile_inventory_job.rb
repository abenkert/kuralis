class ReconcileInventoryJob < ApplicationJob
  queue_as :default

  # How many products to process per batch
  BATCH_SIZE = 100

  # Retry options specific to this job
  retry_on StandardError, wait: :exponentially_longer, attempts: 3

  def perform(shop_id = nil, options = {})
    # Track start time for performance monitoring
    start_time = Time.current

    # Set defaults
    options = {
      batch_size: BATCH_SIZE,
      recently_updated_only: false
    }.merge(options)

    if shop_id
      # Process a specific shop
      reconcile_for_shop(shop_id, options)
    else
      # Process all shops, with a small delay between each to prevent overloading
      Shop.find_each do |shop|
        # Skip if no products
        next unless shop.kuralis_products.exists?

        # Process each shop in its own job to improve parallelization
        ReconcileInventoryJob.perform_later(shop.id, options)
      end
    end

    # Log completion time
    duration = Time.current - start_time
    if shop_id
      Rails.logger.info "Completed inventory reconciliation for shop_id=#{shop_id} in #{duration.round(2)}s"
    else
      Rails.logger.info "Scheduled inventory reconciliation for all shops in #{duration.round(2)}s"
    end
  end

  private

  def reconcile_for_shop(shop_id, options)
    shop = Shop.find(shop_id)
    count = 0
    errors = 0

    # Build the query for products to reconcile
    products_scope = shop.kuralis_products

    # Optionally limit to recently updated products only
    if options[:recently_updated_only]
      products_scope = products_scope.where("updated_at > ?", 24.hours.ago)
    end

    # Process in batches to prevent memory issues with large datasets
    products_scope.find_in_batches(batch_size: options[:batch_size]) do |batch|
      batch.each do |product|
        begin
          InventoryService.reconcile_inventory(kuralis_product: product)
          count += 1
        rescue => e
          errors += 1
          Rails.logger.error "Failed to reconcile product_id=#{product.id}: #{e.message}"
        end
      end

      # Log progress for larger shops
      Rails.logger.info "Reconciled batch of #{options[:batch_size]} products for shop_id=#{shop_id}, #{count} processed, #{errors} errors"

      # Small sleep to allow other processes to run
      sleep(0.1)
    end

    # Create notification if there were errors
    if errors > 0
      Notification.create!(
        shop_id: shop_id,
        title: "Inventory Reconciliation",
        message: "Completed with #{errors} errors. Please check logs.",
        category: "inventory",
        status: errors > 10 ? "error" : "warning",
        metadata: {
          processed: count,
          errors: errors
        }
      )
    end

    Rails.logger.info "Completed inventory reconciliation for shop_id=#{shop_id}: #{count} products processed, #{errors} errors"
  end
end
