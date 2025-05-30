FactoryBot.define do
  factory :shop do
    sequence(:shopify_domain) { |n| "test-shop-#{n}.myshopify.com" }
    shopify_token { "shpat_#{SecureRandom.hex(32)}" }
    access_scopes { "read_products,write_products,read_orders,write_orders" }
    default_location_id { "12345" }
    locations do
      {
        "12345" => {
          "name" => "Main Warehouse",
          "address1" => "123 Test St",
          "city" => "Test City",
          "province" => "CA",
          "country" => "US",
          "zip" => "12345"
        }
      }
    end

    trait :with_ebay_account do
      after(:create) do |shop|
        create(:shopify_ebay_account, shop: shop)
      end
    end

    trait :with_inventory_sync do
      after(:create) do |shop|
        create(:kuralis_shop_setting,
          shop: shop,
          category: 'inventory',
          key: 'sync_enabled',
          value: { 'enabled' => true }
        )
      end
    end
  end
end
