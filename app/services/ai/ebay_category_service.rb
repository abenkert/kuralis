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

      # Check cache first for performance
      cache_key = "ebay_category_match:#{Digest::MD5.hexdigest(category_path_or_description.downcase)}"
      cached_result = Rails.cache.read(cache_key)
      if cached_result
        Rails.logger.info "Found cached category match: #{cached_result['name']} (#{cached_result['category_id']})"
        return EbayCategory.find_by(category_id: cached_result["category_id"], marketplace_id: "EBAY_US")
      end

      Rails.logger.info "Finding matching eBay category for: #{category_path_or_description}"

      # Strategy 1: Exact path matching (highest priority)
      match = find_by_exact_path(category_path_or_description)
      if match
        Rails.logger.info "Found exact path match: #{match.name} (#{match.category_id})"
        cache_category_match(cache_key, match)
        return match
      end

      # Strategy 2: Semantic search using embeddings (if available)
      if embeddings_available? && EbayCategory.where.not(embedding_json: nil).exists?
        match = Ai::EbayCategoryEmbeddingService.find_most_similar_category(category_path_or_description)
        if match && match.leaf? # Only accept leaf categories from semantic search
          Rails.logger.info "Found match by semantic similarity: #{match.name} (#{match.category_id})"
          cache_category_match(cache_key, match)
          return match
        end
      end

      # Strategy 3: Intelligent leaf name matching with context
      match = find_by_leaf_name_with_context(category_path_or_description)
      if match
        Rails.logger.info "Found match by leaf name with context: #{match.name} (#{match.category_id})"
        cache_category_match(cache_key, match)
        return match
      end

      # Strategy 4: Broader category matching (fallback to parent categories)
      match = find_broader_category_match(category_path_or_description)
      if match
        Rails.logger.info "Found broader category match: #{match.name} (#{match.category_id})"
        cache_category_match(cache_key, match)
        return match
      end

      Rails.logger.warn "No matching category found for: #{category_path_or_description}"
      # Cache negative results too (for 5 minutes)
      Rails.cache.write(cache_key, nil, expires_in: 5.minutes)
      nil
    end

    # Cache successful category matches
    def self.cache_category_match(cache_key, category)
      Rails.cache.write(cache_key, {
        "category_id" => category.category_id,
        "name" => category.name,
        "full_path" => category.full_path
      }, expires_in: 1.hour)
    end

    # Find exact path matches
    def self.find_by_exact_path(path)
      normalized_path = normalize_text_for_matching(path)

      # Try to find categories where the full path matches exactly
      EbayCategory.where(leaf: true).find do |category|
        category_path = normalize_text_for_matching(category.full_path)
        category_path == normalized_path
      end
    end

    # Enhanced leaf name matching with better context awareness
    def self.find_by_leaf_name_with_context(path)
      segments = path.split(/\s*[>\/]\s*/)
      return nil if segments.empty?

      leaf_name = segments.last.strip
      parent_context = segments.size > 1 ? segments[-2..-1] : []

      # Normalize for matching
      normalized_leaf = normalize_text_for_matching(leaf_name)

      # Get potential matches
      potential_matches = EbayCategory.where("LOWER(REPLACE(REPLACE(name, '''', ''), '&', 'and')) LIKE LOWER(REPLACE(REPLACE(?, '''', ''), '&', 'and'))", "%#{leaf_name}%")
                                     .where(leaf: true)
                                     .to_a

      # Score matches based on context
      scored_matches = potential_matches.map do |category|
        score = calculate_context_score(category, segments)
        [ category, score ]
      end

      # Return the highest scoring match if it's above threshold
      best_match = scored_matches.max_by { |_, score| score }
      return best_match[0] if best_match && best_match[1] > 0.3

      nil
    end

    # Find broader category matches when specific ones fail
    def self.find_broader_category_match(path)
      segments = path.split(/\s*[>\/]\s*/)
      return nil if segments.size < 2

      # Try matching against broader categories (parents)
      (segments.size - 1).downto(1) do |i|
        broader_path = segments[0..i].join(" > ")

        # Look for categories that contain these broader terms
        segments[0..i].each do |segment|
          normalized_segment = normalize_text_for_matching(segment)
          next if normalized_segment.length < 4 # Skip very short terms

          category = EbayCategory.where("LOWER(REPLACE(REPLACE(name, '''', ''), '&', 'and')) LIKE LOWER(REPLACE(REPLACE(?, '''', ''), '&', 'and'))", "%#{segment}%")
                                .where(leaf: true)
                                .first
          return category if category
        end
      end

      nil
    end

    # Calculate context score for category matching
    def self.calculate_context_score(category, path_segments)
      return 0 unless category.full_path.present?

      category_segments = category.full_path.split(/\s*>\s*/).map { |s| normalize_text_for_matching(s) }
      path_segments_normalized = path_segments.map { |s| normalize_text_for_matching(s) }

      # Count matching segments
      matching_segments = 0
      path_segments_normalized.each do |path_segment|
        if category_segments.any? { |cat_segment| cat_segment.include?(path_segment) || path_segment.include?(cat_segment) }
          matching_segments += 1
        end
      end

      # Calculate score (percentage of path segments that match)
      matching_segments.to_f / path_segments.size
    end

    # Fast method to find by leaf name (legacy - keeping for backward compatibility)
    def self.find_by_leaf_name(path)
      find_by_leaf_name_with_context(path)
    end

    # Legacy method for backward compatibility
    def self.find_best_matching_category(category_path_or_description)
      find_matching_ebay_category(category_path_or_description)
    end

    # Normalize text for better matching
    def self.normalize_text_for_matching(text)
      return "" if text.blank?

      # Remove apostrophes, standardize ampersands, lowercase
      normalized = text.downcase
                      .gsub(/['']/, "")   # Remove apostrophes
                      .gsub(/&/, "and")    # Convert & to 'and'
                      .gsub(/\bwomens\b/, "women")  # Normalize womens to women
                      .gsub(/\bmens\b/, "men")      # Normalize mens to men
                      .gsub(/[-_]/, " ")   # Convert hyphens and underscores to spaces
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
      stopwords = %w[the and a an of to in for on with by at from]
      keywords = words.reject { |word| word.length < 4 || stopwords.include?(word.downcase) }

      # Join the top keywords for the search
      keywords.first(5).join(" ")
    end
  end
end
