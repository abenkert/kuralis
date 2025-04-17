module Ai
  class EbayCategoryService
    # Maximum number of categories to include in context
    DEFAULT_CATEGORY_LIMIT = 5
    
    # Retrieve top eBay categories for AI context
    # This provides a curated list of categories to include in the OpenAI prompt
    def self.get_categories_for_ai_context(limit: DEFAULT_CATEGORY_LIMIT, query: nil)
      categories = if query.present?
        # If embeddings are available, try semantic search first
        if embeddings_available? && EbayCategory.where.not(embedding_json: nil).exists?
          # Use semantic search
          Ai::EbayCategoryEmbeddingService.find_similar_categories(query, limit: limit)
        else
          # Fall back to text search
          EbayCategory.search_by_name(query).limit(limit)
        end
      else
        # Otherwise, get popular leaf categories
        EbayCategory.leaves.order(id: :desc).limit(limit)
      end
      
      # Format the categories for inclusion in the prompt
      format_categories_for_prompt(categories)
    end
    
    # Format categories in a structured way for the AI prompt
    def self.format_categories_for_prompt(categories)
      categories.map do |category|
        {
          "category_id" => category.category_id,
          "name" => category.name,
          "full_path" => category.full_path,
          "is_leaf" => category.leaf
        }
      end
    end
    
    # Optimized method to find the best matching eBay category using multiple strategies
    def self.find_matching_ebay_category(category_path_or_description)
      return nil if category_path_or_description.blank?
      
      Rails.logger.info "Finding matching eBay category for: #{category_path_or_description}"
      
      # Optimized approach - focus primarily on the leaf (most specific) category
      # Strategy 1: Direct leaf name matching (fast)
      match = find_by_leaf_name(category_path_or_description)
      if match
        Rails.logger.info "Found match by leaf name: #{match.name} (#{match.category_id})"
        return match
      end
      
      # Strategy 2: Only if needed, try a semantic search
      if embeddings_available? && EbayCategory.where.not(embedding_json: nil).exists?
        match = Ai::EbayCategoryEmbeddingService.find_most_similar_category(category_path_or_description)
        if match
          Rails.logger.info "Found match by semantic similarity: #{match.name} (#{match.category_id})"
          return match
        end
      end
      
      Rails.logger.info "No matching category found for: #{category_path_or_description}"
      nil
    end
    
    # Legacy method for backward compatibility
    def self.find_best_matching_category(category_path_or_description)
      find_matching_ebay_category(category_path_or_description)
    end
    
    # Fast method to find by leaf name
    def self.find_by_leaf_name(path)
      # Extract the leaf name (last segment of the path)
      segments = path.split(/\s*[>\/]\s*/)
      leaf_name = segments.last.strip
      
      # Normalize the leaf name for better matching
      normalized_leaf = normalize_text_for_matching(leaf_name)
      
      # Check parent context from path to help with ambiguous categories
      parent_context = segments.size > 1 ? segments[-2].strip : nil
      
      # Try 1: Exact match on normalized name at leaf level with parent context
      if parent_context
        # If we have parent context, prioritize matches with the right parent
        categories = EbayCategory.where("LOWER(name) = LOWER(?)", leaf_name)
                               .where(leaf: true)
                               .to_a
                               
        categories.each do |category|
          if category.parent && normalize_text_for_matching(category.parent.name) == normalize_text_for_matching(parent_context)
            return category
          end
        end
      end
      
      # Try 2: Exact match on normalized name at leaf level
      category = EbayCategory.where("LOWER(REPLACE(REPLACE(name, '''', ''), '&', 'and')) = LOWER(REPLACE(REPLACE(?, '''', ''), '&', 'and'))", leaf_name)
                            .where(leaf: true)
                            .first
      return category if category
      
      # Try 3: Exact match on any level (not just leaves)
      category = EbayCategory.where("LOWER(REPLACE(REPLACE(name, '''', ''), '&', 'and')) = LOWER(REPLACE(REPLACE(?, '''', ''), '&', 'and'))", leaf_name)
                            .first
      return category if category
      
      # Try 4: Partial match on normalized leaf name
      category = EbayCategory.where("LOWER(REPLACE(REPLACE(name, '''', ''), '&', 'and')) LIKE LOWER(REPLACE(REPLACE(?, '''', ''), '&', 'and'))", "%#{leaf_name}%")
                            .where(leaf: true)
                            .first
      return category if category
      
      # Try 5: Full path context matching
      if segments.size > 1
        # Create a simplified version of the path for matching
        simple_path = segments.map { |s| normalize_text_for_matching(s) }.join(" ")
        
        # Get all leaf categories and check if their path contains elements from our path
        leaf_categories = EbayCategory.where(leaf: true).to_a
        leaf_categories.each do |category|
          if category.full_path.present?
            normalized_category_path = normalize_text_for_matching(category.full_path)
            # Count how many segments match
            matching_terms = simple_path.split(/\s+/).select { |term| normalized_category_path.include?(term) }.count
            if matching_terms >= [segments.size, 2].min # At least 2 terms or all if less than 2
              return category
            end
          end
        end
      end
      
      # Try 6: Keyword matching as last resort
      keywords = leaf_name.split(/\s+/).select { |word| word.length > 3 }
      keywords.each do |keyword|
        normalized_keyword = normalize_text_for_matching(keyword)
        category = EbayCategory.where("LOWER(REPLACE(REPLACE(name, '''', ''), '&', 'and')) LIKE LOWER(REPLACE(REPLACE(?, '''', ''), '&', 'and'))", "%#{keyword}%")
                              .where(leaf: true)
                              .first
        return category if category
      end
      
      nil
    end
    
    # Normalize text for better matching
    def self.normalize_text_for_matching(text)
      return "" if text.blank?
      
      # Remove apostrophes, standardize ampersands, lowercase
      normalized = text.downcase
                      .gsub(/['']/, '')   # Remove apostrophes
                      .gsub(/&/, 'and')    # Convert & to 'and'
                      .gsub(/\bwomens\b/, 'women')  # Normalize womens to women
                      .gsub(/\bmens\b/, 'men')      # Normalize mens to men
                      .gsub(/[-_]/, ' ')   # Convert hyphens and underscores to spaces
                      .strip
      
      normalized
    end
    
    # Generate a system prompt for eBay category awareness
    def self.generate_ebay_category_prompt
      <<~PROMPT
        You are a product analysis expert for eBay. Provide accurate eBay category paths for products.

        Use standard eBay category paths with the full hierarchy, separated by " > " between levels.
        Be specific and accurate. Use only real eBay categories.
        
        Important format notes:
        - Use apostrophes for possessives (e.g., "Women's Bags" not "Womens Bags")
        - Include "accessories" when appropriate
        - Use "&" for "and" in category names
      PROMPT
    end
    
    private
    
    # Check if embeddings functionality is available
    def self.embeddings_available?
      defined?(Ai::EbayCategoryEmbeddingService) && 
      Ai::EbayCategoryEmbeddingService.respond_to?(:find_similar_categories)
    end
    
    # Format the categories as plain text for inclusion in the prompt
    def self.format_categories_as_text(categories)
      categories.map do |category|
        "- #{category['name']} (#{category['full_path']}) - ID: #{category['category_id']}"
      end.join("\n")
    end
    
    # Extract potential keywords from a product title
    def self.extract_keywords_from_title(title)
      return "" if title.blank?
      
      # Extract nouns and meaningful terms - basic implementation
      # In a production environment, consider using NLP for better extraction
      words = title.split(/\s+/).uniq
      
      # Filter out common stopwords and short words
      stopwords = %w(the and a an of to in for on with by at from)
      keywords = words.reject { |word| word.length < 4 || stopwords.include?(word.downcase) }
      
      # Join the top keywords for the search
      keywords.first(5).join(" ")
    end
  end
end 