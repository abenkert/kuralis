require 'openai'

module Ai
  class OpenaiService
    attr_reader :client
    
    DEFAULT_MODEL = "gpt-4o"
    DEFAULT_TEMPERATURE = 0.7
    DEFAULT_MAX_TOKENS = 1000
    
    def initialize(model: DEFAULT_MODEL, temperature: DEFAULT_TEMPERATURE, max_tokens: DEFAULT_MAX_TOKENS)
      @client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
      @model = model
      @temperature = temperature
      @max_tokens = max_tokens
    end
    
    # Send a simple chat request with a single user message
    def chat(message, system_prompt: nil)
      messages = []
      
      # Add system message if provided
      if system_prompt.present?
        messages << { role: "system", content: system_prompt }
      end
      
      # Add user message
      messages << { role: "user", content: message }
      
      # Send request to OpenAI
      response = client.chat(
        parameters: {
          model: @model,
          messages: messages,
          temperature: @temperature,
          max_tokens: @max_tokens
        }
      )
      
      # Extract and return the assistant's response
      if response["choices"] && response["choices"].first && response["choices"].first["message"]
        return response["choices"].first["message"]["content"]
      else
        Rails.logger.error "OpenAI API Error: #{response.inspect}"
        raise "Failed to get response from OpenAI"
      end
    end
    
    # Send a chat request with a conversation history
    def chat_with_history(messages)
      # Validate messages format
      unless messages.is_a?(Array) && messages.all? { |m| m.key?(:role) && m.key?(:content) }
        raise ArgumentError, "Messages must be an array of hashes with :role and :content keys"
      end
      
      # Send request to OpenAI
      response = client.chat(
        parameters: {
          model: @model,
          messages: messages,
          temperature: @temperature,
          max_tokens: @max_tokens
        }
      )
      
      # Extract and return the assistant's response
      if response["choices"] && response["choices"].first && response["choices"].first["message"]
        return {
          content: response["choices"].first["message"]["content"],
          usage: response["usage"],
          full_response: response
        }
      else
        Rails.logger.error "OpenAI API Error: #{response.inspect}"
        raise "Failed to get response from OpenAI"
      end
    end
    
    # Generate a product description based on product details
    def generate_product_description(product_details)
      system_prompt = "You are a professional e-commerce product description writer. Create compelling, accurate, and SEO-friendly product descriptions."
      
      user_prompt = <<~PROMPT
        Please write a product description for the following product:
        
        Title: #{product_details[:title]}
        Brand: #{product_details[:brand]}
        Condition: #{product_details[:condition]}
        Category: #{product_details[:category]}
        Features: #{product_details[:features]}
        
        The description should be engaging, highlight key features, and be optimized for e-commerce platforms.
      PROMPT
      
      chat(user_prompt, system_prompt: system_prompt)
    end
    
    # Suggest eBay categories based on product details
    def suggest_ebay_categories(product_details)
      system_prompt = "You are an eBay category expert. Suggest the most appropriate eBay categories for products."
      
      user_prompt = <<~PROMPT
        Please suggest the most appropriate eBay category for the following product:
        
        Title: #{product_details[:title]}
        Brand: #{product_details[:brand]}
        Description: #{product_details[:description]}
        
        Return your answer in the following format:
        Primary Category: [Category Name]
        Alternative Categories: [Category 1], [Category 2], [Category 3]
      PROMPT
      
      chat(user_prompt, system_prompt: system_prompt)
    end
    
    # Extract product attributes from unstructured text
    def extract_product_attributes(text)
      system_prompt = "You are a data extraction expert. Extract structured product information from unstructured text."
      
      user_prompt = <<~PROMPT
        Extract the following attributes from this product text if present:
        - Brand
        - Model
        - Color
        - Size
        - Material
        - Condition
        - Features
        
        Text: #{text}
        
        Return the results in JSON format.
      PROMPT
      
      response = chat(user_prompt, system_prompt: system_prompt)
      
      # Parse JSON response
      begin
        JSON.parse(response)
      rescue JSON::ParserError
        Rails.logger.error "Failed to parse JSON from OpenAI response: #{response}"
        { error: "Failed to parse attributes", raw_response: response }
      end
    end
  end
end 