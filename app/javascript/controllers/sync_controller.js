import { Controller } from "@hotwired/stimulus"
import * as bootstrap from "bootstrap"

export default class extends Controller {
  static targets = ["spinner"]
  
  startSync(event) {
    this.spinnerTarget.classList.remove("d-none")
    this.showToast("Syncing eBay listings. This may take a few minutes...")
  }
  
  syncComplete() {
    this.spinnerTarget.classList.add("d-none")
    this.showToast("Sync completed!")
  }

  showToast(message) {
    const toastEl = document.createElement('div')
    toastEl.innerHTML = `
      <div class="toast" role="alert" aria-live="assertive" aria-atomic="true">
        <div class="toast-header">
          <strong class="me-auto">eBay Sync</strong>
          <button type="button" class="btn-close" data-bs-dismiss="toast" aria-label="Close"></button>
        </div>
        <div class="toast-body">
          ${message}
        </div>
      </div>
    `
    document.querySelector('.toast-container').appendChild(toastEl)
    const toast = new bootstrap.Toast(toastEl.querySelector('.toast'))
    toast.show()
  }
} 