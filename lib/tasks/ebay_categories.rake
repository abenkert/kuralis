namespace :ebay_categories do
  desc "Generate embeddings for all eBay categories"
  task :generate_embeddings, [:limit] => :environment do |t, args|
    limit = args[:limit].to_i if args[:limit].present?
    
    puts "Starting to generate embeddings for eBay categories..."
    # Get the categories to process - filter out test categories
    categories = if limit && limit > 0
                   puts "Processing only #{limit} categories (test mode)"
                   EbayCategory.where("name NOT ILIKE '%test%'")
                              .where("name NOT ILIKE 'category %'")
                              .leaves
                              .order(id: :desc)
                              .limit(limit)
                 else
                   EbayCategory.where("name NOT ILIKE '%test%'")
                              .where("name NOT ILIKE 'category %'")
                 end
    
    total = categories.count
    puts "Found #{total} meaningful categories to process"
    
    processed = 0
    start_time = Time.now
    
    categories.each do |category|
      Ai::EbayCategoryEmbeddingService.generate_embedding_for_category(category)
      processed += 1
      
      if processed % 10 == 0 || processed == total
        elapsed = Time.now - start_time
        rate = processed / [elapsed, 0.1].max  # Avoid division by zero
        remaining = (total - processed) / [rate, 0.1].max
        puts "Processed #{processed} of #{total} categories (#{(processed.to_f / total * 100).round(2)}%). ETA: #{remaining.round(2)} seconds"
      end
    end
    
    elapsed = Time.now - start_time
    puts "Completed generating embeddings for #{processed} eBay categories in #{elapsed.round(2)} seconds"
  end
  
  desc "Update the AI product analysis service with eBay category data"
  task update_ai_context: :environment do
    puts "Updating AI context with eBay category data..."
    
    # Count how many categories have embeddings
    with_embeddings = EbayCategory.where.not(embedding_json: nil).count
    total = EbayCategory.count
    
    puts "#{with_embeddings} of #{total} categories have embeddings (#{(with_embeddings.to_f / total * 100).round(2)}%)"
    
    # Test the category search functionality
    puts "\nTesting category search..."
    
    test_queries = [
      "Superman #56 Marvel 1980",
    ]
    
    test_queries.each do |query|
      puts "\nSearch for: #{query}"
      begin
        categories = Ai::EbayCategoryService.get_categories_for_ai_context(query: query, limit: 3)
        puts "Top matches:"
        categories.each do |category|
          puts "- #{category['name']} (#{category['full_path']}) - ID: #{category['category_id']}"
        end
      rescue => e
        puts "Error: #{e.message}"
      end
    end
    
    puts "\nDone!"
  end
end 