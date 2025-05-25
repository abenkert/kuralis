module DashboardHelper
  def activity_background_color(platform)
    case platform.to_s
    when "shopify"
      "linear-gradient(135deg, #13795b, #25a97a)"
    when "ebay"
      "linear-gradient(135deg, #e6a100, #ffc107)"
    when "system"
      "linear-gradient(135deg, #0d6efd, #5a9cff)"
    when "admin"
      "linear-gradient(135deg, #6f42c1, #9a71d2)"
    else
      "linear-gradient(135deg, #495057, #6c757d)"
    end
  end

  def activity_badge_background(platform)
    case platform.to_s
    when "shopify"
      "rgba(25, 135, 84, 0.1)"
    when "ebay"
      "rgba(255, 193, 7, 0.1)"
    when "system"
      "rgba(13, 110, 253, 0.1)"
    when "admin"
      "rgba(111, 66, 193, 0.1)"
    else
      "rgba(75, 85, 99, 0.1)"
    end
  end

  def activity_badge_color(platform)
    case platform.to_s
    when "shopify"
      "#198754"
    when "ebay"
      "#997404"
    when "system"
      "#0d6efd"
    when "admin"
      "#6f42c1"
    else
      "#4b5563"
    end
  end
end
