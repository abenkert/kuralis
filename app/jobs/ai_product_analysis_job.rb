class AiProductAnalysisJob < ApplicationJob
  require "base64"
  require "image_processing/mini_magick"

  queue_as :default

  # Add retry logic for transient failures - use simpler retry strategy
  retry_on StandardError, wait: 5.seconds, attempts: 3

  # Don't retry on permanent failures
  discard_on ActiveRecord::RecordNotFound
  discard_on OpenAI::Error # If OpenAI API returns permanent error

  def perform(shop_id, analysis_id)
    Rails.logger.info "Starting AI analysis job for shop #{shop_id}, analysis #{analysis_id}"

    shop = Shop.find(shop_id)
    analysis = shop.ai_product_analyses.find(analysis_id)

    # Update status to processing
    analysis.update!(status: "processing")

    # Broadcast status update
    broadcast_analysis_update(shop, analysis)

    # Perform the AI analysis
    result = perform_ai_analysis(analysis)

    if result[:success]
      Rails.logger.info "AI analysis completed successfully for analysis #{analysis_id}"
      analysis.update!(
        status: "completed",
        results: result[:data]
      )

      # Auto-create draft product
      create_draft_product(analysis)

      # Broadcast completion
      broadcast_analysis_update(shop, analysis)
    else
      Rails.logger.error "AI analysis failed for analysis #{analysis_id}: #{result[:error]}"
      analysis.update!(
        status: "failed",
        error_message: result[:error]
      )

      # Broadcast failure
      broadcast_analysis_update(shop, analysis)
    end

  rescue => e
    Rails.logger.error "Unexpected error in AI analysis job: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    analysis&.update!(
      status: "failed",
      error_message: "Unexpected error: #{e.message}"
    )

    # Broadcast failure
    broadcast_analysis_update(shop, analysis) if shop && analysis

    raise # Re-raise to trigger retry logic
  end

  private

  def broadcast_analysis_update(shop, analysis)
    # Use Turbo Streams to update the UI in real-time
    Turbo::StreamsChannel.broadcast_replace_to(
      "shop_#{shop.id}_analyses",
      target: "analysis_#{analysis.id}",
      partial: "kuralis/ai_product_analyses/ai_analysis_item",
      locals: { analysis: analysis }
    )

    # Also broadcast progress banner update
    broadcast_progress_update(shop)
  rescue => e
    Rails.logger.warn "Failed to broadcast analysis update: #{e.message}"
    # Don't fail the job if broadcasting fails
  end

  def create_draft_product(analysis)
    # Auto-create draft product from analysis
    draft_product = analysis.create_draft_product_from_analysis

    if draft_product
      Rails.logger.info "Auto-created draft product #{draft_product.id} from analysis #{analysis.id}"

      # Broadcast that a draft product was created
      broadcast_draft_product_created(analysis.shop, draft_product)
    end
  rescue => e
    Rails.logger.error "Failed to create draft product from analysis #{analysis.id}: #{e.message}"
    # Don't fail the job if draft creation fails
  end

  def broadcast_progress_update(shop)
    # Get current counts
    pending_count = shop.ai_product_analyses.pending.count
    processing_count = shop.ai_product_analyses.processing.count
    total_processing = pending_count + processing_count

    # Broadcast progress update
    Turbo::StreamsChannel.broadcast_update_to(
      "shop_#{shop.id}_analyses",
      target: "processing-count",
      html: processing_count.to_s
    )

    Turbo::StreamsChannel.broadcast_update_to(
      "shop_#{shop.id}_analyses",
      target: "pending-count",
      html: pending_count.to_s
    )

    # Update the sidebar indicator
    if total_processing > 0
      Turbo::StreamsChannel.broadcast_update_to(
        "shop_#{shop.id}_analyses",
        target: "ai-progress-indicator",
        html: total_processing.to_s
      )
    else
      # Remove the indicator when no more processing
      Turbo::StreamsChannel.broadcast_remove_to(
        "shop_#{shop.id}_analyses",
        target: "ai-progress-indicator"
      )
    end

    # If no more processing, hide the banner
    if total_processing == 0
      Turbo::StreamsChannel.broadcast_update_to(
        "shop_#{shop.id}_analyses",
        target: "processing-banner",
        html: ""
      )
    end
  rescue => e
    Rails.logger.warn "Failed to broadcast progress update: #{e.message}"
  end

  def broadcast_draft_product_created(shop, draft_product)
    # This could be used to update the drafts tab in real-time
    # For now, we'll let the JavaScript handle the tab switching
    Rails.logger.info "Draft product #{draft_product.id} created and ready for finalization"
  rescue => e
    Rails.logger.warn "Failed to broadcast draft product creation: #{e.message}"
  end

  def perform_ai_analysis(analysis)
    begin
      # Get the attached image
      unless analysis.image_attachment.attached?
        return { success: false, error: "No image attached to analysis" }
      end

      # Check if the file actually exists in storage
      unless analysis.image_attachment.blob.present?
        return { success: false, error: "Image blob is missing" }
      end

      # Verify file exists in storage before processing
      begin
        analysis.image_attachment.blob.open { |file| file.read(1) }
      rescue ActiveStorage::FileNotFoundError => e
        Rails.logger.error "File not found in storage for analysis #{analysis.id}: #{e.message}"
        return { success: false, error: "Image file not found in storage. The file may have been deleted." }
      end

      # Process and compress image for faster analysis
      processed_image_data = process_image_for_analysis(analysis.image_attachment)

      # Get the filename
      filename = analysis.image_attachment.filename.to_s

      # Analyze the image with optimized settings
      results = analyze_image(processed_image_data, filename, analysis.shop_id)

      # Check if analysis was successful
      if results.key?(:error)
        { success: false, error: results[:error] }
      else
        { success: true, data: results }
      end
    rescue => e
      Rails.logger.error "Error in perform_ai_analysis: #{e.message}"
      { success: false, error: "Failed to analyze image: #{e.message}" }
    end
  end

  # Process and compress image for faster AI analysis
  def process_image_for_analysis(image_attachment)
    # Download the original image
    original_data = image_attachment.download

    # Process with ImageProcessing to optimize for AI analysis
    # Resize to max 1024px on longest side and compress to reduce API payload
    processed_blob = ImageProcessing::MiniMagick
      .source(StringIO.new(original_data))
      .resize_to_limit(1024, 1024)  # Smaller size for faster processing
      .convert("jpeg")              # Convert to JPEG for better compression
      .saver(quality: 85)           # Fix: use saver instead of call with quality
      .call

    processed_blob.read
  rescue => e
    Rails.logger.warn "Failed to process image, using original: #{e.message}"
    # Fall back to original if processing fails
    original_data
  end

  def analyze_image(image_data, filename, shop_id)
    # Call OpenAI API to analyze the image using the OpenAI Vision API
    begin
      # Encode image for API request
      base64_image = Base64.strict_encode64(image_data)

      # Call OpenAI Vision API with optimized settings
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
      max_tokens: 8000  # Reduced for faster response
    )

    # First, do a quick analysis to determine product type (using low detail)
    product_type = determine_product_type(base64_image, openai_service)

    # Get relevant category examples based on product type
    category_examples = get_relevant_category_examples(product_type)

    # Get the eBay category prompt
    category_prompt = Ai::EbayCategoryService.generate_ebay_category_prompt

    # Enhanced prompt with relevant eBay category examples
    prompt = generate_enhanced_prompt(product_type, category_examples)

    messages = [
      {
        role: "system",
        content: category_prompt
      },
      {
        role: "user",
        content: [
          { type: "text", text: "Analyze this product image and extract detailed information. Based on the image, this appears to be a #{product_type}.\n\nHere are some relevant eBay category examples for this type of product:\n#{category_examples}\n\n#{prompt}\n\nReturn ONLY the JSON response, no additional text." },
          {
            type: "image_url",
            image_url: {
              url: "data:image/jpeg;base64,#{base64_image}",
              detail: product_type.match?(/comic book|comic|manga|graphic novel/) ? "high" : "low"  # Use high detail for comics to read text clearly
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
        max_tokens: 8000,  # Reduced for faster response
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
    quick_prompt = <<~PROMPT
      Look at this image and identify the specific product type. Be as specific as possible while staying accurate.

      Respond with ONLY the product type from this list (choose the most specific match):
      - comic book
      - manga
      - graphic novel
      - book
      - magazine
      - trading card
      - action figure
      - toy
      - doll
      - electronics
      - phone
      - computer
      - camera
      - video game
      - clothing
      - shoes
      - jewelry
      - watch
      - collectible
      - antique
      - art
      - painting
      - print
      - musical instrument
      - automotive part
      - home decor
      - kitchen item
      - furniture
      - sports equipment
      - fitness equipment
      - tool
      - craft supply
      - beauty product
      - health product
      - pet supply
      - general item

      If you cannot determine the specific type, use "general item".
      Respond with ONLY the product type, nothing else.
    PROMPT

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
        max_tokens: 20,
        temperature: 0.0  # Use 0.0 for more consistent type detection
      }
    )

    product_type = response.dig("choices", 0, "message", "content")&.strip&.downcase || "general item"
    Rails.logger.info "Determined product type: #{product_type}"
    product_type
  rescue => e
    Rails.logger.warn "Failed to determine product type: #{e.message}"
    "general item"
  end

  # Get relevant category examples based on product type
  def get_relevant_category_examples(product_type)
    case product_type
    when /comic book|comic|manga|graphic novel/
      get_books_comics_categories
    when /book|magazine/
      get_books_categories
    when /trading card/
      get_trading_card_categories
    when /action figure|toy|doll/
      get_toys_categories
    when /electronics|phone|computer|camera|video game/
      get_electronics_categories
    when /clothing|shoes/
      get_clothing_categories
    when /jewelry|watch/
      get_jewelry_categories
    when /collectible|antique/
      get_collectibles_categories
    when /art|painting|print/
      get_art_categories
    when /musical instrument/
      get_musical_categories
    when /automotive/
      get_automotive_categories
    when /home decor|kitchen|furniture/
      get_home_garden_categories
    when /sports|fitness/
      get_sports_categories
    when /tool/
      get_tools_categories
    when /craft/
      get_crafts_categories
    when /beauty|health/
      get_health_beauty_categories
    when /pet/
      get_pet_categories
    else
      get_general_category_examples
    end
  end

  # Enhanced prompt generation based on product type
  def generate_enhanced_prompt(product_type, category_examples)
    base_structure = <<~BASE
      Please provide a JSON response with the following structure:
      {
        "title": "Specific product title with key details",
        "description": "Detailed description including condition, features, and relevant details",
        "brand": "Brand or publisher name",
        "condition": "Product condition (new, like_new, very_good, good, acceptable)",
        "category": "General product category",
        "ebay_category": "Most specific eBay category path from the examples above",
        "item_specifics": {
          "key": "value pairs of important product attributes"
        },
        "tags": ["relevant", "search", "tags"],
        "confidence_notes": {
          "category_confidence": 0.85,
          "specifics_confidence": 0.75,
          "overall_confidence": 0.80
        }
      }
    BASE

    case product_type
    when /comic book|comic|manga|graphic novel/
      <<~COMIC_PROMPT
        #{base_structure}

        **CRITICAL FOR COMIC BOOKS**: Pay special attention to these details:

        1. **ISSUE NUMBER**: Look very carefully at the cover for the issue number. It's usually displayed prominently on the front cover, often as "#1", "#2", "Vol 1 #1", etc. This is ESSENTIAL for comic identification.

        2. **SERIES TITLE**: The main title of the comic series (e.g., "Amazing Spider-Man", "Fathom", "X-Men")

        3. **PUBLISHER**: Look for publisher logos/names (Marvel, DC, Image, Top Cow, Dark Horse, etc.)

        4. **PUBLICATION DATE**: Look for month/year on the cover or spine (e.g., "March 2023", "2023")

        5. **VARIANT COVERS**: Note if it says "Variant", "Cover A/B/C", "1:10", "1:25", etc.

        6. **CONDITION**: Assess visible wear, creases, spine stress, corner damage

        For item_specifics, include:
        - "Issue Number": The specific issue number (REQUIRED)
        - "Series Title": The main series name
        - "Publisher": The publishing company
        - "Publication Year": Specific year if visible
        - "Publication Month": Month if visible
        - "Format": "Single Issue" or "Trade Paperback" or "Graphic Novel"
        - "Variant": If it's a variant cover
        - "Key Issue": If it's a first appearance, death, origin, etc.
        - "Grade": Your assessment of condition
        - "Era": "Modern Age (1985-Present)", "Copper Age (1984-1991)", etc.

        Focus on accuracy over speed. If you can't clearly see the issue number, say "Issue number not clearly visible" rather than guessing.
      COMIC_PROMPT
    else
      base_structure + "\n\nFocus on accuracy and be specific. If you cannot determine certain details, use reasonable defaults or leave fields empty."
    end
  end

  # Category examples for different product types
  def get_books_comics_categories
    [
      "Collectibles > Comic Books & Memorabilia > Comics > Comics & Graphic Novels",
      "Collectibles > Comic Books & Memorabilia > Comics > Single Issues > Modern Age (1992-Now)",
      "Collectibles > Comic Books & Memorabilia > Comics > Single Issues > Copper Age (1984-1991)",
      "Collectibles > Comic Books & Memorabilia > Comics > Single Issues > Bronze Age (1970-1983)",
      "Collectibles > Comic Books & Memorabilia > Comics > Single Issues > Silver Age (1956-1969)",
      "Collectibles > Comic Books & Memorabilia > Comics > Single Issues > Golden Age (1938-1955)",
      "Collectibles > Comic Books & Memorabilia > Comics > Trade Paperbacks & Hardcovers",
      "Collectibles > Comic Books & Memorabilia > Comics > Manga & Asian Comics",
      "Collectibles > Comic Books & Memorabilia > Comics > Independent & Small Press",
      "Collectibles > Comic Books & Memorabilia > Comics > Variant Covers"
    ].join("\n")
  end

  def get_books_categories
    [
      "Books > Fiction & Literature",
      "Books > Textbooks, Education & Reference",
      "Books > Children & Young Adults",
      "Books > Antiquarian & Collectible"
    ].join("\n")
  end

  def get_trading_card_categories
    [
      "Collectibles > Trading Cards > Sports Trading Cards > Baseball Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Football Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Basketball Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Hockey Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Soccer Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Wrestling Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Baseball & Softball Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Basketball & Football Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Hockey & Soccer Cards",
      "Collectibles > Trading Cards > Sports Trading Cards > Wrestling & Baseball Cards"
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

  def get_tools_categories
    [
      "Home & Garden > Tools & Workshop Equipment > Hand Tools",
      "Home & Garden > Tools & Workshop Equipment > Power Tools",
      "Home & Garden > Tools & Workshop Equipment > Measuring Tools",
      "Home & Garden > Tools & Workshop Equipment > Woodworking Tools",
      "Home & Garden > Tools & Workshop Equipment > Automotive Tools"
    ].join("\n")
  end

  def get_crafts_categories
    [
      "Home & Garden > Tools & Workshop Equipment > Woodworking Tools",
      "Home & Garden > Tools & Workshop Equipment > Jewelry Making Tools",
      "Home & Garden > Tools & Workshop Equipment > Sewing & Quilting Tools",
      "Home & Garden > Tools & Workshop Equipment > Painting & Sculpting Tools",
      "Home & Garden > Tools & Workshop Equipment > General Crafting Tools"
    ].join("\n")
  end

  def get_health_beauty_categories
    [
      "Beauty & Personal Care > Skin Care > Face Care",
      "Beauty & Personal Care > Skin Care > Body Care",
      "Beauty & Personal Care > Hair Care > Hair Styling",
      "Beauty & Personal Care > Hair Care > Hair Coloring",
      "Beauty & Personal Care > Hair Care > Hair Care",
      "Beauty & Personal Care > Makeup",
      "Beauty & Personal Care > Skincare",
      "Beauty & Personal Care > Bath & Body",
      "Beauty & Personal Care > Fragrance",
      "Beauty & Personal Care > Oral Care"
    ].join("\n")
  end

  def get_pet_categories
    [
      "Pet Supplies > Dog Supplies",
      "Pet Supplies > Cat Supplies",
      "Pet Supplies > Fish Supplies",
      "Pet Supplies > Bird Supplies",
      "Pet Supplies > Small Animal Supplies",
      "Pet Supplies > Reptile & Amphibian Supplies",
      "Pet Supplies > Aquatic Supplies",
      "Pet Supplies > Horse Supplies",
      "Pet Supplies > Livestock Supplies",
      "Pet Supplies > Other Pet Supplies"
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
      "ebay_category_confidence" => data["confidence_notes"]&.dig("category_confidence") || data["ebay_category_confidence"] || 0.0,
      "item_specifics" => data["item_specifics"] || {},
      "item_specifics_confidence" => data["confidence_notes"]&.dig("specifics_confidence") || data["item_specifics_confidence"] || 0.0,
      "missing_required_specifics" => data["missing_required_specifics"] || [],
      "requires_category_review" => data["requires_category_review"] || false,
      "requires_specifics_review" => data["requires_specifics_review"] || false,
      "tags" => data["tags"] || [],
      "confidence_notes" => data["confidence_notes"] || {}
    }

    # Use AI confidence scores to determine if review is needed
    if result["confidence_notes"]["category_confidence"].present? && result["confidence_notes"]["category_confidence"] < 0.7
      result["requires_category_review"] = true
    end

    if result["confidence_notes"]["specifics_confidence"].present? && result["confidence_notes"]["specifics_confidence"] < 0.6
      result["requires_specifics_review"] = true
    end

    # Special validation for comic books
    if data["category"]&.downcase&.include?("comic") || data["ebay_category_path"]&.include?("Comic")
      validate_comic_book_specifics(result)
    end

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
      cleaned_specifics = {}
      data["item_specifics"].each do |key, value|
        next if key.blank?

        # Handle array values (like multiple characters)
        if value.is_a?(Array)
          # Join array values with commas for eBay compatibility
          cleaned_value = value.compact.map(&:to_s).join(", ")
          cleaned_specifics[key] = cleaned_value if cleaned_value.present?
        elsif value.present?
          cleaned_specifics[key] = value.to_s
        end
      end
      data["item_specifics"] = cleaned_specifics
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
    value_type = aspect["value_type"]

    # For text_with_suggestions, the values are just suggestions, not strict requirements
    # So we should keep the original value even if it's not in the list
    if value_type == "text_with_suggestions"
      Rails.logger.info "Aspect '#{aspect['name']}' is text_with_suggestions - keeping original value: #{value}"
      return value
    end

    # For select fields, we need to find a match in the allowed values
    # Check for exact match
    exact_match = allowed_values.find { |v| v.downcase == value.downcase }
    return exact_match if exact_match

    # Check for partial match
    partial_match = allowed_values.find { |v| v.downcase.include?(value.downcase) || value.downcase.include?(v.downcase) }
    return partial_match if partial_match

    # If no match found and it's a strict select field, we might want to return nil or empty
    # But for now, return original value (eBay may accept it anyway)
    Rails.logger.warn "No match found for aspect '#{aspect['name']}' value '#{value}' in allowed values: #{allowed_values.first(5).join(', ')}#{allowed_values.size > 5 ? '...' : ''}"
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
      "language" => [ "language", "text language" ],
      # Comic book specific mappings
      "publication month" => [ "publication month", "month", "cover date" ],
      "era" => [ "era", "age", "comic age", "publication era" ],
      "variant" => [ "variant", "variant cover", "cover variant", "special cover" ],
      "key issue" => [ "key issue", "first appearance", "origin", "death", "key" ],
      "grade" => [ "grade", "condition grade", "comic grade" ],
      "certification" => [ "certification", "cgc", "cbcs", "graded" ],
      "artist" => [ "artist", "penciler", "illustrator", "cover artist" ],
      "writer" => [ "writer", "author", "story by" ],
      "universe" => [ "universe", "marvel universe", "dc universe" ],
      "team" => [ "team", "superhero team", "group" ]
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

  # Validate comic book specific requirements
  def validate_comic_book_specifics(result)
    item_specifics = result["item_specifics"] || {}

    # Check for critical comic book fields
    issue_number = item_specifics["Issue Number"] || item_specifics["issue number"] ||
                   item_specifics["Issue"] || item_specifics["#"]

    series_title = item_specifics["Series Title"] || item_specifics["series title"] ||
                   item_specifics["Series"] || item_specifics["Title"]

    publisher = item_specifics["Publisher"] || item_specifics["publisher"] ||
                result["brand"]

    # Flag for review if critical fields are missing
    missing_critical = []
    missing_critical << "Issue Number" if issue_number.blank?
    missing_critical << "Series Title" if series_title.blank?
    missing_critical << "Publisher" if publisher.blank?

    if missing_critical.any?
      result["requires_specifics_review"] = true
      result["missing_critical_comic_fields"] = missing_critical
      Rails.logger.warn "Comic book missing critical fields: #{missing_critical.join(', ')}"
    end

    # Enhance title with issue number if available and not already included
    if issue_number.present? && series_title.present?
      enhanced_title = "#{series_title} ##{issue_number}"
      enhanced_title += " - #{publisher}" if publisher.present?

      # Only update if current title doesn't already include issue number
      unless result["title"].include?("#") || result["title"].include?("Issue")
        result["title"] = enhanced_title
        Rails.logger.info "Enhanced comic title: #{enhanced_title}"
      end
    end

    result
  end
end
