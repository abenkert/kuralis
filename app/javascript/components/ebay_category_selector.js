// eBay Category Selector Component
// This component creates a searchable dropdown for eBay categories

class EbayCategorySelector {
  constructor(element, options = {}) {
    this.element = element;
    this.options = {
      placeholder: 'Search for eBay category...',
      minLength: 2,
      delay: 300,
      marketplaceId: 'EBAY_US',
      ...options
    };
    
    this.searchUrl = '/kuralis/ebay_categories/search';
    this.selectedCategory = null;
    
    this.init();
  }
  
  init() {
    // Create the UI elements
    this.createElements();
    
    // Set up event listeners
    this.setupEventListeners();
    
    // Initialize with any existing value
    this.initializeWithExistingValue();
  }
  
  createElements() {
    // Create container
    this.container = document.createElement('div');
    this.container.className = 'ebay-category-selector position-relative';
    
    // Create search input
    this.searchInput = document.createElement('input');
    this.searchInput.type = 'text';
    this.searchInput.className = 'form-control';
    this.searchInput.placeholder = this.options.placeholder;
    this.searchInput.autocomplete = 'off';
    
    // Create dropdown results container
    this.resultsContainer = document.createElement('div');
    this.resultsContainer.className = 'dropdown-menu w-100';
    
    // Create hidden input for form submission
    this.hiddenInput = document.createElement('input');
    this.hiddenInput.type = 'hidden';
    this.hiddenInput.name = this.element.name;
    this.hiddenInput.id = this.element.id;
    
    // Create selected category display
    this.selectedDisplay = document.createElement('div');
    this.selectedDisplay.className = 'selected-category mt-2 d-none';
    
    // Append elements
    this.container.appendChild(this.searchInput);
    this.container.appendChild(this.resultsContainer);
    this.container.appendChild(this.hiddenInput);
    this.container.appendChild(this.selectedDisplay);
    
    // Replace the original element with our custom component
    this.element.parentNode.replaceChild(this.container, this.element);
  }
  
  setupEventListeners() {
    // Search input event
    let debounceTimeout;
    this.searchInput.addEventListener('input', () => {
      clearTimeout(debounceTimeout);
      
      const query = this.searchInput.value.trim();
      if (query.length < this.options.minLength) {
        this.hideResults();
        return;
      }
      
      debounceTimeout = setTimeout(() => {
        this.performSearch(query);
      }, this.options.delay);
    });
    
    // Handle clicks outside to close dropdown
    document.addEventListener('click', (e) => {
      if (!this.container.contains(e.target)) {
        this.hideResults();
      }
    });
    
    // Prevent form submission on enter in search field
    this.searchInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        return false;
      }
    });
  }
  
  initializeWithExistingValue() {
    const categoryId = this.hiddenInput.value;
    if (categoryId) {
      // Fetch category details and display them
      fetch(`/kuralis/ebay_categories/${categoryId}.json`)
        .then(response => response.json())
        .then(category => {
          this.selectCategory(category);
        })
        .catch(error => console.error('Error fetching category:', error));
    }
  }
  
  performSearch(query) {
    const url = new URL(this.searchUrl, window.location.origin);
    url.searchParams.append('q', query);
    url.searchParams.append('marketplace_id', this.options.marketplaceId);
    
    fetch(url, {
      headers: {
        'Accept': 'application/json'
      }
    })
      .then(response => response.json())
      .then(data => {
        this.displayResults(data);
      })
      .catch(error => {
        console.error('Error searching categories:', error);
      });
  }
  
  displayResults(categories) {
    // Clear previous results
    this.resultsContainer.innerHTML = '';
    
    if (categories.length === 0) {
      const noResults = document.createElement('div');
      noResults.className = 'dropdown-item text-muted';
      noResults.textContent = 'No categories found';
      this.resultsContainer.appendChild(noResults);
    } else {
      categories.forEach(category => {
        const item = document.createElement('a');
        item.className = 'dropdown-item';
        item.href = '#';
        
        // Create category name with full path
        const nameSpan = document.createElement('div');
        nameSpan.className = 'category-name';
        nameSpan.textContent = category.name;
        
        const pathSpan = document.createElement('div');
        pathSpan.className = 'category-path small text-muted';
        pathSpan.textContent = category.full_path;
        
        item.appendChild(nameSpan);
        item.appendChild(pathSpan);
        
        // Add leaf indicator if it's a leaf category
        if (category.leaf) {
          const leafBadge = document.createElement('span');
          leafBadge.className = 'badge bg-success float-end';
          leafBadge.textContent = 'Leaf';
          item.appendChild(leafBadge);
        }
        
        // Add click handler
        item.addEventListener('click', (e) => {
          e.preventDefault();
          this.selectCategory(category);
          this.hideResults();
        });
        
        this.resultsContainer.appendChild(item);
      });
    }
    
    // Show results
    this.resultsContainer.classList.add('show');
  }
  
  selectCategory(category) {
    this.selectedCategory = category;
    this.hiddenInput.value = category.category_id;
    
    // Update the selected display
    this.selectedDisplay.innerHTML = '';
    this.selectedDisplay.classList.remove('d-none');
    
    const categoryInfo = document.createElement('div');
    categoryInfo.className = 'selected-category-info p-2 border rounded';
    
    const categoryName = document.createElement('div');
    categoryName.className = 'fw-bold';
    categoryName.textContent = category.name;
    
    const categoryPath = document.createElement('div');
    categoryPath.className = 'small text-muted';
    categoryPath.textContent = category.full_path;
    
    const categoryId = document.createElement('div');
    categoryId.className = 'small';
    categoryId.textContent = `Category ID: ${category.category_id}`;
    
    const removeButton = document.createElement('button');
    removeButton.type = 'button';
    removeButton.className = 'btn btn-sm btn-outline-danger mt-1';
    removeButton.textContent = 'Remove';
    removeButton.addEventListener('click', () => {
      this.clearSelection();
    });
    
    categoryInfo.appendChild(categoryName);
    categoryInfo.appendChild(categoryPath);
    categoryInfo.appendChild(categoryId);
    categoryInfo.appendChild(removeButton);
    
    this.selectedDisplay.appendChild(categoryInfo);
    
    // Clear the search input
    this.searchInput.value = '';
    
    // Trigger change event on hidden input
    const event = new Event('change', { bubbles: true });
    this.hiddenInput.dispatchEvent(event);
  }
  
  clearSelection() {
    this.selectedCategory = null;
    this.hiddenInput.value = '';
    this.selectedDisplay.innerHTML = '';
    this.selectedDisplay.classList.add('d-none');
    
    // Trigger change event on hidden input
    const event = new Event('change', { bubbles: true });
    this.hiddenInput.dispatchEvent(event);
  }
  
  hideResults() {
    this.resultsContainer.classList.remove('show');
  }
}

// Initialize all eBay category selectors on the page
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('[data-ebay-category-selector]').forEach(element => {
    const options = JSON.parse(element.getAttribute('data-options') || '{}');
    new EbayCategorySelector(element, options);
  });
});

export default EbayCategorySelector; 