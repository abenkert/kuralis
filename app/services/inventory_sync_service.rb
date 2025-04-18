class InventorySyncService
  # Process unprocessed inventory transactions and sync to platforms
  #
  # @param kuralis_product [KuralisProduct] The product to sync inventory for
  # @return [Array<InventoryTransaction>] Processed transactions
  def self.process_pending_transactions(kuralis_product)
    # Find unprocessed transactions for this product
    pending_transactions = kuralis_product.inventory_transactions
                            .where(processed: false)
                            .order(created_at: :asc)

    return [] if pending_transactions.empty?

    # Group by origin platform to avoid updating the originating platform
    transactions_by_platform = pending_transactions.group_by do |transaction|
      transaction.order&.platform&.downcase
    end

    # Process transactions from each platform
    processed_transactions = []
    p "================================================"
    p pending_transactions
    p "================================================"
    p transactions_by_platform
    p "================================================"
    p transactions_by_platform[nil]
    p "================================================"
    # First, mark all non-platform specific transactions (like manual adjustments)
    if transactions_by_platform[nil].present?
      # These are manual adjustments or reconciliations with no platform association
      process_transactions(transactions_by_platform[nil], kuralis_product, nil)
      processed_transactions.concat(transactions_by_platform[nil])
    end

    # Now process platform-specific transactions
    transactions_by_platform.each do |platform, transactions|
      next if platform.nil? # Already processed above

      # Don't update the platform that originated these transactions
      process_transactions(transactions, kuralis_product, platform)
      processed_transactions.concat(transactions)
    end

    processed_transactions
  end

  private

  # Process a group of transactions and sync to other platforms
  #
  # @param transactions [Array<InventoryTransaction>] Transactions to process
  # @param kuralis_product [KuralisProduct] The product to sync
  # @param skip_platform [String, nil] Platform to skip updating
  def self.process_transactions(transactions, kuralis_product, skip_platform)
    return if transactions.empty?

    p "================================================"
    p transactions
    p "================================================"
    # Sync inventory to other platforms
    PlatformSyncService.sync_product(
      kuralis_product,
      skip_platform: skip_platform
    )

    # Mark all transactions as processed
    transaction_ids = transactions.map(&:id)
    InventoryTransaction.where(id: transaction_ids).update_all(processed: true)

    Rails.logger.info "Processed #{transactions.count} inventory transactions for product_id=#{kuralis_product.id}, skip_platform=#{skip_platform || 'none'}"
  end
end
