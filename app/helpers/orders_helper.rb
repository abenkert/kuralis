module OrdersHelper
  def shipment_status_color_class(status)
    case status&.downcase
    when 'fulfilled'
      'bg-success'
    when 'in_progress'
      'bg-info'
    when 'not_started', 'unfulfilled'
      'bg-warning'
    when 'cancelled'
      'bg-danger'
    else
      'bg-secondary'
    end
  end

  def fulfillment_status_label(status)
    case status&.downcase
    when 'fulfilled'
      'Shipped'
    when 'in_progress'
      'Partially Shipped'
    when 'cancelled'
      'Cancelled'
    when 'not_started', 'unfulfilled'
      'Awaiting Shipment'
    else
      'Unknown'
    end
  end

  def payment_status_color_class(status)
    case status&.downcase
    when 'paid'
      'bg-success'
    when 'partially_refunded'
      'bg-warning'
    when 'incomplete', 'pending'
      'bg-danger'
    else
      'bg-secondary'
    end
  end
end 