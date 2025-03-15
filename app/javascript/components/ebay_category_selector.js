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
    
    // Copy the original element's value to the hidden input
    this.hiddenInput.value = this.element.value || '';
    
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
    
    // Fetch item specifics for this category
    this.fetchItemSpecifics(category.category_id);
    
    // Trigger change event on hidden input
    const event = new Event('change', { bubbles: true });
    this.hiddenInput.dispatchEvent(event);
  }
  
  clearSelection() {
    this.selectedCategory = null;
    this.hiddenInput.value = '';
    this.selectedDisplay.innerHTML = '';
    this.selectedDisplay.classList.add('d-none');
    
    // Clear item specifics
    this.clearItemSpecifics();
    
    // Trigger change event on hidden input
    const event = new Event('change', { bubbles: true });
    this.hiddenInput.dispatchEvent(event);
  }
  
  hideResults() {
    this.resultsContainer.classList.remove('show');
  }
  
  // Add these new methods for item specifics
  fetchItemSpecifics(categoryId) {
    const url = `/kuralis/ebay_categories/${categoryId}/item_specifics.json`;
    
    // Show loading indicator
    this.showItemSpecificsLoading();
    
    fetch(url)
      .then(response => response.json())
      .then(itemSpecifics => {
        this.renderItemSpecificsForm(itemSpecifics);
      })
      .catch(error => {
        console.error('Error fetching item specifics:', error);
        this.showItemSpecificsError();
      });
  }
  
  showItemSpecificsLoading() {
    // Find or create the container for item specifics
    let container = this.getOrCreateItemSpecificsContainer();
    
    // Show loading indicator
    container.innerHTML = `
      <div class="text-center my-4">
        <div class="spinner-border text-primary" role="status">
          <span class="visually-hidden">Loading...</span>
        </div>
        <p class="mt-2 text-muted">Loading item specifics...</p>
      </div>
    `;
  }
  
  showItemSpecificsError() {
    let container = this.getOrCreateItemSpecificsContainer();
    
    container.innerHTML = `
      <div class="alert alert-warning my-3">
        <i class="fas fa-exclamation-triangle me-2"></i>
        Failed to load item specifics for this category. Please try again later.
      </div>
    `;
  }
  
  getOrCreateItemSpecificsContainer() {
    // Find or create the container for item specifics
    let container = document.getElementById('ebay-item-specifics-container');
    if (!container) {
      container = document.createElement('div');
      container.id = 'ebay-item-specifics-container';
      container.className = 'mt-4 pt-4 border-top';
      
      // Find a good place to insert it in the form
      const ebayTab = document.getElementById('ebay-info');
      if (ebayTab) {
        // Insert after the best offer switch
        const bestOfferRow = ebayTab.querySelector('.form-check-input[role="switch"]').closest('.row');
        if (bestOfferRow) {
          bestOfferRow.after(container);
        } else {
          ebayTab.appendChild(container);
        }
      }
    }
    
    return container;
  }
  
  clearItemSpecifics() {
    const container = document.getElementById('ebay-item-specifics-container');
    if (container) {
      container.innerHTML = '';
    }
  }
  
  renderItemSpecificsForm(itemSpecifics) {
    const container = this.getOrCreateItemSpecificsContainer();
    
    // Clear existing content
    container.innerHTML = '';
    
    if (!itemSpecifics || itemSpecifics.length === 0) {
      container.innerHTML = '<p class="text-muted">No item specifics available for this category.</p>';
      return;
    }
    
    // Add a heading
    const heading = document.createElement('h5');
    heading.className = 'mb-3';
    heading.textContent = 'Item Specifics';
    container.appendChild(heading);
    
    // Create a description
    const description = document.createElement('p');
    description.className = 'text-muted mb-4';
    description.textContent = 'These fields are specific to the selected eBay category and help buyers find your item.';
    container.appendChild(description);
    
    // Group required and optional specifics
    const requiredSpecifics = itemSpecifics.filter(spec => spec.required);
    const optionalSpecifics = itemSpecifics.filter(spec => !spec.required);
    
    // Create form fields for required item specifics
    if (requiredSpecifics.length > 0) {
      const requiredHeading = document.createElement('h6');
      requiredHeading.className = 'mb-3 text-danger';
      requiredHeading.innerHTML = '<i class="fas fa-asterisk me-1"></i> Required Fields';
      container.appendChild(requiredHeading);
      
      this.createSpecificFields(container, requiredSpecifics);
    }
    
    // Create form fields for optional item specifics
    if (optionalSpecifics.length > 0) {
      const optionalHeading = document.createElement('h6');
      optionalHeading.className = 'mb-3 mt-4';
      optionalHeading.innerHTML = '<i class="fas fa-plus-circle me-1"></i> Optional Fields';
      container.appendChild(optionalHeading);
      
      this.createSpecificFields(container, optionalSpecifics);
    }
    
    // After rendering is complete, try to populate with existing values
    this.populateExistingItemSpecifics();
  }
  
  createSpecificFields(container, specifics) {
    // Create a row for the fields
    const row = document.createElement('div');
    row.className = 'row g-3';
    container.appendChild(row);
    
    // Create form fields for each item specific
    specifics.forEach(specific => {
      const col = document.createElement('div');
      col.className = 'col-md-6 mb-3';
      
      const formGroup = document.createElement('div');
      formGroup.className = 'form-group';
      
      // Create label
      const label = document.createElement('label');
      label.className = 'form-label';
      label.textContent = specific.name;
      if (specific.required) {
        const requiredSpan = document.createElement('span');
        requiredSpan.className = 'text-danger ms-1';
        requiredSpan.textContent = '*';
        label.appendChild(requiredSpan);
      }
      
      // Create input based on value_type
      let input;
      if (specific.value_type === 'select' && specific.values && specific.values.length > 0) {
        input = document.createElement('select');
        input.className = 'form-select';
        
        // Add blank option
        const blankOption = document.createElement('option');
        blankOption.value = '';
        blankOption.textContent = `Select ${specific.name}`;
        input.appendChild(blankOption);
        
        // Add options
        specific.values.forEach(value => {
          const option = document.createElement('option');
          option.value = value;
          option.textContent = value;
          input.appendChild(option);
        });
      } else if (specific.value_type === 'text_with_suggestions' && specific.values && specific.values.length > 0) {
        // Create a datalist for suggestions
        const datalistId = `datalist-${specific.name.replace(/\s+/g, '-').toLowerCase()}`;
        
        input = document.createElement('input');
        input.type = 'text';
        input.className = 'form-control';
        input.placeholder = `Enter ${specific.name}`;
        input.setAttribute('list', datalistId);
        
        const datalist = document.createElement('datalist');
        datalist.id = datalistId;
        
        specific.values.forEach(value => {
          const option = document.createElement('option');
          option.value = value;
          datalist.appendChild(option);
        });
        
        formGroup.appendChild(datalist);
      } else {
        input = document.createElement('input');
        input.type = 'text';
        input.className = 'form-control';
        input.placeholder = `Enter ${specific.name}`;
      }
      
      // Set name and id for the input
      const fieldName = specific.name.replace(/\s+/g, '_').toLowerCase();
      input.name = `kuralis_product[ebay_product_attribute_attributes][item_specifics][${fieldName}]`;
      input.id = `kuralis_product_ebay_product_attribute_attributes_item_specifics_${fieldName}`;
      
      // Add required attribute if needed
      if (specific.required) {
        input.required = true;
      }
      
      // Assemble the form group
      formGroup.appendChild(label);
      formGroup.appendChild(input);
      
      // Add help text if available for text inputs with suggestions
      if (specific.value_type === 'text' && specific.values && specific.values.length > 0) {
        const helpText = document.createElement('small');
        helpText.className = 'form-text text-muted';
        helpText.textContent = `Suggested: ${specific.values.join(', ')}`;
        formGroup.appendChild(helpText);
      }
      
      col.appendChild(formGroup);
      row.appendChild(col);
    });
  }
  
  populateExistingItemSpecifics() {
    // Check if we have existing item specifics data in options
    if (!this.options.existingItemSpecifics) {
      console.log('No existing item specifics data found in options');
      return;
    }
    
    try {
      const itemSpecificsData = this.options.existingItemSpecifics;
      console.log('Found existing item specifics:', itemSpecificsData);
      
      // Iterate through the data and populate form fields
      Object.entries(itemSpecificsData).forEach(([key, value]) => {
        // Skip empty values
        if (!value) return;
        
        // Convert the key to the format used in field names
        const fieldName = key.replace(/\s+/g, '_').toLowerCase();
        const selector = `[name="kuralis_product[ebay_product_attribute_attributes][item_specifics][${fieldName}]"]`;
        
        const field = document.querySelector(selector);
        if (field) {
          console.log(`Populating field ${fieldName} with value: ${value}`);
          field.value = value;
        } else {
          // Try with original case
          const altSelector = `[name="kuralis_product[ebay_product_attribute_attributes][item_specifics][${key}]"]`;
          const altField = document.querySelector(altSelector);
          if (altField) {
            console.log(`Populating field ${key} with value: ${value}`);
            altField.value = value;
          } else {
            console.log(`Could not find field for item specific: ${key}`);
          }
        }
      });
    } catch (error) {
      console.error('Error processing item specifics data:', error);
    }
  }
}

// Initialize all eBay category selectors on the page
function initializeEbayCategorySelectors() {
  document.querySelectorAll('[data-ebay-category-selector]').forEach(element => {
    // Check if the element has already been initialized to prevent duplicate initialization
    if (!element.hasAttribute('data-initialized')) {
      const options = JSON.parse(element.getAttribute('data-options') || '{}');
      new EbayCategorySelector(element, options);
      // Mark as initialized
      element.setAttribute('data-initialized', 'true');
    }
  });
}

// Initialize on both DOMContentLoaded and turbo:load/render events
document.addEventListener('DOMContentLoaded', initializeEbayCategorySelectors);
document.addEventListener('turbo:load', initializeEbayCategorySelectors);
document.addEventListener('turbo:render', initializeEbayCategorySelectors);

export default EbayCategorySelector; 