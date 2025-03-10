class AnalyzeProductImageJob < ApplicationJob
  queue_as :default

  def perform(analysis_id)
    analysis = AiProductAnalysis.find(analysis_id)
    
    # Mark as processing
    analysis.mark_as_processing!
    
    begin
      # Initialize OpenAI service
      openai_service = AI::OpenaiService.new(
        model: "gpt-4o",
        temperature: 0.3,
        max_tokens: 2000
      )
      
      # Get image URL
      image_url = Rails.application.routes.url_helpers.rails_blob_url(analysis.image_file)
      
      # Prepare messages for OpenAI
      messages = [
        {
          role: "system",
          content: "You are an expert in product identification and categorization, especially for collectibles like comic books. Analyze the image and extract detailed product information."
        },
        {
          role: "user",
          content: [
            {
              type: "text",
              text: "Analyze this product image and provide the following information in JSON format:\n\n1. Title (be specific and include series, issue number, year if visible)\n2. Description (detailed, including publisher, key characters, condition notes)\n3. Brand/Publisher\n4. Condition (New, Like New, Very Good, Good, Acceptable, etc.)\n5. Category (e.g., Comic Book, Graphic Novel, etc.)\n6. Most appropriate eBay category\n7. Item specifics (key-value pairs of important attributes)\n\nReturn ONLY valid JSON with these fields."
            },
            {
              type: "image_url",
              image_url: {
                url: image_url
              }
            }
          ]
        }
      ]
      
      # Call OpenAI API
      response = openai_service.chat_with_history(messages)
      
      # Parse JSON response
      begin
        json_response = JSON.parse(response[:content])
        
        # Mark as completed with results
        analysis.mark_as_completed!(json_response)
        
        # Create notification
        NotificationService.success(
          shop: analysis.shop,
          title: "Image Analysis Completed",
          message: "Successfully analyzed image: #{analysis.image}",
          category: "ai_analysis"
        )
      rescue JSON::ParserError => e
        # If JSON parsing fails, try to extract JSON from the response
        json_match = response[:content].match(/```json\n(.*?)\n```/m) || 
                    response[:content].match(/\{.*\}/m)
        
        if json_match
          begin
            json_response = JSON.parse(json_match[1] || json_match[0])
            analysis.mark_as_completed!(json_response)
            
            NotificationService.success(
              shop: analysis.shop,
              title: "Image Analysis Completed",
              message: "Successfully analyzed image: #{analysis.image}",
              category: "ai_analysis"
            )
          rescue JSON::ParserError => e2
            analysis.mark_as_failed!("Failed to parse JSON response: #{e2.message}")
            
            NotificationService.error(
              shop: analysis.shop,
              title: "Image Analysis Failed",
              message: "Failed to parse JSON response for image: #{analysis.image}",
              category: "ai_analysis"
            )
          end
        else
          analysis.mark_as_failed!("Failed to parse JSON response: #{e.message}")
          
          NotificationService.error(
            shop: analysis.shop,
            title: "Image Analysis Failed",
            message: "Failed to parse JSON response for image: #{analysis.image}",
            category: "ai_analysis"
          )
        end
      end
    rescue => e
      # Handle any other errors
      analysis.mark_as_failed!("Error analyzing image: #{e.message}")
      
      NotificationService.error(
        shop: analysis.shop,
        title: "Image Analysis Failed",
        message: "Error analyzing image: #{analysis.image} - #{e.message}",
        category: "ai_analysis"
      )
      
      # Re-raise the error for job retry mechanisms
      raise
    end
  end
end
