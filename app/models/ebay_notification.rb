class EbayNotification < ApplicationRecord
  belongs_to :shopify_ebay_account

  # Example of handling an order notification
  def self.handle_notification(notification_data)
    case notification_data['NotificationEventName']
    when 'ORDERS_AWAITING_SHIPMENT'
      process_new_order(notification_data)
    when 'ORDER_PAID'
      update_order_payment_status(notification_data)
    when 'ORDER_SHIPPED'
      update_order_shipping_status(notification_data)
    end
  end
end 