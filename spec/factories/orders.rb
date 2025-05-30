FactoryBot.define do
  factory :order do
    shop
    platform { "ebay" }
    sequence(:platform_order_id) { |n| "#{rand(10..99)}-#{rand(10000..99999)}-#{rand(10000..99999)}" }
    sequence(:platform_order_number) { |n| "ORDER-#{n}" }
    customer_name { Faker::Name.name }
    status { "NOT_STARTED" }
    fulfillment_status { "NOT_STARTED" }
    payment_status { "PAID" }
    subtotal { Faker::Commerce.price(range: 20.0..200.0) }
    shipping_cost { Faker::Commerce.price(range: 5.0..15.0) }
    total_price { subtotal + shipping_cost }
    order_placed_at { 2.hours.ago }
    last_synced_at { 1.hour.ago }

    shipping_address do
      {
        "name" => customer_name,
        "street1" => Faker::Address.street_address,
        "city" => Faker::Address.city,
        "state" => Faker::Address.state_abbr,
        "postal_code" => Faker::Address.zip_code,
        "country" => "US"
      }
    end

    trait :shopify do
      platform { "shopify" }
      platform_order_id { "##{rand(1000..9999)}" }
    end

    trait :fulfilled do
      fulfillment_status { "FULFILLED" }
      status { "FULFILLED" }
    end

    trait :cancelled do
      fulfillment_status { "CANCELLED" }
      status { "CANCELLED" }
    end

    trait :with_order_items do
      after(:create) do |order|
        create_list(:order_item, 2, order: order, platform: order.platform)
      end
    end

    trait :recent do
      order_placed_at { 30.minutes.ago }
      last_synced_at { 15.minutes.ago }
    end

    trait :old do
      order_placed_at { 30.days.ago }
      last_synced_at { 29.days.ago }
    end
  end

  factory :order_item do
    order
    platform { order.platform }
    sequence(:platform_item_id) { |n| "item_#{n}_#{rand(100000..999999)}" }
    title { Faker::Commerce.product_name }
    quantity { rand(1..3) }

    trait :with_kuralis_product do
      association :kuralis_product, factory: :kuralis_product
      after(:build) do |order_item|
        order_item.sku = order_item.kuralis_product&.sku
        order_item.location = order_item.kuralis_product&.location
      end
    end

    trait :ebay do
      platform { "ebay" }
      platform_item_id { rand(100000000000..999999999999).to_s }
    end

    trait :shopify do
      platform { "shopify" }
      platform_item_id { rand(10000000000000..99999999999999).to_s }
    end
  end
end
