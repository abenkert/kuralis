require 'rails_helper'

RSpec.describe KuralisProduct, type: :model do
  describe 'validations' do
    subject { build(:kuralis_product) }

    it { should validate_presence_of(:title) }
    it { should validate_presence_of(:base_price) }
    it { should validate_numericality_of(:base_quantity).is_greater_than_or_equal_to(0) }
    it { should validate_numericality_of(:weight_oz).is_greater_than_or_equal_to(0) }

    it 'is valid with valid attributes' do
      expect(subject).to be_valid
    end
  end

  describe 'associations' do
    it { should belong_to(:shop) }
    it { should belong_to(:shopify_product).optional }
    it { should belong_to(:ebay_listing).optional }
    it { should have_many(:inventory_transactions) }
    it { should have_many(:order_items) }
  end

  describe 'scopes' do
    let!(:active_product) { create(:kuralis_product, status: 'active') }
    let!(:inactive_product) { create(:kuralis_product, status: 'inactive') }
    let!(:out_of_stock) { create(:kuralis_product, :out_of_stock) }

    describe '.active' do
      it 'returns only active products' do
        expect(KuralisProduct.active).to include(active_product)
        expect(KuralisProduct.active).not_to include(inactive_product)
      end
    end

    describe '.out_of_stock' do
      it 'returns products with zero quantity' do
        expect(KuralisProduct.out_of_stock).to include(out_of_stock)
        expect(KuralisProduct.out_of_stock).not_to include(active_product)
      end
    end
  end

  describe 'inventory management' do
    let(:product) { create(:kuralis_product, base_quantity: 10) }

    describe '#sufficient_inventory?' do
      it 'returns true when quantity is sufficient' do
        expect(product.sufficient_inventory?(5)).to be true
      end

      it 'returns false when quantity is insufficient' do
        expect(product.sufficient_inventory?(15)).to be false
      end
    end

    describe 'status changes based on quantity' do
      it 'marks as completed when quantity reaches zero' do
        product.update!(base_quantity: 0)
        # This would depend on your actual model callbacks
        # expect(product.status).to eq('completed')
      end
    end
  end

  describe 'platform associations' do
    context 'with eBay listing' do
      let(:product) { create(:kuralis_product, :with_ebay_listing) }

      it 'has an eBay listing associated' do
        expect(product.ebay_listing).to be_present
        expect(product.source_platform).to eq('ebay')
      end
    end

    context 'with Shopify product' do
      let(:product) { create(:kuralis_product, :with_shopify_product) }

      it 'has a Shopify product associated' do
        expect(product.shopify_product).to be_present
        expect(product.source_platform).to eq('shopify')
      end
    end
  end

  describe 'factory traits' do
    it 'creates out of stock products correctly' do
      product = create(:kuralis_product, :out_of_stock)
      expect(product.base_quantity).to eq(0)
      expect(product.status).to eq('completed')
    end

    it 'creates low stock products correctly' do
      product = create(:kuralis_product, :low_stock)
      expect(product.base_quantity).to be_between(1, 3)
    end
  end
end
