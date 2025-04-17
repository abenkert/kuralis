namespace :ebay_categories do
  desc "Test eBay category matching with sample product descriptions"
  task test_matching: :environment do
    require 'openai'
    require 'benchmark'
    
    # Create a reusable OpenAI client
    def openai_client
      @client ||= OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
    end
    
    # Function to get a category path from OpenAI
    def get_category_path_from_openai(product_title)
      # For testing, let's use a cache to avoid repeat API calls
      @category_cache ||= {}
      return @category_cache[product_title] if @category_cache[product_title]
      
      prompt = "You are an eBay category expert. For the following product, provide ONLY the most appropriate eBay category path with category levels separated by ' > '.\n\n" +
               "Product: #{product_title}\n\n" +
               "IMPORTANT: Respond with ONLY the EBAY category path, nothing else. Do not make up categories'"
      
      response = openai_client.chat(
        parameters: {
          model: "gpt-4o-2024-11-20",
          messages: [
            { role: "system", content: "You are an eBay category expert that provides accurate category paths." },
            { role: "user", content: prompt }
          ],
          temperature: 0.2,
          max_tokens: 100
        }
      )
      
      # Extract the response content
      path = response.dig("choices", 0, "message", "content")
      
      # Clean up the response (remove quotes, etc.)
      path = path.gsub(/["']/, '').strip if path.present?
      
      # Cache the result
      @category_cache[product_title] = path
      path
    rescue => e
      puts "Error calling OpenAI API: #{e.message}"
      "Error: #{e.message}"
    end
    
    test_cases = [
      "Superman #56 DC Comics 1980",
      "Vintage Chanel Handbag Black Leather",
      "iPhone 12 Pro Max 256GB Pacific Blue",
      "Antique Brass Compass Maritime Navigation",
      "Nike Air Jordan 1 High OG Chicago Size 10",
      "Star Wars The Mandalorian Action Figure",
      "Vitamix 5200 Blender Professional Grade",
      "The Lord of the Rings First Edition Book",
      "Microscope 40X-2000X LED Binocular Compound",
      "Vintage Rolex Submariner 1680 1970s"
    ]
    
    puts "Testing eBay category matching with sample product descriptions..."
    puts "=" * 80
    
    total_matching_time = 0
    successful_matches = 0
    
    test_cases.each do |description|
      puts "\nTesting: \"#{description}\""
      puts "-" * 50
      
      # Make a real OpenAI API call to get a category path
      print "Generating category path from OpenAI... "
      simulated_path = get_category_path_from_openai(description)
      puts "Done!"
      puts "OpenAI suggested category path: \"#{simulated_path}\""
      
      # Skip if we got an error from the API
      if simulated_path.start_with?("Error:")
        puts "Skipping category matching due to OpenAI API error."
        next
      end
      
      # Test our enhanced category matcher and benchmark it
      print "Finding matching eBay category... "
      match_time = Benchmark.measure do
        @ebay_category = Ai::EbayCategoryService.find_matching_ebay_category(simulated_path)
      end
      
      # Store the result in a variable accessible outside the benchmark block
      ebay_category = @ebay_category
      
      # Track timing
      total_matching_time += match_time.real
      
      # Output results
      if ebay_category
        successful_matches += 1
        puts "Found! (#{match_time.real.round(3)}s)"
        puts "Matched to: \"#{ebay_category.name}\" (ID: #{ebay_category.category_id})"
        if ebay_category.full_path.present?
          puts "Full path: \"#{ebay_category.full_path}\""
          
          # Show similarity between suggested and found paths
          puts "Path comparison:"
          puts "  AI suggested: #{simulated_path}"
          puts "  Found       : #{ebay_category.full_path}"
          
          # Calculate a simple similarity score
          ai_normalized = Ai::EbayCategoryService.normalize_text_for_matching(simulated_path)
          db_normalized = Ai::EbayCategoryService.normalize_text_for_matching(ebay_category.full_path)
          
          # Count common terms
          ai_terms = ai_normalized.split(/\s+/)
          db_terms = db_normalized.split(/\s+/)
          common_terms = ai_terms & db_terms
          
          similarity = common_terms.size.to_f / [ai_terms.size, db_terms.size].max
          puts "  Similarity score: #{(similarity * 100).round(1)}%"
          puts "  Match quality: #{similarity >= 0.5 ? 'GOOD' : 'QUESTIONABLE'}"
        end
      else
        puts "No match found. (#{match_time.real.round(3)}s)"
      end
    end
    
    # Print performance summary
    puts "\n#{"=" * 80}"
    puts "Performance Summary:"
    puts "Total matching time: #{total_matching_time.round(3)} seconds"
    puts "Average matching time: #{(total_matching_time / test_cases.size).round(3)} seconds per match"
    puts "Success rate: #{successful_matches}/#{test_cases.size} (#{(successful_matches.to_f / test_cases.size * 100).round(1)}%)"
    puts "#{"=" * 80}"
    puts "Testing completed!"
  end
end 