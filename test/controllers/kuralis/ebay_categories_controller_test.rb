require "test_helper"

class Kuralis::EbayCategoriesControllerTest < ActionDispatch::IntegrationTest
  test "should get search" do
    get kuralis_ebay_categories_search_url
    assert_response :success
  end
end
