# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2025_03_21_004039) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ai_product_analyses", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "image", null: false
    t.string "status", default: "pending", null: false
    t.jsonb "results", default: {}
    t.boolean "processed", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["processed"], name: "index_ai_product_analyses_on_processed"
    t.index ["shop_id"], name: "index_ai_product_analyses_on_shop_id"
    t.index ["status"], name: "index_ai_product_analyses_on_status"
  end

  create_table "ebay_categories", force: :cascade do |t|
    t.string "category_id", null: false
    t.string "name", null: false
    t.string "parent_id"
    t.integer "level", default: 1, null: false
    t.boolean "leaf", default: false, null: false
    t.string "marketplace_id", default: "EBAY_US", null: false
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "embedding_json"
    t.index ["category_id"], name: "index_ebay_categories_on_category_id"
    t.index ["marketplace_id", "category_id"], name: "index_ebay_categories_on_marketplace_id_and_category_id", unique: true
    t.index ["marketplace_id", "parent_id"], name: "index_ebay_categories_on_marketplace_id_and_parent_id"
    t.index ["name"], name: "index_ebay_categories_on_name"
    t.index ["parent_id"], name: "index_ebay_categories_on_parent_id"
  end

  create_table "ebay_listings", force: :cascade do |t|
    t.string "ebay_item_id", null: false
    t.string "title"
    t.text "description"
    t.decimal "sale_price", precision: 10, scale: 2
    t.integer "quantity"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "shopify_ebay_account_id", null: false
    t.decimal "original_price", precision: 10, scale: 2
    t.string "shipping_profile_id"
    t.string "location"
    t.jsonb "image_urls", default: []
    t.string "listing_format"
    t.string "condition_id"
    t.string "condition_description"
    t.string "category_id"
    t.jsonb "item_specifics", default: {}
    t.string "listing_duration"
    t.datetime "end_time"
    t.boolean "best_offer_enabled", default: false
    t.string "ebay_status"
    t.datetime "last_sync_at"
    t.string "store_category_id"
    t.index ["shopify_ebay_account_id"], name: "index_ebay_listings_on_shopify_ebay_account_id"
    t.index ["store_category_id"], name: "index_ebay_listings_on_store_category_id"
  end

  create_table "ebay_product_attributes", force: :cascade do |t|
    t.bigint "kuralis_product_id", null: false
    t.string "condition_id"
    t.string "condition_description"
    t.string "category_id"
    t.jsonb "item_specifics", default: {}
    t.string "listing_duration"
    t.boolean "best_offer_enabled", default: true
    t.string "shipping_profile_id"
    t.string "store_category_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "payment_profile_id"
    t.string "return_profile_id"
    t.index ["kuralis_product_id"], name: "index_ebay_product_attributes_on_kuralis_product_id", unique: true
    t.index ["payment_profile_id"], name: "index_ebay_product_attributes_on_payment_profile_id"
    t.index ["return_profile_id"], name: "index_ebay_product_attributes_on_return_profile_id"
  end

  create_table "inventory_transactions", force: :cascade do |t|
    t.bigint "kuralis_product_id", null: false
    t.bigint "order_item_id"
    t.integer "quantity", null: false
    t.string "transaction_type", null: false
    t.integer "previous_quantity", null: false
    t.integer "new_quantity", null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "order_id"
    t.index ["created_at"], name: "index_inventory_transactions_on_created_at"
    t.index ["kuralis_product_id"], name: "index_inventory_transactions_on_kuralis_product_id"
    t.index ["order_id"], name: "index_inventory_transactions_on_order_id"
    t.index ["order_item_id"], name: "index_inventory_transactions_on_order_item_id"
    t.index ["transaction_type"], name: "index_inventory_transactions_on_transaction_type"
  end

  create_table "job_runs", force: :cascade do |t|
    t.string "job_class"
    t.string "job_id"
    t.string "status"
    t.text "arguments"
    t.text "error_message"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.bigint "shop_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["job_class"], name: "index_job_runs_on_job_class"
    t.index ["job_id"], name: "index_job_runs_on_job_id"
    t.index ["shop_id"], name: "index_job_runs_on_shop_id"
    t.index ["status"], name: "index_job_runs_on_status"
  end

  create_table "kuralis_products", force: :cascade do |t|
    t.string "title", null: false
    t.text "description"
    t.text "description_html"
    t.decimal "base_price", precision: 10, scale: 2
    t.integer "base_quantity", default: 0
    t.string "sku"
    t.string "brand"
    t.string "condition"
    t.string "location"
    t.jsonb "image_urls", default: []
    t.jsonb "product_attributes", default: {}
    t.bigint "shop_id", null: false
    t.bigint "shopify_product_id"
    t.bigint "ebay_listing_id"
    t.string "source_platform"
    t.datetime "last_synced_at"
    t.string "status", default: "active"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "images_last_synced_at"
    t.decimal "weight_oz", precision: 8, scale: 2
    t.jsonb "tags", default: [], null: false
    t.bigint "ai_product_analysis_id"
    t.boolean "is_draft", default: false
    t.index ["ai_product_analysis_id"], name: "index_kuralis_products_on_ai_product_analysis_id"
    t.index ["ebay_listing_id"], name: "index_kuralis_products_on_ebay_listing_id"
    t.index ["is_draft"], name: "index_kuralis_products_on_is_draft"
    t.index ["shop_id"], name: "index_kuralis_products_on_shop_id"
    t.index ["shopify_product_id"], name: "index_kuralis_products_on_shopify_product_id"
    t.index ["sku"], name: "index_kuralis_products_on_sku"
    t.index ["source_platform"], name: "index_kuralis_products_on_source_platform"
    t.index ["status"], name: "index_kuralis_products_on_status"
    t.index ["tags"], name: "index_kuralis_products_on_tags", using: :gin
  end

  create_table "notifications", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "title", null: false
    t.text "message", null: false
    t.string "category", null: false
    t.boolean "read", default: false
    t.jsonb "metadata", default: {}
    t.integer "failed_product_ids", default: [], array: true
    t.integer "successful_product_ids", default: [], array: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "status", default: "info", null: false
    t.index ["failed_product_ids"], name: "index_notifications_on_failed_product_ids", using: :gin
    t.index ["shop_id", "category"], name: "index_notifications_on_shop_id_and_category"
    t.index ["shop_id", "read"], name: "index_notifications_on_shop_id_and_read"
    t.index ["shop_id"], name: "index_notifications_on_shop_id"
    t.index ["status"], name: "index_notifications_on_status"
    t.index ["successful_product_ids"], name: "index_notifications_on_successful_product_ids", using: :gin
  end

  create_table "order_items", force: :cascade do |t|
    t.bigint "order_id", null: false
    t.bigint "kuralis_product_id"
    t.string "title"
    t.string "sku"
    t.string "location"
    t.integer "quantity"
    t.jsonb "platform_data", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "platform", null: false
    t.string "platform_item_id"
    t.index ["kuralis_product_id"], name: "index_order_items_on_kuralis_product_id"
    t.index ["order_id"], name: "index_order_items_on_order_id"
    t.index ["platform_item_id"], name: "index_order_items_on_platform_item_id"
    t.index ["sku"], name: "index_order_items_on_sku"
  end

  create_table "orders", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "platform", null: false
    t.string "platform_order_id", null: false
    t.string "platform_order_number"
    t.string "customer_name"
    t.jsonb "shipping_address"
    t.string "status"
    t.decimal "subtotal", precision: 10, scale: 2
    t.decimal "shipping_cost", precision: 10, scale: 2
    t.decimal "total_price", precision: 10, scale: 2
    t.string "payment_status"
    t.datetime "paid_at"
    t.string "fulfillment_status"
    t.string "tracking_number"
    t.string "tracking_company"
    t.datetime "shipped_at"
    t.jsonb "platform_data", default: {}
    t.datetime "order_placed_at"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["fulfillment_status"], name: "index_orders_on_fulfillment_status"
    t.index ["order_placed_at"], name: "index_orders_on_order_placed_at"
    t.index ["payment_status"], name: "index_orders_on_payment_status"
    t.index ["platform", "platform_order_id"], name: "index_orders_on_platform_and_platform_order_id", unique: true
    t.index ["platform_order_number"], name: "index_orders_on_platform_order_number"
    t.index ["shop_id"], name: "index_orders_on_shop_id"
    t.index ["status"], name: "index_orders_on_status"
  end

  create_table "shopify_ebay_accounts", force: :cascade do |t|
    t.bigint "shop_id", null: false
    t.string "access_token"
    t.string "refresh_token"
    t.datetime "access_token_expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "refresh_token_expires_at"
    t.datetime "last_listing_import_at"
    t.jsonb "store_categories", default: [], null: false
    t.jsonb "shipping_profiles", default: [], null: false
    t.jsonb "shipping_profile_weights", default: {}, null: false
    t.jsonb "category_tag_mappings", default: {}, null: false
    t.jsonb "payment_profiles", default: []
    t.jsonb "return_profiles", default: []
    t.index ["payment_profiles"], name: "index_shopify_ebay_accounts_on_payment_profiles", using: :gin
    t.index ["return_profiles"], name: "index_shopify_ebay_accounts_on_return_profiles", using: :gin
    t.index ["shop_id"], name: "index_shopify_ebay_accounts_on_shop_id"
  end

  create_table "shopify_products", force: :cascade do |t|
    t.string "shopify_product_id", null: false
    t.string "shopify_variant_id", null: false
    t.decimal "price", precision: 10, scale: 2
    t.integer "quantity"
    t.string "sku"
    t.string "inventory_location"
    t.string "status", default: "active"
    t.boolean "published", default: true
    t.string "title"
    t.string "description"
    t.string "handle"
    t.string "product_type"
    t.string "vendor"
    t.jsonb "tags"
    t.jsonb "options"
    t.datetime "last_synced_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "shop_id", null: false
    t.string "image_urls", default: [], array: true
    t.datetime "images_last_synced_at"
    t.index ["shop_id"], name: "index_shopify_products_on_shop_id"
    t.index ["shopify_product_id"], name: "index_shopify_products_on_shopify_product_id", unique: true
    t.index ["shopify_variant_id"], name: "index_shopify_products_on_shopify_variant_id"
    t.index ["status"], name: "index_shopify_products_on_status"
  end

  create_table "shops", force: :cascade do |t|
    t.string "shopify_domain", null: false
    t.string "shopify_token", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "access_scopes", default: "", null: false
    t.string "default_location_id"
    t.jsonb "locations", default: {}
    t.index ["shopify_domain"], name: "index_shops_on_shopify_domain", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "encrypted_password", null: false
    t.string "first_name"
    t.string "last_name"
    t.bigint "shop_id"
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["shop_id"], name: "index_users_on_shop_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ai_product_analyses", "shops"
  add_foreign_key "ebay_listings", "shopify_ebay_accounts"
  add_foreign_key "ebay_product_attributes", "kuralis_products"
  add_foreign_key "inventory_transactions", "kuralis_products"
  add_foreign_key "inventory_transactions", "order_items"
  add_foreign_key "inventory_transactions", "orders"
  add_foreign_key "job_runs", "shops"
  add_foreign_key "kuralis_products", "ai_product_analyses"
  add_foreign_key "kuralis_products", "ebay_listings", on_delete: :nullify
  add_foreign_key "kuralis_products", "shopify_products", on_delete: :nullify
  add_foreign_key "kuralis_products", "shops"
  add_foreign_key "notifications", "shops"
  add_foreign_key "order_items", "kuralis_products"
  add_foreign_key "order_items", "orders"
  add_foreign_key "orders", "shops"
  add_foreign_key "shopify_ebay_accounts", "shops"
  add_foreign_key "shopify_products", "shops"
  add_foreign_key "users", "shops"
end
