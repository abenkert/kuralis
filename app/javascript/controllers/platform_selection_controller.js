import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["submitButton"]

  connect() {
    this.updateButton()
    this.setupKeyboardShortcuts()
  }

  setupKeyboardShortcuts() {
    // Allow Enter key to submit the finalize & list button when focused
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey) {
        const activeElement = document.activeElement
        
        // If user is focused on a platform checkbox, submit the finalize & list button
        if (activeElement && (activeElement.id === 'platform_shopify' || activeElement.id === 'platform_ebay')) {
          event.preventDefault()
          this.submitButtonTarget.click()
        }
      }
    })
  }

  updateButton() {
    const shopifyCheckbox = document.getElementById('platform_shopify')
    const ebayCheckbox = document.getElementById('platform_ebay')
    
    const shopifyChecked = shopifyCheckbox?.checked && !shopifyCheckbox?.disabled
    const ebayChecked = ebayCheckbox?.checked && !ebayCheckbox?.disabled
    
    // Detect if we're in sequential mode
    const isSequential = window.location.pathname.includes('sequential')
    const baseText = isSequential ? "Finalize & List" : "Finalize & List"
    const nextText = isSequential ? " & Next" : ""
    
    let buttonText = ""
    let buttonClass = "btn btn-success"
    
    if (!shopifyChecked && !ebayChecked) {
      buttonText = isSequential ? "Finalize Only & Next" : "Finalize Only"
      buttonClass = "btn btn-secondary"
    } else if (shopifyChecked && ebayChecked) {
      buttonText = baseText + " All" + nextText
    } else if (shopifyChecked) {
      buttonText = baseText + " Shopify" + nextText
    } else if (ebayChecked) {
      buttonText = baseText + " eBay" + nextText
    }
    
    // Update button
    this.submitButtonTarget.className = buttonClass
    this.submitButtonTarget.innerHTML = `
      <i class="bi bi-rocket-takeoff me-1"></i>
      ${buttonText}
    `
    
    // Update the hidden input value to reflect whether we should list
    const shouldList = shopifyChecked || ebayChecked
    this.submitButtonTarget.value = shouldList ? "true" : "false"
  }
} 