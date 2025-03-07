class NotificationService
  def self.create(shop:, title:, message:, category:, status: 'info', metadata: {}, failed_product_ids: [], successful_product_ids: [])
    Notification.create!(
      shop: shop,
      title: title,
      message: message,
      category: category,
      status: status,
      metadata: metadata,
      failed_product_ids: failed_product_ids,
      successful_product_ids: successful_product_ids,
      read: false
    )
  end
  
  # Convenience methods for different status types
  def self.info(shop:, title:, message:, category:, **options)
    create(shop: shop, title: title, message: message, category: category, status: 'info', **options)
  end
  
  def self.success(shop:, title:, message:, category:, **options)
    create(shop: shop, title: title, message: message, category: category, status: 'success', **options)
  end
  
  def self.warning(shop:, title:, message:, category:, **options)
    create(shop: shop, title: title, message: message, category: category, status: 'warning', **options)
  end
  
  def self.error(shop:, title:, message:, category:, **options)
    create(shop: shop, title: title, message: message, category: category, status: 'error', **options)
  end
end 