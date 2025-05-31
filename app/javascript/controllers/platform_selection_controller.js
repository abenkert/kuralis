import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["submitButton"]

  connect() {
    this.updateButton()
  }

  updateButton() {
    const shopifyCheckbox = document.getElementById('platform_shopify')
    const ebayCheckbox = document.getElementById('platform_ebay')
    
    const shopifyChecked = shopifyCheckbox?.checked && !shopifyCheckbox?.disabled
    const ebayChecked = ebayCheckbox?.checked && !ebayCheckbox?.disabled
    
    let buttonText = "Finalize & List on "
    let platforms = []
    
    if (shopifyChecked) platforms.push("Shopify")
    if (ebayChecked) platforms.push("eBay")
    
    if (platforms.length === 0) {
      buttonText = "Finalize Only"
      this.submitButtonTarget.classList.remove('btn-success')
      this.submitButtonTarget.classList.add('btn-secondary')
    } else if (platforms.length === 1) {
      buttonText += platforms[0]
      this.submitButtonTarget.classList.remove('btn-secondary')
      this.submitButtonTarget.classList.add('btn-success')
    } else {
      buttonText += "All Platforms"
      this.submitButtonTarget.classList.remove('btn-secondary')
      this.submitButtonTarget.classList.add('btn-success')
    }
    
    this.submitButtonTarget.innerHTML = `
      <i class="bi bi-rocket-takeoff me-1"></i>
      ${buttonText}
    `
  }
} 