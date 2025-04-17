module Ai
  class EbayCategoryEmbeddingService
    # Using JSON storage for embeddings since pgvector is not available
    
    # Generate embeddings for all eBay categories
    def self.generate_embeddings_for_all_categories
      # Process in batches to avoid memory issues
      EbayCategory.find_each(batch_size: 100) do |category|
        generate_embedding_for_category(category)
      end
    end

    # Generate embedding for a single category
    def self.generate_embedding_for_category(category)
      # Skip if already has embedding and hasn't changed
      return if category.embedding_json.present? && !category.updated_at_changed?

      # Get embedding from OpenAI
      embedding = get_embedding_for_text("#{category.name}: #{category.full_path}")
      
      # Save the embedding to JSON column
      category.update(embedding_json: embedding)
    rescue => e
      Rails.logger.error "Error generating embedding for category #{category.id}: #{e.message}"
    end

    # Find semantically similar categories to the given text
    def self.find_similar_categories(text, limit: 10)
      # Get embedding for the search text
      query_embedding = get_embedding_for_text(text)
      
      # Using manual cosine similarity calculation
      categories_with_embeddings = EbayCategory.where.not(embedding_json: nil).to_a
      
      # Calculate similarity scores
      categories_with_scores = categories_with_embeddings.map do |category|
        category_embedding = category.embedding_json
        score = calculate_cosine_similarity(query_embedding, category_embedding)
        [category, score]
      end
      
      # Sort by similarity score (descending) and take the top N
      categories_with_scores.sort_by { |_, score| -score }.take(limit).map(&:first)
    rescue => e
      Rails.logger.error "Error finding similar categories: #{e.message}"
      # Fallback to keyword search
      EbayCategory.search_by_name(text).limit(limit)
    end
    
    # Find the most semantically similar category to the given text
    def self.find_most_similar_category(text)
      find_similar_categories(text, limit: 1).first
    rescue => e
      Rails.logger.error "Error finding most similar category: #{e.message}"
      nil
    end

    private

    # Get embedding from OpenAI for the given text
    def self.get_embedding_for_text(text)
      # Initialize OpenAI client
      client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
      
      # Call embedding API
      response = client.embeddings(
        parameters: {
          model: "text-embedding-ada-002",
          input: text
        }
      )
      
      # Extract the embedding vector
      response.dig("data", 0, "embedding")
    end
    
    # Calculate cosine similarity between two embedding vectors
    def self.calculate_cosine_similarity(vec1, vec2)
      # Ensure we have arrays
      return 0 unless vec1.is_a?(Array) && vec2.is_a?(Array)
      return 0 unless vec1.length == vec2.length
      
      # Calculate dot product
      dot_product = 0
      vec1.each_with_index do |v1, i|
        dot_product += v1 * vec2[i]
      end
      
      # Calculate magnitudes
      mag1 = Math.sqrt(vec1.map { |v| v * v }.sum)
      mag2 = Math.sqrt(vec2.map { |v| v * v }.sum)
      
      # Calculate cosine similarity
      dot_product / (mag1 * mag2)
    end
  end
end 