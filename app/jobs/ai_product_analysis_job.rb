class AiProductAnalysisJob < ApplicationJob
  require 'base64'
  
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
        results = analyze_image(image_data, filename)
        
        # Mark as completed with results
        if results.key?(:error)
          analysis.mark_as_failed!(results[:error])
        else
          analysis.mark_as_completed!(results)
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
  
  private
  
  def analyze_image(image_data, filename)
    # Call OpenAI API to analyze the image using the OpenAI Vision API
    begin
      # Encode image for API request
      base64_image = Base64.strict_encode64(image_data)
      
      # Call OpenAI Vision API
      response = call_openai_api(base64_image)
      
      # Process OpenAI response
      process_openai_response(response, filename)
    rescue => e
      Rails.logger.error "Error calling OpenAI API: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      return { error: "Failed to analyze image: #{e.message}" }
    end
  end
  
  def call_openai_api(base64_image)
    # Get the OpenAI service from your existing implementation
    openai_service = Ai::OpenaiService.new(
      model: "gpt-4o-2024-11-20",
      temperature: 0.2,
      max_tokens: 10000
    )
    
    # Construct the prompt for better structured results
    prompt = "Analyze this product image and provide detailed information. Return a JSON object with the following fields:\n\n" \
             "- title: Product title\n" \
             "- description: Detailed product description\n" \
             "- brand: Brand name if visible\n" \
             "- ebay_category_path: Full eBay category path (e.g., 'Collectibles > Comic Books & Memorabilia > Comics > Comics & Graphic Novels')\n" \
             "- item_specifics: A JSON object with key-value pairs of important product attributes\n" \
             "- tags: Array of relevant tags for the product\n\n" \
             "If you cannot determine some fields, use null values. For item_specifics, provide as many relevant details as possible based on the product image these should be specific to the ebay category."
    
    # Since the OpenAI service doesn't have a specific vision method,
    # we'll use chat_with_history and construct the messages with the image
    messages = [
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
  
  def process_openai_response(response, filename)
    # Extract the content from OpenAI response
    content = response.dig('choices', 0, 'message', 'content')
    
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
    end
    
    # Process eBay category path to find category ID if possible
    if data["ebay_category_path"].present?
      data["ebay_category"] = find_ebay_category_id(data["ebay_category_path"])
    end
    
    # Ensure all expected fields are present
    result = {
      "title" => data["title"],
      "description" => data["description"],
      "brand" => data["brand"],
      "category" => data["category"],
      "ebay_category" => data["ebay_category"],
      "item_specifics" => data["item_specifics"] || {},
      "tags" => data["tags"] || []
    }
    
    # Log the result for debugging
    Rails.logger.info "Analyzed image results: #{result.to_json}"
    
    result
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
    # This is a placeholder for a more sophisticated category lookup
    # In a real implementation, you might:
    # 1. Search your local database of eBay categories
    # 2. Call eBay API to search for matching categories
    # 3. Have a mapping table from common paths to category IDs
    
    begin
      # Try to find the category in the database
      # Example (depends on your actual database structure):
      category_terms = category_path.split(' > ').last(2)
      
      if category_terms.any?
        # Search for matching category by name
        category = EbayCategory.where('name ILIKE ?', "%#{category_terms.last}%").first
        
        if category
          return category.category_id
        else
          # More specific search if needed
          category_terms.each do |term|
            category = EbayCategory.where('name ILIKE ?', "%#{term}%").first
            return category.category_id if category
          end
        end
      end
      
      # If we couldn't find a matching category, return nil
      # The user will need to select a category manually
      return nil
    rescue => e
      Rails.logger.error "Error finding eBay category: #{e.message}"
      return nil
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
end 