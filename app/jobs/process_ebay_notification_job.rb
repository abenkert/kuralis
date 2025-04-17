class ProcessEbayNotificationJob < ApplicationJob
  queue_as :default

  def perform(notification_data)
    case notification_data['NotificationEventName']
    when 'ORDERS_AWAITING_SHIPMENT'
      create_or_update_order(notification_data)
    when 'ORDER_PAID'
      update_order_payment(notification_data)
    end
  end

  private

  def create_or_update_order(data)
    order_data = data['OrderData']
    
    order = Order.find_or_initialize_by(
      platform: 'ebay',
      platform_order_id: order_data['OrderID']
    )

    order.assign_attributes(
      status: 'pending',
      payment_status: order_data['PaymentStatus'],
      total_price: order_data['TotalAmount'],
      # ... other attributes
    )

    order.save!
  end

  def update_order_payment(data)
    order = Order.find_by!(
      platform: 'ebay',
      platform_order_id: data['OrderID']
    )

    order.update!(
      payment_status: 'paid',
      paid_at: Time.current
    )
  end
end 