import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["selectAll", "checkbox", "selectedCount", "migrateSelected"]

  connect() {
    console.log("Listing Selection Controller Connected")
    this.updateSelectedCount()
    
    // Initialize all popovers
    document.querySelectorAll('[data-bs-toggle="popover"]').forEach(popoverTriggerEl => {
      new bootstrap.Popover(popoverTriggerEl)
    })
  }

  toggleAll(event) {
    console.log("Toggle All Triggered")
    const checked = this.selectAllTarget.checked
    console.log("Setting all to:", checked)
    
    this.checkboxTargets.forEach(checkbox => {
      if (!checkbox.disabled) {
        checkbox.checked = checked
      }
    })
    this.updateSelectedCount()
  }

  toggleOne(event) {
    console.log("Toggle One Triggered")
    console.log("Checkbox state:", event.target.checked)
    
    if (this.selectAllTarget.checked && !this.allChecked) {
      this.selectAllTarget.checked = false
    } else if (!this.selectAllTarget.checked && this.allChecked) {
      this.selectAllTarget.checked = true
    }
    this.updateSelectedCount()
  }

  updateSelectedCount() {
    const count = this.checkboxTargets.filter(cb => cb.checked).length
    console.log("Updating count to:", count)
    this.selectedCountTarget.textContent = count
    this.migrateSelectedTarget.disabled = count === 0
  }

  get allChecked() {
    return this.checkboxTargets
      .filter(cb => !cb.disabled)
      .every(cb => cb.checked)
  }

  // Reset selection when page changes
  resetSelection() {
    this.selectAllTarget.checked = false
    this.updateSelectedCount()
  }

  migrate(event) {
    event.preventDefault()
    
    const selectedIds = this.checkboxTargets
      .filter(cb => cb.checked)
      .map(cb => cb.value)
    
    if (selectedIds.length === 0) {
      return
    }

    const form = document.createElement('form')
    form.method = 'POST'
    form.action = '/ebay/listings/migrations'
    
    // Add authenticity token
    const authToken = document.querySelector('meta[name="csrf-token"]').content
    const authInput = document.createElement('input')
    authInput.type = 'hidden'
    authInput.name = 'authenticity_token'
    authInput.value = authToken
    form.appendChild(authInput)
    
    // Add listing IDs
    selectedIds.forEach(id => {
      const input = document.createElement('input')
      input.type = 'hidden'
      input.name = 'listing_ids[]'
      input.value = id
      form.appendChild(input)
    })

    document.body.appendChild(form)
    form.submit()
  }

  async migrateAll(event) {
    event.preventDefault()
    
    try {
      // First fetch the total count of unmigrated listings
      const response = await fetch('/ebay/listings/migrations/unmigrated_count')
      const data = await response.json()
      
      if (data.count === 0) {
        alert('No listings available to migrate.')
        return
      }

      if (confirm(`Are you sure you want to migrate all ${data.count} listings? This may take some time.`)) {
        const form = document.createElement('form')
        form.method = 'POST'
        form.action = '/ebay/listings/migrations'
        
        // Add authenticity token
        const authToken = document.querySelector('meta[name="csrf-token"]').content
        const authInput = document.createElement('input')
        authInput.type = 'hidden'
        authInput.name = 'authenticity_token'
        authInput.value = authToken
        form.appendChild(authInput)
        
        // Add migrate_all flag
        const migrateAllInput = document.createElement('input')
        migrateAllInput.type = 'hidden'
        migrateAllInput.name = 'migrate_all'
        migrateAllInput.value = 'true'
        form.appendChild(migrateAllInput)

        document.body.appendChild(form)
        form.submit()
      }
    } catch (error) {
      console.error('Error fetching unmigrated count:', error)
      alert('Error checking available listings. Please try again.')
    }
  }
} 