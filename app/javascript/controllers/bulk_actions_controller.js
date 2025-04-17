import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox", "bulkActionsButton"]

  connect() {
    console.log("Bulk actions controller connected")
    this.updateButtonState()
  }

  toggleSelection(event) {
    console.log("Toggle selection triggered")
    this.updateButtonState()
  }

  updateButtonState() {
    const checkedBoxes = this.checkboxTargets.filter(checkbox => checkbox.checked)
    console.log(`${checkedBoxes.length} checkboxes checked`)
    
    if (this.hasBulkActionsButtonTarget) {
      this.bulkActionsButtonTarget.disabled = checkedBoxes.length === 0
    }
  }

  toggleAll(event) {
    const isChecked = event.currentTarget.checked
    console.log(`Toggle all: ${isChecked}`)
    
    this.checkboxTargets.forEach(checkbox => {
      if (!checkbox.disabled) {
        checkbox.checked = isChecked
      }
    })
    
    this.updateButtonState()
  }
} 