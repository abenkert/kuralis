# app/services/ai/item_specifics_mapper.rb
module Ai
    class ItemSpecificsMapper
      # Maps AI-detected item specifics to eBay category-specific item specifics
      # 
      # @param ai_item_specifics [Hash] Item specifics detected by AI
      # @param ebay_aspect_metadata [Array] Aspect metadata from eBay taxonomy API
      # @return [Hash] Mapped item specifics in the format eBay expects
      def self.map_to_ebay_format(ai_item_specifics, ebay_aspect_metadata)
        mapped_specifics = {}
        
        # Initialize required fields with empty values
        ebay_aspect_metadata.each do |aspect|
          if aspect["required"]
            mapped_specifics[aspect["name"]] = ""
          end
        end
        
        # Try to map AI attributes to eBay aspects
        ai_item_specifics.each do |ai_key, ai_value|
          next if ai_value.blank?
          
          # Try exact match first
          exact_match = find_exact_match(ai_key, ebay_aspect_metadata)
          if exact_match
            mapped_specifics[exact_match["name"]] = format_value(ai_value, exact_match)
            next
          end
          
          # Try fuzzy match if no exact match found
          fuzzy_match = find_fuzzy_match(ai_key, ai_value, ebay_aspect_metadata)
          if fuzzy_match
            mapped_specifics[fuzzy_match["name"]] = format_value(ai_value, fuzzy_match)
          end
        end
        
        mapped_specifics
      end
      
      private
      
      def self.find_exact_match(ai_key, ebay_aspects)
        ebay_aspects.find { |aspect| aspect["name"].downcase == ai_key.downcase }
      end
      
      def self.find_fuzzy_match(ai_key, ai_value, ebay_aspects)
        # Try different matching strategies
        
        # 1. Check if AI key is contained in or contains eBay aspect name
        ebay_aspects.each do |aspect|
          return aspect if aspect["name"].downcase.include?(ai_key.downcase) || 
                             ai_key.downcase.include?(aspect["name"].downcase)
        end
        
        # 2. Check for word-level matches
        ai_words = ai_key.downcase.split(/\W+/)
        
        ebay_aspects.each do |aspect|
          aspect_words = aspect["name"].downcase.split(/\W+/)
          common_words = ai_words & aspect_words
          
          # If at least half of the words match (of whichever is shorter)
          if common_words.any? && common_words.length >= [ai_words.length, aspect_words.length].min * 0.5
            return aspect
          end
        end
        
        # 3. Check if AI value matches any recommended values
        ebay_aspects.each do |aspect|
          next unless aspect["values"].present?
          
          aspect["values"].each do |value|
            if value.downcase.include?(ai_value.to_s.downcase) || 
               ai_value.to_s.downcase.include?(value.downcase)
              return aspect
            end
          end
        end
        
        nil
      end
      
      def self.format_value(ai_value, aspect)
        # Format the value based on aspect constraints and value_type
        if aspect["values"].present?
          value_type = aspect["value_type"]
          
          # For "select" type fields, we must use one of the provided values
          if value_type == "select"
            best_match = find_best_matching_value(ai_value.to_s, aspect["values"])
            return best_match || "" # Return empty string if no match found for required select fields
          
          # For "text_with_suggestions" type fields, try to match but allow custom values
          elsif value_type == "text_with_suggestions"
            # Try to find a matching suggested value first
            best_match = find_best_matching_value(ai_value.to_s, aspect["values"])
            return best_match if best_match
          end
          
          # For other field types or if no match in text_with_suggestions
          # Try the previous simple matching logic for backward compatibility
          aspect["values"].each do |value|
            return value if value.downcase.include?(ai_value.to_s.downcase) || 
                           ai_value.to_s.downcase.include?(value.downcase)
          end
        end
        
        # If no matching recommended value or for free text fields, return original with basic formatting
        ai_value.to_s.strip
      end
      
      # Find the best matching value from a list of allowed values
      # Returns nil if no good match is found
      def self.find_best_matching_value(ai_value, allowed_values)
        ai_value = ai_value.to_s.strip.downcase
        
        # 1. Try exact match (case insensitive)
        exact_match = allowed_values.find { |v| v.downcase == ai_value }
        return exact_match if exact_match
        
        # 2. Try numeric match for years and other numeric values
        if ai_value =~ /^\d+$/
          # If AI value is a number, try to find closest match
          numeric_ai_value = ai_value.to_i
          numeric_values = allowed_values.select { |v| v =~ /^\d+$/ }.map { |v| v.to_i }
          
          if numeric_values.any?
            # Find exact numeric match
            exact_numeric_match = allowed_values.find { |v| v.to_i == numeric_ai_value }
            return exact_numeric_match if exact_numeric_match
            
            # Find closest year (for publication years, etc.)
            closest_value = numeric_values.min_by { |v| (v - numeric_ai_value).abs }
            closest_value_diff = (closest_value - numeric_ai_value).abs
            
            # If within reasonable range (e.g., 5 years), use it
            if closest_value_diff <= 5
              return allowed_values.find { |v| v.to_i == closest_value }
            end
          end
        end
        
        # 3. Try contained match (one contains the other)
        contained_match = allowed_values.find do |v| 
          v.downcase.include?(ai_value) || ai_value.include?(v.downcase)
        end
        return contained_match if contained_match
        
        # 4. Try word similarity
        ai_words = ai_value.split(/\W+/)
        
        best_match = nil
        highest_similarity = 0
        
        allowed_values.each do |value|
          value_words = value.downcase.split(/\W+/)
          common_words = ai_words & value_words
          
          # Calculate similarity as percentage of matching words
          similarity = common_words.length.to_f / [ai_words.length, value_words.length].max
          
          if similarity > highest_similarity && similarity >= 0.3 # At least 30% similar
            highest_similarity = similarity
            best_match = value
          end
        end
        
        best_match
      end
    end
  end