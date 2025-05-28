class AiProductAnalysisJob < ApplicationJob
  require "base64"

  queue_as :default

  retry_on StandardError, attempts: 3, wait: 5.seconds

  def perform(shop_id, analysis_id)
    analysis = AiProductAnalysis.find_by(id: analysis_id)

    # Exit early if analysis record not found
    unless analysis
      Rails.logger.error "Analysis record not found (ID: #{analysis_id})"
      return
    end

    # Update status to processing
    analysis.mark_as_processing!

    # Broadcast status update
    broadcast_update(analysis)

    begin
      # Get the attached image
      if analysis.image_attachment.attached?
        # Download the image data
        image_data = analysis.image_attachment.download

        # Get the filename
        filename = analysis.image_attachment.filename.to_s

        # Analyze the image
        results = analyze_image(image_data, filename, shop_id)

        # Mark as completed with results and automatically create draft product
        if results.key?(:error)
          analysis.mark_as_failed!(results[:error])
        else
          analysis.mark_as_completed!(results)

          # Automatically create draft product after successful analysis
          create_draft_product_from_analysis(analysis)
        end
      else
        # No image attached, mark as failed
        analysis.mark_as_failed!("No image attached to analysis")
      end

      # Broadcast the update
      broadcast_update(analysis)
    rescue => e
      Rails.logger.error "Error in AI analysis job: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")

      # Mark as failed with error message
      analysis.update(
        status: "failed",
        error_message: "Error analyzing image: #{e.message}"
      )

      # Broadcast the error status
      broadcast_update(analysis)
    end
  end

  def analyze_image(image_data, filename, shop_id)
    # Call OpenAI API to analyze the image using the OpenAI Vision API
    begin
      # Encode image for API request
      base64_image = Base64.strict_encode64(image_data)

      # Call OpenAI Vision API
      response = call_openai_api(base64_image, shop_id)

      # Process OpenAI response
      process_openai_response(response, filename, shop_id)
    rescue => e
      Rails.logger.error "Error calling OpenAI API: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      { error: "Failed to analyze image: #{e.message}" }
    end
  end

  def call_openai_api(base64_image, shop_id)
    # Get the OpenAI service from your existing implementation
    openai_service = Ai::OpenaiService.new(
      model: "gpt-4o-2024-11-20",
      temperature: 0.2,
      max_tokens: 10000
    )

    # First, do a quick analysis to determine product type
    product_type = determine_product_type(base64_image, openai_service)

    # Get relevant category examples based on product type
    category_examples = get_relevant_category_examples(product_type)

    # Get the eBay category prompt
    category_prompt = Ai::EbayCategoryService.generate_ebay_category_prompt

    # Enhanced prompt with relevant eBay category examples
    prompt = <<~PROMPT
      Analyze this product image and provide detailed information. Return a JSON object with the following fields:

      - title: Product title (be specific and descriptive)
      - description: Detailed product description
      - brand: Brand name if identifiable
      - ebay_category_path: The EXACT eBay category path from the examples below
      - item_specifics: Key-value pairs of product attributes relevant to the category
      - tags: Array of relevant search tags

      IMPORTANT EBAY CATEGORY GUIDELINES:
      1. ONLY use category paths from the examples below - do NOT create new paths
      2. Choose the MOST SPECIFIC category that fits the product
      3. If unsure, choose a broader category rather than making up subcategories
      4. For comics: Use "Collectibles > Comic Books & Memorabilia > Comics > Comics & Graphic Novels"
      5. For collectibles: Start with "Collectibles > [appropriate subcategory]"

      RELEVANT EBAY CATEGORY EXAMPLES FOR THIS PRODUCT TYPE:
      #{category_examples}

      For item_specifics, provide attributes that are commonly required for the chosen category.
      Do NOT suggest prices - pricing will be handled separately.

      If you cannot determine some fields, use null values.
    PROMPT

    # Since the OpenAI service doesn't have a specific vision method,
    # we'll use chat_with_history and construct the messages with the image
    messages = [
      {
        role: "system",
        content: category_prompt
      },
      {
        role: "user",
        content: [
          { type: "text", text: prompt },
          {
            type: "image_url",
            image_url: {
              url: "data:image/jpeg;base64,#{base64_image}",
              detail: "high"
            }
          }
        ]
      }
    ]

    # Make a direct API call since our service wrapper doesn't support images yet
    client = openai_service.client

    response = client.chat(
      parameters: {
        model: "gpt-4o-2024-11-20",
        messages: messages,
        max_tokens: 10000,
        temperature: 0.2
      }
    )

    # Check for errors
    if response["error"]
      Rails.logger.error "OpenAI API error: #{response["error"]["message"]}"
      raise "OpenAI API returned error: #{response["error"]["message"]}"
    end

    response
  end

  # Quick analysis to determine product type for better category suggestions
  def determine_product_type(base64_image, openai_service)
    quick_prompt = "Look at this image and identify the product type in 1-3 words. Examples: 'comic book', 'clothing', 'electronics', 'jewelry', 'toy', 'book', 'collectible', 'antique', 'art', 'musical instrument', 'automotive', 'home decor', 'sports equipment'. Respond with ONLY the product type."

    messages = [
      {
        role: "user",
        content: [
          { type: "text", text: quick_prompt },
          {
            type: "image_url",
            image_url: {
              url: "data:image/jpeg;base64,#{base64_image}",
              detail: "low"  # Use low detail for speed
            }
          }
        ]
      }
    ]

    client = openai_service.client
    response = client.chat(
      parameters: {
        model: "gpt-4o-2024-11-20",
        messages: messages,
        max_tokens: 50,
        temperature: 0.1
      }
    )

    product_type = response.dig("choices", 0, "message", "content")&.strip&.downcase || "general"
    Rails.logger.info "Determined product type: #{product_type}"
    product_type
  rescue => e
    Rails.logger.warn "Failed to determine product type: #{e.message}"
    "general"
  end

  # Get relevant category examples based on product type
  def get_relevant_category_examples(product_type)
    case product_type
    when /comic|book|magazine/
      get_books_comics_categories
    when /clothing|apparel|fashion|dress|shirt|pants|shoes/
      get_clothing_categories
    when /electronic|phone|computer|camera|gadget/
      get_electronics_categories
    when /toy|action figure|doll|game/
      get_toys_categories
    when /jewelry|watch|ring|necklace/
      get_jewelry_categories
    when /collectible|vintage|antique/
      get_collectibles_categories
    when /art|painting|print|sculpture/
      get_art_categories
    when /music|instrument|guitar|piano/
      get_musical_categories
    when /automotive|car|truck|motorcycle/
      get_automotive_categories
    when /home|kitchen|furniture|decor/
      get_home_garden_categories
    when /sport|fitness|outdoor/
      get_sports_categories
    else
      get_general_category_examples
    end
  end

  # Category examples for different product types
  def get_books_comics_categories
    [
      "Collectibles > Comic Books & Memorabilia > Comics > Comics & Graphic Novels",
      "Collectibles > Comic Books & Memorabilia > Comics > Comic Strips",
      "Books > Fiction & Literature",
      "Books > Textbooks, Education & Reference",
      "Books > Children & Young Adults",
      "Books > Antiquarian & Collectible",
      "Collectibles > Comic Books & Memorabilia > Manga & Asian Comics"
    ].join("\n")
  end

  def get_clothing_categories
    [
      "Clothing, Shoes & Accessories > Women's Clothing > Dresses",
      "Clothing, Shoes & Accessories > Women's Clothing > Tops & Blouses",
      "Clothing, Shoes & Accessories > Men's Clothing > Casual Shirts",
      "Clothing, Shoes & Accessories > Men's Clothing > T-Shirts",
      "Clothing, Shoes & Accessories > Women's Shoes",
      "Clothing, Shoes & Accessories > Men's Shoes",
      "Clothing, Shoes & Accessories > Women's Accessories > Handbags & Purses",
      "Clothing, Shoes & Accessories > Unisex Clothing, Shoes & Accs"
    ].join("\n")
  end

  def get_electronics_categories
    [
      "Electronics > Cell Phones & Smartphones",
      "Electronics > Computers/Tablets & Networking > Laptops & Netbooks",
      "Electronics > Computers/Tablets & Networking > Tablets & eBook Readers",
      "Electronics > Cameras & Photo > Digital Cameras",
      "Electronics > Video Games & Consoles > Video Games",
      "Electronics > TV, Video & Home Audio > Home Audio > Home Audio Components",
      "Electronics > Portable Audio & Headphones"
    ].join("\n")
  end

  def get_toys_categories
    [
      "Toys & Hobbies > Action Figures & Accessories > Action Figures",
      "Toys & Hobbies > Building Toys > LEGO Building Toys",
      "Toys & Hobbies > Dolls & Bears > Dolls",
      "Toys & Hobbies > Games > Board & Traditional Games",
      "Toys & Hobbies > Diecast & Toy Vehicles",
      "Toys & Hobbies > Electronic, Battery & Wind-Up > Electronic Toys"
    ].join("\n")
  end

  def get_jewelry_categories
    [
      "Jewelry & Watches > Fine Jewelry > Necklaces & Pendants",
      "Jewelry & Watches > Fine Jewelry > Rings",
      "Jewelry & Watches > Fine Jewelry > Earrings",
      "Jewelry & Watches > Watches, Parts & Accessories > Watches",
      "Jewelry & Watches > Fashion Jewelry > Necklaces & Pendants",
      "Jewelry & Watches > Fashion Jewelry > Bracelets"
    ].join("\n")
  end

  def get_collectibles_categories
    [
      "Collectibles > Trading Cards > Sports Trading Cards > Baseball Cards",
      "Collectibles > Coins & Paper Money > Coins: US > Commemorative",
      "Collectibles > Advertising > Soda > Coca-Cola",
      "Collectibles > Decorative Collectibles > Figurines",
      "Collectibles > Postcards & Supplies > Postcards",
      "Collectibles > Militaria > Original Period Items"
    ].join("\n")
  end

  def get_art_categories
    [
      "Art > Paintings",
      "Art > Prints",
      "Art > Drawings",
      "Art > Photography",
      "Art > Sculpture",
      "Art > Mixed Media Art & Collage"
    ].join("\n")
  end

  def get_musical_categories
    [
      "Musical Instruments & Gear > Guitars & Basses > Electric Guitars",
      "Musical Instruments & Gear > Guitars & Basses > Acoustic Guitars",
      "Musical Instruments & Gear > Keyboards & Pianos > Digital Pianos",
      "Musical Instruments & Gear > Pro Audio Equipment",
      "Musical Instruments & Gear > Wind & Woodwind > Saxophones"
    ].join("\n")
  end

  def get_automotive_categories
    [
      "Automotive > Parts & Accessories > Car & Truck Parts & Accessories",
      "Automotive > Motorcycle Parts",
      "Automotive > Tools & Supplies > Automotive Tools",
      "Automotive > GPS & Security Devices"
    ].join("\n")
  end

  def get_home_garden_categories
    [
      "Home & Garden > Kitchen, Dining & Bar > Small Kitchen Appliances",
      "Home & Garden > Home Décor > Candles & Home Fragrance",
      "Home & Garden > Furniture > Living Room Furniture",
      "Home & Garden > Tools & Workshop Equipment > Hand Tools",
      "Home & Garden > Yard, Garden & Outdoor Living > Garden Tools"
    ].join("\n")
  end

  def get_sports_categories
    [
      "Sports Mem, Cards & Fan Shop > Sports Trading Cards > Baseball Cards",
      "Sporting Goods > Fitness, Running & Yoga > Cardio Training",
      "Sporting Goods > Team Sports > Baseball & Softball",
      "Sporting Goods > Outdoor Sports > Cycling"
    ].join("\n")
  end

  def get_general_category_examples
    [
      "Collectibles > Comic Books & Memorabilia > Comics > Comics & Graphic Novels",
      "Clothing, Shoes & Accessories > Women's Clothing > Dresses",
      "Electronics > Cell Phones & Smartphones",
      "Toys & Hobbies > Action Figures & Accessories > Action Figures",
      "Jewelry & Watches > Watches, Parts & Accessories > Watches",
      "Books > Fiction & Literature",
      "Art > Paintings",
      "Musical Instruments & Gear > Guitars & Basses > Electric Guitars",
      "Home & Garden > Kitchen, Dining & Bar > Small Kitchen Appliances",
      "Sporting Goods > Fitness, Running & Yoga > Cardio Training"
    ].join("\n")
  end

  def process_openai_response(response, filename, shop_id)
    # Extract the content from OpenAI response
    content = response.dig("choices", 0, "message", "content")

    if content.blank?
      Rails.logger.error "Empty response from OpenAI"
      return { error: "Empty response from image analysis" }
    end

    # Try to extract JSON from the content (OpenAI might wrap it in markdown code blocks)
    json_match = content.match(/```json\n(.*?)\n```/m) || content.match(/```\n(.*?)\n```/m)

    if json_match
      json_content = json_match[1]
    else
      # If no code block, try to use the entire content
      json_content = content
    end

    begin
      data = JSON.parse(json_content)
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse OpenAI JSON response: #{e.message}"
      Rails.logger.error "Raw content: #{content}"

      # Fall back to simpler parsing approach - try to extract key-value pairs
      data = extract_data_from_text(content)

      # If extraction still fails, create minimal valid response
      if data.empty? || data.values.all?(&:blank?)
        Rails.logger.warn "Fallback text extraction failed, creating minimal response"
        data = create_minimal_response(filename)
      end
    end

    # Validate and clean the data
    data = validate_and_clean_ai_response(data)

    # Process eBay category - using our improved two-stage approach
    if data["ebay_category_path"].present?
      # Log the AI-suggested category path
      Rails.logger.info "AI suggested eBay category path: #{data["ebay_category_path"]}"

      # Use our enhanced category matching service to find the best match
      ebay_category = Ai::EbayCategoryService.find_matching_ebay_category(data["ebay_category_path"])

      if ebay_category
        data["ebay_category"] = ebay_category.category_id
        data["ebay_category_confidence"] = calculate_category_confidence(data["ebay_category_path"], ebay_category)
        Rails.logger.info "Matched to eBay category: #{ebay_category.name} (ID: #{ebay_category.category_id}) - Confidence: #{data["ebay_category_confidence"]}"

        # Fetch and validate item specifics for this category
        validated_item_specifics = fetch_and_validate_item_specifics(
          data["item_specifics"] || {},
          ebay_category.category_id,
          Shop.find(shop_id)
        )
        data["item_specifics"] = validated_item_specifics[:validated_specifics]
        data["item_specifics_confidence"] = validated_item_specifics[:confidence]
        data["missing_required_specifics"] = validated_item_specifics[:missing_required]

        # Validate the match quality
        if data["ebay_category_confidence"] < 0.5
          Rails.logger.warn "Low confidence category match (#{data["ebay_category_confidence"]}) - consider manual review"
          data["requires_category_review"] = true
        end

        # Flag if item specifics are incomplete
        if validated_item_specifics[:missing_required].any?
          Rails.logger.warn "Missing required item specifics: #{validated_item_specifics[:missing_required].join(', ')}"
          data["requires_specifics_review"] = true
        end
      else
        Rails.logger.warn "Could not match AI suggested category to any eBay category: #{data["ebay_category_path"]}"
        data["requires_category_review"] = true
        # Try to find a fallback category
        data["ebay_category"] = find_fallback_category(data)
      end
    elsif data["ebay_category_id"].present?
      # Fallback if the model somehow provided a direct category ID
      data["ebay_category"] = data["ebay_category_id"]
    else
      # No category suggested, flag for review and try to infer one
      data["requires_category_review"] = true
      data["ebay_category"] = find_fallback_category(data)
    end

    # Ensure all expected fields are present (excluding price)
    result = {
      "title" => data["title"] || "Untitled Product",
      "description" => data["description"] || "Product description to be added",
      "brand" => data["brand"],
      "category" => data["category"],
      "ebay_category" => data["ebay_category"],
      "ebay_category_confidence" => data["ebay_category_confidence"] || 0.0,
      "item_specifics" => data["item_specifics"] || {},
      "item_specifics_confidence" => data["item_specifics_confidence"] || 0.0,
      "missing_required_specifics" => data["missing_required_specifics"] || [],
      "requires_category_review" => data["requires_category_review"] || false,
      "requires_specifics_review" => data["requires_specifics_review"] || false,
      "tags" => data["tags"] || []
    }

    # Log the result for debugging
    Rails.logger.info "Analyzed image results: #{result.to_json}"

    result
  end

  # Validate and clean AI response data
  def validate_and_clean_ai_response(data)
    # Ensure data is a hash
    data = {} unless data.is_a?(Hash)

    # Clean and validate title
    if data["title"].present?
      data["title"] = data["title"].strip.gsub(/[^\w\s\-\.\,\(\)\/]/, "").squeeze(" ")
      data["title"] = data["title"][0..199] if data["title"].length > 200 # Limit length
    end

    # Clean and validate description
    if data["description"].present?
      data["description"] = data["description"].strip
      data["description"] = data["description"][0..4999] if data["description"].length > 5000 # Limit length
    end

    # Validate item specifics
    if data["item_specifics"].present? && data["item_specifics"].is_a?(Hash)
      data["item_specifics"] = data["item_specifics"].select { |k, v| k.present? && v.present? }
    else
      data["item_specifics"] = {}
    end

    # Validate tags
    if data["tags"].present? && data["tags"].is_a?(Array)
      data["tags"] = data["tags"].map(&:to_s).map(&:strip).reject(&:blank?).uniq[0..19] # Limit to 20 tags
    else
      data["tags"] = []
    end

    data
  end

  # Create minimal response when AI analysis fails
  def create_minimal_response(filename)
    {
      "title" => filename.gsub(/\.[^.]*$/, "").humanize, # Use filename as title
      "description" => "Product description to be added",
      "brand" => nil,
      "ebay_category_path" => nil,
      "item_specifics" => {},
      "tags" => []
    }
  end

  # Find fallback category when primary matching fails
  def find_fallback_category(data)
    # Try to infer category from title or description
    text_to_analyze = [ data["title"], data["description"], data["tags"]&.join(" ") ].compact.join(" ").downcase

    # Simple keyword-based fallback categories
    fallback_categories = {
      /comic|manga|graphic novel/ => "259104", # Comics & Graphic Novels
      /book|novel|literature/ => "377", # Books > Fiction & Literature
      /clothing|apparel|shirt|dress|pants/ => "15724", # Women's Clothing
      /electronic|phone|computer|camera/ => "58058", # Cell Phones & Smartphones
      /toy|action figure|doll/ => "246", # Action Figures
      /jewelry|ring|necklace|watch/ => "281", # Jewelry & Watches
      /art|painting|print/ => "550", # Art
      /music|instrument|guitar/ => "619", # Musical Instruments
      /home|kitchen|furniture/ => "11700", # Home & Garden
      /sport|fitness|outdoor/ => "888" # Sporting Goods
    }

    fallback_categories.each do |pattern, category_id|
      return category_id if text_to_analyze.match?(pattern)
    end

    # Ultimate fallback - general collectibles
    "1" # Collectibles
  end

  def extract_data_from_text(content)
    # Fallback method to extract data if JSON parsing fails
    data = {}

    # Look for key patterns like "title: Product name"
    patterns = {
      "title" => /title:?\s*(.+?)(?:\n|$)/i,
      "description" => /description:?\s*(.+?)(?:\n|$)/i,
      "brand" => /brand:?\s*(.+?)(?:\n|$)/i,
      "ebay_category_path" => /ebay[_\s]category[_\s]path:?\s*(.+?)(?:\n|$)/i
    }

    patterns.each do |key, pattern|
      if match = content.match(pattern)
        data[key] = match[1].strip
      end
    end

    # Try to extract item specifics
    item_specifics_section = content.match(/item[_\s]specifics:?\s*\{(.+?)\}/m)
    if item_specifics_section
      data["item_specifics"] = {}
      item_specifics_text = item_specifics_section[1]

      # Extract key-value pairs
      item_specifics_text.scan(/"([^"]+)":\s*"([^"]+)"/).each do |key, value|
        data["item_specifics"][key] = value
      end
    end

    # Try to extract tags
    tags_section = content.match(/tags:?\s*\[(.+?)\]/m)
    if tags_section
      tags_text = tags_section[1]
      data["tags"] = tags_text.scan(/"([^"]+)"/).flatten
    end

    data
  end

  def find_ebay_category_id(category_path)
    # Use our new service for better category matching
    category = Ai::EbayCategoryService.find_best_matching_category(category_path)
    category&.category_id
  rescue => e
    Rails.logger.error "Error finding eBay category: #{e.message}"
    nil
  end

  def create_draft_product_from_analysis(analysis)
    # Check if a draft product already exists for this analysis
    existing_draft = KuralisProduct.find_by(ai_product_analysis_id: analysis.id, is_draft: true)
    if existing_draft.present?
      Rails.logger.info "Draft product already exists for analysis #{analysis.id}"
      return existing_draft
    end

    # Create the draft product using the existing method
    shop = Shop.find(analysis.shop_id)
    draft_product = KuralisProduct.create_from_ai_analysis(analysis, shop)

    if draft_product.persisted?
      Rails.logger.info "Successfully created draft product #{draft_product.id} from analysis #{analysis.id}"

      # Broadcast update to include the new draft product
      broadcast_draft_created(analysis, draft_product)
    else
      Rails.logger.error "Failed to create draft product from analysis #{analysis.id}: #{draft_product.errors.full_messages.join(', ')}"
    end

    draft_product
  rescue => e
    Rails.logger.error "Error creating draft product from analysis #{analysis.id}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    nil
  end

  def broadcast_update(analysis)
    # Use ActionCable to broadcast updates to clients
    ActionCable.server.broadcast(
      "ai_analysis_#{analysis.shop_id}",
      {
        analysis_id: analysis.id,
        status: analysis.status,
        completed: analysis.completed?,
        results: analysis.completed? ? analysis.results : nil,
        error: analysis.error_message
      }
    )
  rescue => e
    Rails.logger.error "Failed to broadcast update: #{e.message}"
  end

  def broadcast_draft_created(analysis, draft_product)
    # Broadcast that a draft product was automatically created
    ActionCable.server.broadcast(
      "ai_analysis_#{analysis.shop_id}",
      {
        analysis_id: analysis.id,
        status: analysis.status,
        completed: analysis.completed?,
        results: analysis.results,
        draft_product_created: true,
        draft_product_id: draft_product.id,
        draft_product_title: draft_product.title
      }
    )
  rescue => e
    Rails.logger.error "Failed to broadcast draft creation: #{e.message}"
  end

  # Calculate confidence score for category matching
  def calculate_category_confidence(ai_suggested_path, matched_category)
    return 0.0 unless ai_suggested_path.present? && matched_category&.full_path.present?

    # Normalize both paths for comparison
    ai_segments = ai_suggested_path.split(/\s*>\s*/).map(&:strip).map(&:downcase)
    category_segments = matched_category.full_path.split(/\s*>\s*/).map(&:strip).map(&:downcase)

    # Calculate segment overlap
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

    # Base confidence on segment overlap
    segment_confidence = matching_segments.to_f / [ ai_segments.size, category_segments.size ].max

    # Boost confidence if the leaf categories match well
    ai_leaf = ai_segments.last
    category_leaf = category_segments.last
    leaf_similarity = calculate_string_similarity(ai_leaf, category_leaf)

    # Weighted average: 60% segment overlap, 40% leaf similarity
    final_confidence = (segment_confidence * 0.6) + (leaf_similarity * 0.4)

    # Cap at 1.0
    [ final_confidence, 1.0 ].min
  end

  # Calculate string similarity using simple character overlap
  def calculate_string_similarity(str1, str2)
    return 1.0 if str1 == str2
    return 0.0 if str1.blank? || str2.blank?

    # Simple character-based similarity
    chars1 = str1.chars.to_set
    chars2 = str2.chars.to_set

    intersection = chars1 & chars2
    union = chars1 | chars2

    intersection.size.to_f / union.size
  end

  # Fetch real eBay item specifics for category and validate AI suggestions
  def fetch_and_validate_item_specifics(ai_item_specifics, category_id, shop)
    begin
      # Get the category from database
      category = EbayCategory.find_by(category_id: category_id, marketplace_id: "EBAY_US")
      return default_item_specifics_result(ai_item_specifics) unless category

      # Try to get cached item specifics first
      cached_specifics = category.metadata&.dig("item_specifics")

      if cached_specifics.blank?
        # Fetch from eBay API if not cached
        if shop.shopify_ebay_account.present?
          service = Ebay::TaxonomyService.new(shop.shopify_ebay_account)
          item_specifics = service.fetch_item_aspects(category_id)

          # Cache the results
          metadata = category.metadata || {}
          metadata["item_specifics"] = item_specifics
          category.update(metadata: metadata)
          cached_specifics = item_specifics
        end
      end

      return default_item_specifics_result(ai_item_specifics) if cached_specifics.blank?

      # Validate and map AI suggestions to eBay requirements
      validated_specifics = {}
      missing_required = []
      matched_count = 0
      total_ai_specifics = ai_item_specifics.size

      cached_specifics.each do |aspect|
        aspect_name = aspect["name"]
        is_required = aspect["required"] == true

        # Try to find matching AI suggestion
        ai_value = find_matching_ai_value(ai_item_specifics, aspect_name, aspect)

        if ai_value.present?
          # Validate the value against allowed values if they exist
          validated_value = validate_aspect_value(ai_value, aspect)
          validated_specifics[aspect_name] = validated_value
          matched_count += 1 if ai_item_specifics.values.include?(ai_value)
        elsif is_required
          missing_required << aspect_name
          validated_specifics[aspect_name] = "" # Empty required field
        end
      end

      # Calculate confidence based on how well AI suggestions matched eBay requirements
      confidence = if total_ai_specifics > 0
                    matched_count.to_f / total_ai_specifics
      else
                    0.0
      end

      # Boost confidence if no required fields are missing
      confidence += 0.2 if missing_required.empty? && cached_specifics.any? { |a| a["required"] }
      confidence = [ confidence, 1.0 ].min

      Rails.logger.info "Item specifics validation: #{matched_count}/#{total_ai_specifics} matched, #{missing_required.size} required missing, confidence: #{confidence.round(2)}"

      {
        validated_specifics: validated_specifics,
        confidence: confidence,
        missing_required: missing_required,
        available_aspects: cached_specifics
      }
    rescue => e
      Rails.logger.error "Error validating item specifics: #{e.message}"
      default_item_specifics_result(ai_item_specifics)
    end
  end

  # Find matching AI value for an eBay aspect
  def find_matching_ai_value(ai_item_specifics, aspect_name, aspect)
    # Try exact match first
    exact_match = ai_item_specifics[aspect_name]
    return exact_match if exact_match.present?

    # Try case-insensitive match
    ai_item_specifics.each do |ai_key, ai_value|
      return ai_value if ai_key.downcase == aspect_name.downcase
    end

    # Try fuzzy matching for common variations
    normalized_aspect = normalize_aspect_name(aspect_name)
    ai_item_specifics.each do |ai_key, ai_value|
      normalized_ai_key = normalize_aspect_name(ai_key)
      if normalized_ai_key == normalized_aspect ||
         normalized_ai_key.include?(normalized_aspect) ||
         normalized_aspect.include?(normalized_ai_key)
        return ai_value
      end
    end

    # Try semantic matching for known mappings
    semantic_match = get_semantic_aspect_mapping(aspect_name)
    if semantic_match
      ai_item_specifics.each do |ai_key, ai_value|
        return ai_value if semantic_match.include?(ai_key.downcase)
      end
    end

    nil
  end

  # Validate aspect value against eBay's allowed values
  def validate_aspect_value(value, aspect)
    return value unless aspect["values"].present?

    allowed_values = aspect["values"]

    # Check for exact match
    exact_match = allowed_values.find { |v| v.downcase == value.downcase }
    return exact_match if exact_match

    # Check for partial match
    partial_match = allowed_values.find { |v| v.downcase.include?(value.downcase) || value.downcase.include?(v.downcase) }
    return partial_match if partial_match

    # If no match found, return original value (eBay may accept it anyway)
    value
  end

  # Normalize aspect names for better matching
  def normalize_aspect_name(name)
    name.downcase
        .gsub(/[^a-z0-9\s]/, "")  # Remove special characters
        .gsub(/\s+/, " ")         # Normalize spaces
        .strip
  end

  # Get semantic mappings for common aspect variations
  def get_semantic_aspect_mapping(aspect_name)
    mappings = {
      "brand" => [ "brand", "manufacturer", "make" ],
      "color" => [ "color", "colour", "main color" ],
      "size" => [ "size", "dimensions", "measurement" ],
      "material" => [ "material", "fabric", "composition" ],
      "condition" => [ "condition", "state", "grade" ],
      "year" => [ "year", "publication year", "release year", "vintage" ],
      "genre" => [ "genre", "category", "type", "style" ],
      "character" => [ "character", "characters", "main character" ],
      "publisher" => [ "publisher", "published by", "imprint" ],
      "series title" => [ "series", "series title", "title series" ],
      "issue number" => [ "issue", "issue number", "#", "number" ],
      "format" => [ "format", "type", "binding" ],
      "language" => [ "language", "text language" ]
    }

    mappings[aspect_name.downcase]
  end

  # Default result when item specifics validation fails
  def default_item_specifics_result(ai_item_specifics)
    {
      validated_specifics: ai_item_specifics,
      confidence: 0.5,
      missing_required: [],
      available_aspects: []
    }
  end
end
