FactoryBot.define do
  factory :shopify_ebay_account do
    shop
    access_token { "v^1.1#i^1#r^0#p^3#I^3#f^0#t^H4sI..." }
    refresh_token { "v^1.1#i^1#r^1#p^3#I^3#f^0#t^H4sI..." }
    access_token_expires_at { 2.hours.from_now }
    refresh_token_expires_at { 18.months.from_now }
    last_listing_import_at { 1.hour.ago }

    store_categories do
      [
        { "categoryId" => "123", "categoryName" => "Electronics" },
        { "categoryId" => "456", "categoryName" => "Books" }
      ]
    end

    shipping_profiles do
      [
        {
          "profileId" => "PROF123",
          "profileName" => "Standard Shipping",
          "localShipping" => {
            "shippingService" => "USPSGround"
          }
        }
      ]
    end

    payment_profiles do
      [
        {
          "profileId" => "PAY123",
          "profileName" => "Standard Payments"
        }
      ]
    end

    return_profiles do
      [
        {
          "profileId" => "RET123",
          "profileName" => "30 Day Returns"
        }
      ]
    end
  end

  factory :shopify_product do
    shop
    sequence(:shopify_product_id) { |n| "#{rand(1000000000000..9999999999999)}" }
    sequence(:shopify_variant_id) { |n| "#{rand(10000000000000..99999999999999)}" }
    title { Faker::Commerce.product_name }
    description { Faker::Lorem.paragraph }
    price { Faker::Commerce.price(range: 10.0..100.0) }
    quantity { 10 }
    status { "active" }
    published { true }
    handle { title.parameterize }
    product_type { "Physical" }
    vendor { Faker::Company.name }
    tags { [ "tag1", "tag2" ] }
    last_synced_at { 1.hour.ago }

    trait :with_kuralis_product do
      after(:create) do |shopify_product|
        create(:kuralis_product,
          shopify_product: shopify_product,
          shop: shopify_product.shop,
          source_platform: "shopify"
        )
      end
    end

    trait :out_of_stock do
      quantity { 0 }
      status { "inactive" }
    end
  end

  factory :ebay_listing do
    shopify_ebay_account
    sequence(:ebay_item_id) { |n| "#{rand(100000000000..999999999999)}" }
    title { Faker::Commerce.product_name }
    description { Faker::Lorem.paragraph }
    sale_price { Faker::Commerce.price(range: 10.0..100.0) }
    original_price { sale_price }
    quantity { 10 }
    total_quantity { quantity }
    quantity_sold { 0 }
    location { "A1B-2" }
    listing_format { "FixedPriceItem" }
    condition_id { "1000" }
    condition_description { "New" }
    category_id { "177" }
    listing_duration { "GTC" }
    best_offer_enabled { true }
    ebay_status { "Active" }
    last_sync_at { 1.hour.ago }

    image_urls do
      [
        "https://i.ebayimg.com/00/s/MTIwMFgxNjAw/z/test/$_57.JPG?set_id=880000500F"
      ]
    end

    item_specifics do
      {
        "Brand" => "Test Brand",
        "Type" => "Test Type"
      }
    end

    trait :with_kuralis_product do
      after(:create) do |ebay_listing|
        create(:kuralis_product,
          ebay_listing: ebay_listing,
          shop: ebay_listing.shopify_ebay_account.shop,
          source_platform: "ebay"
        )
      end
    end

    trait :completed do
      ebay_status { "Completed" }
      quantity { 0 }
      quantity_sold { total_quantity }
    end

    trait :ended do
      ebay_status { "Ended" }
    end
  end

  factory :kuralis_shop_setting do
    shop
    category { "inventory" }
    key { "sync_enabled" }
    value { { "enabled" => true } }
    metadata { {} }
  end
end
