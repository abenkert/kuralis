namespace :ebay_categories do
  desc "Test eBay category matching with sample product descriptions"
  task test_matching: :environment do
    require "openai"
    require "benchmark"

    # Create a reusable OpenAI client
    def openai_client
      @client ||= OpenAI::Client.new(access_token: ENV["OPENAI_API_KEY"])
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
      path = path.gsub(/["']/, "").strip if path.present?

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
      "Vintage Rolex Submariner 1680 1970s",
      "Batman Comic Book Modern Age",
      "Marvel Spider-Man Action Figure",
      "Pokemon Trading Cards Booster Pack",
      "Vintage Baseball Card 1952 Topps",
      "Women's Designer Dress Size Medium",
      "Men's Nike Running Shoes Size 10",
      "Kitchen Stand Mixer Professional",
      "Antique Victorian Jewelry Ring",
      "Electric Guitar Fender Stratocaster",
      "Digital Camera Canon DSLR"
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

          # Calculate confidence using the new system
          confidence = calculate_test_confidence(simulated_path, ebay_category)
          puts "  Confidence score: #{(confidence * 100).round(1)}%"
          puts "  Match quality: #{confidence >= 0.8 ? 'EXCELLENT' : confidence >= 0.5 ? 'GOOD' : 'QUESTIONABLE'}"

          # Test item specifics if available
          test_item_specifics(ebay_category, description)
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

  # Calculate confidence score for testing
  def calculate_test_confidence(ai_path, matched_category)
    return 0.0 unless ai_path.present? && matched_category&.full_path.present?

    ai_segments = ai_path.split(/\s*>\s*/).map(&:strip).map(&:downcase)
    category_segments = matched_category.full_path.split(/\s*>\s*/).map(&:strip).map(&:downcase)

    matching_segments = 0
    ai_segments.each do |ai_segment|
      if category_segments.any? { |cat_segment|
           cat_segment.include?(ai_segment) ||
           ai_segment.include?(cat_segment) ||
           calculate_string_similarity(ai_segment, cat_segment) > 0.8
         }
        matching_segments += 1
      end
    end

    segment_confidence = matching_segments.to_f / [ ai_segments.size, category_segments.size ].max

    ai_leaf = ai_segments.last
    category_leaf = category_segments.last
    leaf_similarity = calculate_string_similarity(ai_leaf, category_leaf)

    final_confidence = (segment_confidence * 0.6) + (leaf_similarity * 0.4)
    [ final_confidence, 1.0 ].min
  end

  # Test item specifics for a category
  def test_item_specifics(category, product_description)
    puts "  Testing item specifics..."

    # Try to get cached item specifics
    cached_specifics = category.metadata&.dig("item_specifics")

    if cached_specifics.present?
      required_count = cached_specifics.count { |aspect| aspect["required"] == true }
      total_count = cached_specifics.size

      puts "    Available aspects: #{total_count} (#{required_count} required)"

      if required_count > 0
        puts "    Required aspects:"
        cached_specifics.select { |a| a["required"] }.first(3).each do |aspect|
          puts "      - #{aspect['name']}"
        end
      end
    else
      puts "    No cached item specifics available"
    end
  end

  # Simple string similarity calculation
  def calculate_string_similarity(str1, str2)
    return 1.0 if str1 == str2
    return 0.0 if str1.blank? || str2.blank?

    chars1 = str1.chars.to_set
    chars2 = str2.chars.to_set

    intersection = chars1 & chars2
    union = chars1 | chars2

    intersection.size.to_f / union.size
  end
end
