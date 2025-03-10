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
  end
end 