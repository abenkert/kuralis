# Test script for Shopify rate limiting
# Run this in the Rails console with:
# load 'test_shopify_rate_limit.rb'
# Then call:
# test_shopify_rate_limit

def test_shopify_rate_limit(product_count: 25, shop_id: nil)
  # Find a valid shop if not provided
  unless shop_id
    shop = Shop.first
    unless shop
      puts "Error: No shops found in the database. Please provide a valid shop_id."
      return
    end
    shop_id = shop.id
  end

  shop = Shop.find(shop_id)
  puts "Using shop: #{ shop.shopify_domain} id: #{ shop.id}"

  # Find existing Kuralis products that aren't yet on Shopify
  unlinked_products = shop.kuralis_products.where(shopify_product_id: nil).limit(product_count)

  product_count = unlinked_products.count
  if product_count == 0
    puts "No unlinked products found. Creating test products instead."

    # Create test products if none exist
    product_count.times do |i|
      shop.kuralis_products.create!(
        title: "Test Product #{i + 1} - #{Time.current.to_i}",
        description: "This is a test product created to test rate limiting",
        base_price: rand(10.0..100.0).round(2),
        base_quantity: rand(1..10),
        weight_oz: rand(1..32),
        sku: "TEST-#{Time.current.to_i}-#{i}",
        status: "active"
      )
    end

    unlinked_products = shop.kuralis_products.where(shopify_product_id: nil).limit(product_count)
    puts "Created #{unlinked_products.count} test products."
  else
    puts "Found #{product_count} unlinked products."
  end

  product_ids = unlinked_products.pluck(:id)

  # Run in debug mode with fewer products
  puts "Starting test with #{product_ids.size} products..."

  # Queue the job
  job = Shopify::BatchCreateListingsJob.perform_later(
    shop_id: shop_id,
    product_ids: product_ids
  )

  puts "Job #{job.job_id} queued successfully!"
  puts "You can monitor this job with:"
  puts "JobRun.find_by(job_id: '#{job.job_id}')"

  # Return the job so it can be inspected
  job
end

# Alternative method: force a rate limit by running multiple jobs in parallel
def force_rate_limit_test(shop_id: nil, batch_size: 10, batch_count: 3)
  # Find a valid shop if not provided
  unless shop_id
    shop = Shop.first
    unless shop
      puts "Error: No shops found in the database. Please provide a valid shop_id."
      return
    end
    shop_id = shop.id
  end

  shop = Shop.find(shop_id)
  puts "Using shop: #{shop.name || shop.id}"

  # Find existing Kuralis products that aren't yet on Shopify
  unlinked_products = shop.kuralis_products.where(shopify_product_id: nil).limit(batch_size * batch_count)

  total_products = unlinked_products.count
  if total_products < batch_size
    puts "Not enough unlinked products found (#{total_products}). Please create more products or reduce batch_size."
    return
  end

  # Create batches
  product_batches = unlinked_products.pluck(:id).each_slice(batch_size).take(batch_count)

  puts "Starting #{batch_count} jobs with #{batch_size} products each to force rate limiting..."

  # Queue multiple jobs to intentionally hit rate limits
  jobs = []
  product_batches.each do |batch_ids|
    job = Shopify::BatchCreateListingsJob.perform_later(
      shop_id: shop_id,
      product_ids: batch_ids
    )
    jobs << job
    puts "Job #{job.job_id} queued with #{batch_ids.size} products"
  end

  puts "\nYou can monitor these jobs with:"
  jobs.each do |job|
    puts "JobRun.find_by(job_id: '#{job.job_id}')"
  end

  puts "\nOr all together with:"
  puts "JobRun.where(job_id: #{jobs.map { |j| "'#{j.job_id}'" }.join(', ')})"

  # Return the jobs so they can be inspected
  jobs
end

puts "Test methods loaded! Run one of these:"
puts "- test_shopify_rate_limit     # Basic test with default settings"
puts "- test_shopify_rate_limit(product_count: 40)  # Test with 40 products"
puts "- force_rate_limit_test       # Run multiple jobs in parallel to force rate limiting"
