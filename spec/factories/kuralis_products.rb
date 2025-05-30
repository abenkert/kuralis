FactoryBot.define do
  factory :kuralis_product do
    shop
    title { Faker::Commerce.product_name }
    description { Faker::Lorem.paragraph }
    base_price { Faker::Commerce.price(range: 10.0..100.0) }
    base_quantity { 10 }
    weight_oz { Faker::Number.decimal(l_digits: 2, r_digits: 2) }
    location { %w[A1 B2 C3 D4].sample }
    status { "active" }
    source_platform { "ai" }
    imported_at { 1.hour.ago }
    initial_quantity { base_quantity }

    trait :out_of_stock do
      base_quantity { 0 }
      status { "completed" }
    end

    trait :low_stock do
      base_quantity { rand(1..3) }
    end

    trait :with_shopify_product do
      source_platform { "shopify" }
      after(:create) do |product|
        create(:shopify_product, kuralis_product: product, shop: product.shop)
      end
    end

    trait :with_ebay_listing do
      source_platform { "ebay" }
      after(:create) do |product|
        account = product.shop.shopify_ebay_accounts.first || create(:shopify_ebay_account, shop: product.shop)
        create(:ebay_listing, kuralis_product: product, shopify_ebay_account: account)
      end
    end

    trait :with_both_platforms do
      with_shopify_product
      with_ebay_listing
    end

    trait :with_image do
      after(:create) do |product|
        image = fixture_file_upload(Rails.root.join('spec', 'fixtures', 'test_image.jpg'), 'image/jpeg')
        product.images.attach(image)
      end
    end

    trait :with_inventory_transactions do
      after(:create) do |product|
        # Create some sample transactions
        create(:inventory_transaction,
          kuralis_product: product,
          transaction_type: "allocation",
          quantity: -2,
          previous_quantity: product.base_quantity + 2,
          new_quantity: product.base_quantity
        )
      end
    end
  end
end
