FactoryBot.define do
  factory :inventory_transaction do
    kuralis_product
    quantity { -1 }
    transaction_type { "allocation" }
    previous_quantity { kuralis_product&.base_quantity || 10 }
    new_quantity { previous_quantity + quantity }
    processed { false }

    trait :allocation do
      transaction_type { "allocation" }
      quantity { -rand(1..3) }
    end

    trait :release do
      transaction_type { "release" }
      quantity { rand(1..3) }
    end

    trait :manual_adjustment do
      transaction_type { "manual_adjustment" }
      quantity { rand(-5..5) }
      notes { "Manual adjustment for testing" }
    end

    trait :reconciliation do
      transaction_type { "reconciliation" }
      quantity { rand(-2..2) }
      notes { "Reconciliation adjustment" }
    end

    trait :allocation_failed do
      transaction_type { "allocation_failed" }
      quantity { -rand(1..5) }
      notes { "Insufficient inventory" }
    end

    trait :processed do
      processed { true }
    end

    trait :with_order do
      association :order
      association :order_item
      after(:build) do |transaction|
        transaction.order_item.order = transaction.order
        transaction.order_item.kuralis_product = transaction.kuralis_product
      end
    end

    trait :recent do
      created_at { 1.hour.ago }
    end

    trait :old do
      created_at { 30.days.ago }
    end
  end
end
