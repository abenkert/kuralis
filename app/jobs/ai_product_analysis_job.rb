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
      Rails.logger.info "Starting AI analysis for image ##{analysis_id}"
      results = analyze_image(image_data, analysis.image)
      Rails.logger.info "AI analysis completed successfully for ##{analysis_id}"
      
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
  
  def analyze_image(image_data, filename)
    # This is a placeholder for the actual AI analysis
    # In a real implementation, this would call an AI service API
    Rails.logger.info "Analyzing image: #{filename}"
    
    # Simulate processing time (shorter for testing)
    sleep(2)
    
    # For comic books, generate more specific results
    if filename.to_s.downcase.include?('comic')
      # Return comic book specific results
      return {
        "title" => "Comic Book - #{random_comic_title}",
        "description" => random_comic_description,
        "price" => format('%.2f', rand(5.99..299.99)),
        "condition" => random_condition,
        "publisher" => random_publisher,
        "year" => rand(1960..2023).to_s,
        "issue_number" => "##{rand(1..500)}",
        "tags" => ["comic", "collectible", random_comic_genre]
      }
    else
      # Return more generic product results
      return {
        "title" => random_product_title,
        "description" => random_product_description,
        "price" => format('%.2f', rand(5.99..199.99)),
        "condition" => random_condition,
        "brand" => random_brand,
        "tags" => ["product", random_product_category]
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
  
  # Helper methods to generate random data for the demo
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