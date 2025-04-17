require "test_helper"

class ShopifyProductsControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get shopify_products_index_url
    assert_response :success
  end
end
