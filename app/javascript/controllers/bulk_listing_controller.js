import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "checkbox", 
    "deselectedIds", 
    "selectAllRecords", 
    "selectedCount", 
    "searchInput", 
    "productRow",
    "platformCheckbox",
    "submitButton"
  ]
  
  static values = {
    totalCount: Number
  }

  connect() {
    console.log("Bulk listing controller connected");
    
    // Initialize deselected IDs using the hidden field value
    this.deselectedIds = new Set();
    const savedIds = this.deselectedIdsTarget.value;
    console.log("Initial deselected IDs from hidden field:", savedIds);
    
    if (savedIds && savedIds !== '[]') {
      this.deselectedIds = new Set(JSON.parse(savedIds));
      console.log("Parsed deselected IDs:", [...this.deselectedIds]);
    }
    
    // Set initial states for checkboxes
    console.log("Total checkboxes found:", this.checkboxTargets.length);
    this.checkboxTargets.forEach(checkbox => {
      if (this.deselectedIds.has(checkbox.value)) {
        checkbox.checked = false;
        console.log("Unchecking product ID:", checkbox.value);
      }
    });

    this.updateDeselectedIds();
    this.updatePlatformState();
  }

  updateDeselectedIds() {
    const deselectedArray = [...this.deselectedIds];
    console.log("Updating deselected IDs:", deselectedArray);
    this.deselectedIdsTarget.value = JSON.stringify(deselectedArray);
    
    // Update the count display
    const selectedCount = this.totalCountValue - this.deselectedIds.size;
    console.log(`Selection count updated: ${selectedCount} of ${this.totalCountValue}`);
    this.selectedCountTarget.textContent = 
      `${selectedCount} of ${this.totalCountValue} products selected`;
  }

  toggleSelection(event) {
    const checkbox = event.target;
    const productId = checkbox.value;
    console.log(`Toggle selection for product ${productId}, checked: ${checkbox.checked}`);

    if (checkbox.checked) {
      this.deselectedIds.delete(productId);
      console.log(`Removed ${productId} from deselected IDs`);
    } else {
      this.deselectedIds.add(productId);
      console.log(`Added ${productId} to deselected IDs`);
    }
    
    this.updateDeselectedIds();
  }

  clearSelection(event) {
    event.preventDefault();
    console.log("Clearing all selections");
    this.deselectedIds.clear();
    this.updateDeselectedIds();
    location.reload();
  }

  submitForm(event) {
    console.log("Form submitted with deselected IDs:", [...this.deselectedIds]);
  }

  search() {
    const searchTerm = this.searchInputTarget.value.toLowerCase();
    console.log('Searching for:', searchTerm);
    console.log('Number of product rows:', this.productRowTargets.length);
    
    let visibleCount = 0;
    this.productRowTargets.forEach(row => {
      const title = row.querySelector('.product-title').textContent.toLowerCase();
      const isVisible = title.includes(searchTerm);
      row.style.display = isVisible ? '' : 'none';
      if (isVisible) visibleCount++;
    });
    console.log(`Search complete: ${visibleCount} products visible`);
  }
  
  // Handle platform selection
  togglePlatform(event) {
    console.log(`Platform ${event.target.value} toggled: ${event.target.checked}`);
    this.updatePlatformState();
  }
  
  updatePlatformState() {
    if (this.hasPlatformCheckboxTarget && this.hasSubmitButtonTarget) {
      const anyPlatformSelected = this.platformCheckboxTargets.some(checkbox => checkbox.checked);
      this.submitButtonTarget.disabled = !anyPlatformSelected;
      console.log(`Submit button enabled: ${anyPlatformSelected}`);
    }
  }
} 