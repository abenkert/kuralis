require 'set'

class EbayCategory < ApplicationRecord
  # Validations
  validates :category_id, presence: true
  validates :name, presence: true
  validates :level, presence: true, numericality: { only_integer: true, greater_than: 0 }
  validates :marketplace_id, presence: true
  validates :category_id, uniqueness: { scope: :marketplace_id }
  
  # Scopes
  scope :roots, -> { where("parent_id IS NULL OR category_id = parent_id") }
  scope :leaves, -> { where(leaf: true) }
  scope :for_marketplace, ->(marketplace_id) { where(marketplace_id: marketplace_id) }
  scope :search_by_name, ->(query) { where("name ILIKE ?", "%#{query}%") }
  scope :with_embedding, -> { where.not(embedding_json: nil) }
  
  # Add embedding-related methods
  def has_embedding?
    embedding_json.present?
  end
  
  # Generate embedding for this category
  def generate_embedding!
    Ai::EbayCategoryEmbeddingService.generate_embedding_for_category(self)
  end
  
  # Tree structure methods
  def parent
    return nil if parent_id.nil?
    EbayCategory.find_by(category_id: parent_id, marketplace_id: marketplace_id)
  end
  
  def children
    EbayCategory.where(parent_id: category_id, marketplace_id: marketplace_id)
  end
  
  def ancestors
    return [] if parent_id.nil?
    
    # Handle root categories (where category_id = parent_id) to avoid infinite loops
    return [] if category_id == parent_id
    
    ancestors = []
    current = self
    visited = Set.new([category_id]) # Track visited categories to prevent loops
    
    while (parent = current.parent)
      # Prevent infinite loops
      break if visited.include?(parent.category_id) 
      visited.add(parent.category_id)
      
      ancestors.unshift(parent)
      current = parent
      
      # Also break if we encounter a root category
      break if parent.category_id == parent.parent_id
    end
    
    ancestors
  end
  
  def full_path
    (ancestors + [self]).map(&:name).join(" > ")
  end
  
  # Class methods for importing categories
  def self.import_from_ebay_api(marketplace_id = 'EBAY_US')
    # This would be implemented to fetch categories from eBay API
    # and store them in the database
    # Implementation depends on your eBay API client
  end
  
  def self.search_with_path(query, marketplace_id = 'EBAY_US')
    categories = search_by_name(query).for_marketplace(marketplace_id).to_a
    
    # Add full path information for display
    categories.map do |category|
      {
        id: category.id,
        category_id: category.category_id,
        name: category.name,
        full_path: category.full_path,
        leaf: category.leaf
      }
    end
  end
end
