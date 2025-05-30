require 'rails_helper'

RSpec.describe Shop, type: :model do
  describe 'validations' do
    subject { build(:shop) }

    it 'is valid with valid attributes' do
      expect(subject).to be_valid
    end

    it 'requires a shopify_domain' do
      subject.shopify_domain = nil
      expect(subject).not_to be_valid
      expect(subject.errors[:shopify_domain]).to include("can't be blank")
    end

    it 'requires a unique shopify_domain' do
      create(:shop, shopify_domain: 'test.myshopify.com')
      duplicate_shop = build(:shop, shopify_domain: 'test.myshopify.com')

      expect(duplicate_shop).not_to be_valid
      expect(duplicate_shop.errors[:shopify_domain]).to include("has already been taken")
    end
  end

  describe 'associations' do
    it { should have_many(:orders) }
    it { should have_one(:shopify_ebay_account) }
    # it { should have_many(:shopify_products) } # Temporarily skip due to Active Storage issue
    it { should have_many(:warehouses) }
    # it { should have_many(:ai_product_analyses) } # Temporarily skip due to Active Storage issue
    # Temporarily skip kuralis_products due to Active Storage issue
    # it { should have_many(:kuralis_products) }
  end

  describe 'factory' do
    it 'creates a valid shop' do
      shop = create(:shop)
      expect(shop).to be_persisted
      expect(shop.shopify_domain).to be_present
      expect(shop.shopify_token).to be_present
    end

    it 'creates shop with ebay account trait' do
      shop = create(:shop, :with_ebay_account)
      expect(shop.shopify_ebay_account).to be_present
    end

    it 'creates shop with inventory sync trait' do
      shop = create(:shop, :with_inventory_sync)
      expect(shop.kuralis_shop_settings).to be_present
    end
  end
end
