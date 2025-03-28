require "sidekiq/web"

Rails.application.routes.draw do
  # Commenting out devise routes for now
  # devise_for :users

  # Protect Sidekiq web UI with basic auth
  if Rails.env.production?
    Sidekiq::Web.use Rack::Auth::Basic do |username, password|
      ActiveSupport::SecurityUtils.secure_compare(
        ::Digest::SHA256.hexdigest(username),
        ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_USERNAME"])
      ) &
      ActiveSupport::SecurityUtils.secure_compare(
        ::Digest::SHA256.hexdigest(password),
        ::Digest::SHA256.hexdigest(ENV["SIDEKIQ_PASSWORD"])
      )
    end
  end

  mount Sidekiq::Web => "/sidekiq"

  get "shopify_products/index"
  get "dashboard/index"
  root to: "home#index"


  mount ShopifyApp::Engine, at: "/"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  get "dashboard", to: "dashboard#index", as: :dashboard
  get "settings", to: "settings#index", as: :settings

  namespace :kuralis do
    get "ebay_categories/search"
    post "ebay_categories/import"
    get "ebay_categories/:id", to: "ebay_categories#show", as: :ebay_category
    resources :ebay_categories, only: [ :index ] do
      member do
        get :item_specifics
      end
    end

    resources :bulk_listings, only: [ :index, :create ]
    resources :listings, only: [ :create ]

    resources :products, only: [ :index, :new, :create, :edit, :update, :destroy ] do
      collection do
        # post :bulk_action
        # get :bulk_ai_creation
        # post :upload_images
        # delete :remove_image
        # get :ai_analysis_status
        # get :create_product_from_ai
      end
    end
    resources :ai_product_analyses, only: [ :index, :show, :create, :destroy ]
    resources :draft_products, only: [ :create ]

    patch "settings", to: "settings#update"
  end

  namespace :ebay do
    get "auth", to: "auth#auth"
    get "callback", to: "auth#callback"
    delete "auth", to: "auth#destroy", as: :unlink
    post "notifications", to: "notifications#create"
    resources :listings, only: [ :index ] do
      collection do
        resources :quick_sync, only: [ :create ]
        resources :synchronizations, only: [ :create ]
        resources :migrations, only: [ :create ] do
          get :unmigrated_count, on: :collection
        end
      end
    end
    post "shipping_policies", to: "shipping_policies#create"
    patch "shipping_weights", to: "shipping_weights#update"
    post "store_categories", to: "store_categories#create"
    patch "category_tags", to: "category_tags#update"
  end

  namespace :admin do
    resources :jobs, only: [ :index ]
  end

  namespace :shopify do
    resources :products, only: [ :index ]
    resources :synchronizations, only: [ :create ]
  end

  resources :settings, only: [ :index ] do
    collection do
      post :sync_locations
      patch :update_default_location
    end
  end

  resources :orders, only: [ :index ] do
    post :trigger_sync_orders, on: :collection
  end

  resources :warehouses, except: [ :show ]
end
