import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["platformCheckbox", "submitButton", "productStatus"]
  
  connect() {
    console.log("Platform listing controller connected")
    this.updateButtonState()
    this.updateProductStatus()
  }
  
  togglePlatform(event) {
    console.log(`Platform ${event.target.value} toggled to ${event.target.checked}`)
    this.updateButtonState()
  }
  
  updateButtonState() {
    const anyChecked = this.platformCheckboxTargets.some(checkbox => checkbox.checked)
    
    if (this.hasSubmitButtonTarget) {
      this.submitButtonTarget.disabled = !anyChecked
      console.log(`Submit button enabled: ${anyChecked}`)
    }
  }
  
  updateProductStatus() {
    if (!this.hasProductStatusTarget) return
    
    const statuses = this.productStatusTargets
    statuses.forEach(status => {
      const platform = status.dataset.platform
      const isListed = status.dataset.listed === "true"
      
      if (isListed) {
        status.classList.add("listed")
        status.classList.remove("unlisted")
        status.innerHTML = `<span class="icon">✓</span> Listed on ${platform}`
      } else {
        status.classList.add("unlisted")
        status.classList.remove("listed")
        status.innerHTML = `<span class="icon">○</span> Not listed on ${platform}`
      }
    })
  }
} 