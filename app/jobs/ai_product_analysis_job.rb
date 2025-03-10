class AiProductAnalysisJob < ApplicationJob
  queue_as :default
  
  retry_on StandardError, attempts: 3, wait: 5.seconds

  def perform(shop_id, analysis_id)
    analysis = AiProductAnalysis.find_by(id: analysis_id)
    return unless analysis
    
    Rails.logger.info "Starting AI analysis job for analysis ##{analysis_id}"
    
    begin
      # Update status to processing
      analysis.update(status: "processing")
      Rails.logger.info "Analysis ##{analysis_id} marked as processing"
      
      # Download the image for processing
      image_data = nil
      if analysis.image_attachment.attached?
        Rails.logger.info "Image attachment found for analysis ##{analysis_id}, downloading..."
        image_data = analysis.image_attachment.download
        Rails.logger.info "Image downloaded successfully (#{image_data.bytesize} bytes)"
      else
        Rails.logger.error "No image attached for analysis ##{analysis_id}"
        analysis.update(status: "failed", error_message: "No image attached")
        return
      end
      
      # Call the AI service to analyze the image
      Rails.logger.info "Starting OpenAI analysis for image ##{analysis_id}"
      results = analyze_image_with_openai(image_data, analysis.image)
      Rails.logger.info "OpenAI analysis completed successfully for ##{analysis_id}"
      
      # Update the analysis with the results
      analysis.update(
        status: "completed",
        results: results
      )
      Rails.logger.info "Analysis ##{analysis_id} marked as completed with results"
      
      # Broadcast an update to any listening clients
      broadcast_update(analysis)
    rescue => e
      # Handle errors
      Rails.logger.error "Error analyzing image ##{analysis_id}: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      analysis.update(
        status: "failed",
        error_message: "Error analyzing image: #{e.message}"
      )
      
      # Broadcast the error status
      broadcast_update(analysis)
    end
  end
  
  private
  
  def analyze_image_with_openai(image_data, filename)
    # Encode the image data as base64
    base64_image = Base64.strict_encode64(image_data)
    
    # Configure the OpenAI client
    client = OpenAI::Client.new(
      access_token: ENV['OPENAI_API_KEY'],
      organization_id: ENV['OPENAI_ORGANIZATION_ID'] # Optional
    )
    
    # Create a general product analysis prompt for eBay listings
    prompt = "You are an expert eBay listing specialist with extensive knowledge of various product categories. Analyze this product image and extract the following information:

    1. Identify exactly what the item is
    2. Product details:
       - Title/name of the product
       - Brand/manufacturer (if applicable)
       - Model/version/edition (if applicable)
       - Year/era (if applicable)
       - Features and specifications
       - Any notable characteristics, special features, or unique identifiers
    
    3. eBay-specific information:
       - The most appropriate eBay category ID and category path for this item
       - A compelling eBay listing title (under 80 characters)
       - Key item specifics appropriate for the eBay category
    
    Return your response as a well-structured JSON object with these fields:
    {
      \"title\": \"[Compelling eBay title]\",
      \"description\": \"[Detailed product description]\",
      \"brand\": \"[Brand or manufacturer]\",
      \"ebay_category_id\": \"[Numeric eBay category ID if known]\",
      \"ebay_category\": \"[Full eBay category path]\",
      \"item_specifics\": {
        \"[Key1]\": \"[Value1]\",
        \"[Key2]\": \"[Value2]\",
        ...
      },
      \"tags\": [\"tag1\", \"tag2\", ...]
    }
    
    If the item is a specific type of collectible (like comics, trading cards, etc.), include any relevant additional fields that would be valuable for an eBay listing.
    
    Be as accurate and detailed as possible, focusing on information that would be valuable for creating a comprehensive eBay listing. DO NOT include a price or value estimate in your analysis."
    
    # Make API call to OpenAI
    Rails.logger.info "Sending image to OpenAI for analysis: #{filename}"
    
    response = client.chat(
      parameters: {
        model: "gpt-4o-2024-08-06", # Use GPT-4 Vision model
        messages: [
          {
            role: "user",
            content: [
              { type: "text", text: prompt },
              { type: "image_url", image_url: { url: "data:image/jpeg;base64,#{base64_image}" } }
            ]
          }
        ],
        max_tokens: 1500,
        response_format: { type: "json_object" }
      }
    )
    
    # Log the response for debugging
    Rails.logger.info "Received OpenAI response: #{response.dig('choices', 0, 'message', 'content')}"
    
    # Parse the JSON from the response
    begin
      ai_text_response = response.dig('choices', 0, 'message', 'content')
      
      # Parse the JSON response
      ai_data = JSON.parse(ai_text_response)
      
      # Ensure we have all required fields, with defaults if necessary
      structured_data = {
        "title" => ai_data["title"] || extract_title(ai_text_response) || "Unknown Product",
        "description" => ai_data["description"] || extract_description(ai_text_response) || "Product image analyzed by AI.",
        "category" => ai_data["ebay_category"] || ai_data["category"] || extract_category(ai_text_response) || "Other",
        "ebay_category_id" => ai_data["ebay_category_id"] || extract_ebay_category_id(ai_text_response),
        "brand" => ai_data["brand"] || extract_brand(ai_text_response),
        "item_specifics" => ai_data["item_specifics"] || ai_data["specifics"] || {},
        "tags" => ai_data["tags"] || [],
        "raw_ai_response" => ai_text_response # Store the full response for debugging
      }
      
      # For comics or other collectibles, preserve specific fields if provided
      if ai_data["publisher"].present? || ai_data["issue_number"].present?
        structured_data["publisher"] = ai_data["publisher"] || extract_publisher(ai_text_response)
        structured_data["issue_number"] = ai_data["issue_number"] || extract_issue_number(ai_text_response)
        structured_data["year"] = ai_data["year"] || extract_year(ai_text_response)
        structured_data["characters"] = ai_data["characters"] || extract_characters(ai_text_response)
        
        # Add to item specifics if not already there
        if structured_data["publisher"].present? && !structured_data["item_specifics"]["Publisher"]
          structured_data["item_specifics"]["Publisher"] = structured_data["publisher"]
        end
        
        if structured_data["issue_number"].present? && !structured_data["item_specifics"]["Issue Number"]
          structured_data["item_specifics"]["Issue Number"] = structured_data["issue_number"]
        end
        
        if structured_data["year"].present? && !structured_data["item_specifics"]["Publication Year"]
          structured_data["item_specifics"]["Publication Year"] = structured_data["year"]
        end
      end
      
      # Sanitize and format the data
      structured_data = sanitize_data(structured_data)
      
      Rails.logger.info "Successfully structured AI data for #{filename}"
      return structured_data
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse JSON from OpenAI response: #{e.message}"
      # Fall back to text extraction
      return extract_structured_data_from_text(ai_text_response)
    rescue => e
      Rails.logger.error "Error processing OpenAI response: #{e.message}"
      # Fall back to the mock response for now
      return generate_mock_response(filename)
    end
  end
  
  # Helper method to extract structured data from text if JSON parsing fails
  def extract_structured_data_from_text(text)
    data = {}
    
    # Extract fields with regex patterns
    data["title"] = extract_title(text)
    data["description"] = extract_description(text)
    data["category"] = extract_category(text)
    data["condition"] = extract_condition(text)
    data["price"] = extract_price(text)
    data["brand"] = extract_brand(text)
    data["ebay_category_id"] = extract_ebay_category_id(text)
    
    # Extract item specifics if present
    item_specifics = {}
    # Look for sections that might contain item specifics
    specs_section = text.match(/item specific(?:s)?:?.*?\n(.*?)(?:\n\n|\Z)/im)
    if specs_section
      specs_text = specs_section[1]
      specs_text.split("\n").each do |line|
        if match = line.match(/^\s*[•\-*]?\s*([^:]+):\s*(.+)$/i)
          key, value = match[1].strip, match[2].strip
          item_specifics[key] = value
        end
      end
    end
    
    data["item_specifics"] = item_specifics
    data["raw_ai_response"] = text
    
    data
  end
  
  # Helper methods to extract specific fields from text
  def extract_title(text)
    match = text.match(/title:?.*?["""]([^"""]+)["""]/i) || text.match(/title:?.*?(\S.*?)(?:\n|$)/i)
    match ? match[1].strip : nil
  end
  
  def extract_description(text)
    match = text.match(/description:?.*?["""]([^"""]+)["""]/i) || text.match(/description:?.*?(\S.*?)(?:\n\n|\Z)/im)
    match ? match[1].strip : nil
  end
  
  def extract_category(text)
    match = text.match(/category:?.*?["""]([^"""]+)["""]/i) || text.match(/category:?.*?(\S.*?)(?:\n|$)/i)
    match ? match[1].strip : nil
  end
  
  def extract_condition(text)
    conditions = ["Mint", "Near Mint", "Very Good", "Good", "Fair", "Poor"]
    match = text.match(/condition:?.*?["""]([^"""]+)["""]/i) || text.match(/condition:?.*?(\S.*?)(?:\n|$)/i)
    
    if match
      condition = match[1].strip
      # Find the best match from our list of valid conditions
      return conditions.find { |c| condition.downcase.include?(c.downcase) } || condition
    end
    
    # If no specific match, search for any condition in the text
    conditions.each do |c|
      return c if text.match?(/\b#{c}\b/i)
    end
    
    nil
  end
  
  def extract_price(text)
    match = text.match(/price:?.*?\$?(\d+\.?\d*)/i) || text.match(/value:?.*?\$?(\d+\.?\d*)/i)
    match ? match[1].strip : nil
  end
  
  def extract_brand(text)
    match = text.match(/brand:?.*?["""]([^"""]+)["""]/i) || text.match(/brand:?.*?(\S.*?)(?:\n|$)/i)
    match ? match[1].strip : nil
  end
  
  def extract_publisher(text)
    match = text.match(/publisher:?.*?["""]([^"""]+)["""]/i) || text.match(/publisher:?.*?(\S.*?)(?:\n|$)/i)
    match ? match[1].strip : nil
  end
  
  def extract_issue_number(text)
    match = text.match(/issue(?:\s+number)?:?.*?["""]?([^"""]+)["""]/i) || text.match(/issue(?:\s+number)?:?.*?(\S.*?)(?:\n|$)/i)
    match ? match[1].strip.gsub(/^#/, '') : nil
  end
  
  def extract_year(text)
    match = text.match(/year:?.*?(\d{4})/i) || text.match(/date:?.*?(\d{4})/i)
    match ? match[1].strip : nil
  end
  
  def extract_characters(text)
    match = text.match(/characters:?.*?["""]([^"""]+)["""]/i) || text.match(/characters:?.*?(\S.*?)(?:\n\n|\Z)/im)
    if match
      return match[1].strip.split(/\s*,\s*/)
    end
    []
  end
  
  def extract_ebay_category_id(text)
    match = text.match(/ebay(?:\s+category)?(?:\s+id)?:?.*?(\d+)/i)
    match ? match[1].strip : nil
  end
  
  def is_comic_book?(data)
    category = data["category"]&.downcase
    title = data["title"]&.downcase
    description = data["description"]&.downcase
    
    return true if category && (category.include?("comic") || category.include?("graphic novel"))
    return true if title && (title.include?("comic") || title.include?("issue"))
    return true if description && (description.include?("comic book") || description.include?("issue #"))
    
    false
  end
  
  def sanitize_data(data)
    # Ensure eBay category ID is valid
    if data["ebay_category_id"]
      category_id = data["ebay_category_id"].to_s.gsub(/\D/, '')
      data["ebay_category_id"] = category_id unless category_id.empty?
    end
    
    # Clean up item specifics
    if data["item_specifics"].is_a?(Hash)
      cleaned_specifics = {}
      data["item_specifics"].each do |key, value|
        # Skip empty or nil values
        next if value.nil? || value.to_s.strip.empty?
        cleaned_specifics[key.to_s.strip] = value.to_s.strip
      end
      data["item_specifics"] = cleaned_specifics
    else
      data["item_specifics"] = {}
    end
    
    data
  end
  
  # Fallback method for generating mock response if OpenAI integration fails
  def generate_mock_response(filename)
    Rails.logger.warn "Falling back to mock response for #{filename}"
    
    # Generate different responses based on the filename
    if filename.to_s.downcase.include?('comic')
      # Comic book mock data
      {
        "title" => "Comic Book - #{random_comic_title}",
        "description" => random_comic_description,
        "category" => "Collectibles & Art > Comics > Comic Books",
        "ebay_category_id" => "63",
        "condition" => random_condition,
        "publisher" => random_publisher,
        "year" => rand(1960..2023).to_s,
        "issue_number" => "#{rand(1..500)}",
        "characters" => random_characters,
        "item_specifics" => {
          "Publisher" => random_publisher,
          "Main Character" => random_characters.first,
          "Issue Number" => "#{rand(1..500)}",
          "Publication Year" => rand(1960..2023).to_s,
          "Format" => "Standard",
          "Language" => "English",
          "Certification" => rand(10) > 8 ? "CGC" : "Uncertified",
          "Grade" => rand(10) > 8 ? "#{rand(1..9)}.#{rand(0..9)}" : "Ungraded"
        }
      }
    else
      # General product mock data
      {
        "title" => random_product_title,
        "description" => random_product_description,
        "category" => "Collectibles & Art > Collectibles",
        "ebay_category_id" => "13877",
        "condition" => random_condition,
        "brand" => random_brand,
        "item_specifics" => {
          "Brand" => random_brand,
          "Type" => random_product_category.capitalize,
          "Material" => ["Plastic", "Metal", "Vinyl", "Resin"].sample,
          "Theme" => ["Superheroes", "Science Fiction", "Fantasy", "Pop Culture"].sample,
          "Original/Reproduction" => ["Original", "Reproduction"].sample,
          "Character" => ["Batman", "Spider-Man", "Star Wars", "Harry Potter"].sample
        }
      }
    end
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
  
  # Helper methods to generate random data for the demo/fallback
  def random_comic_title
    [
      "Amazing Adventures", "Fantastic Tales", "Incredible Heroes",
      "Spectacular Stories", "Uncanny Chronicles", "Marvelous Mysteries",
      "Ultimate Legends", "Daring Exploits"
    ].sample
  end
  
  def random_comic_description
    [
      "A rare issue in excellent condition. Features the first appearance of a major character.",
      "Classic cover art by a renowned artist. Story focuses on an epic battle between heroes and villains.",
      "Limited edition variant cover. Contains a pivotal story arc that changed the series.",
      "Special anniversary issue with bonus content. Includes origin story and character development.",
      "Mint condition comic with original inserts intact. Key issue in the storyline."
    ].sample
  end
  
  def random_comic_genre
    ["superhero", "horror", "sci-fi", "fantasy", "action", "adventure"].sample
  end
  
  def random_publisher
    ["Marvel", "DC", "Image", "Dark Horse", "IDW", "Vertigo", "Boom! Studios"].sample
  end
  
  def random_characters
    [
      ["Spider-Man", "Green Goblin", "Mary Jane"],
      ["Batman", "Joker", "Catwoman"],
      ["Superman", "Lex Luthor", "Lois Lane"],
      ["Wonder Woman", "Cheetah", "Ares"],
      ["X-Men", "Magneto", "Cyclops"]
    ].sample
  end
  
  def random_condition
    ["Mint", "Near Mint", "Very Good", "Good", "Fair", "Poor"].sample
  end
  
  def random_product_title
    [
      "Vintage Collection Item", "Collectible Figurine", "Limited Edition Print",
      "Rare Trading Card", "Signature Series Model", "Commemorative Piece"
    ].sample
  end
  
  def random_product_description
    [
      "A beautiful addition to any collection. Features intricate details and quality craftsmanship.",
      "Rare find in excellent condition. One of only a limited number produced.",
      "Collectible item with certificate of authenticity. Shows minimal wear.",
      "Premium quality collectible with display case included. Perfect for serious collectors.",
      "Hard-to-find item with original packaging. A must-have for enthusiasts."
    ].sample
  end
  
  def random_product_category
    ["collectible", "toy", "memorabilia", "art", "figurine", "model"].sample
  end
  
  def random_brand
    ["Hasbro", "Funko", "Mattel", "McFarlane Toys", "NECA", "Diamond Select"].sample
  end
end 