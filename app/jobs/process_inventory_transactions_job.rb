class ProcessInventoryTransactionsJob < ApplicationJob
  queue_as :inventory

  # Process pending inventory transactions for a product
  #
  # @param shop_id [Integer] ID of the shop to process
  # @param kuralis_product_id [Integer] ID of the product to process
  def perform(shop_id, kuralis_product_id)
    kuralis_product = KuralisProduct.find_by(id: kuralis_product_id)
    return unless kuralis_product

    # Skip if no unprocessed transactions
    return unless kuralis_product.inventory_transactions.where(processed: false).exists?

    # Process the transactions
    Rails.logger.info "Processing inventory transactions for product_id=#{kuralis_product_id}"
    InventorySyncService.process_pending_transactions(kuralis_product)
  end
end
