import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "source" ]

  connect() {
    // Initialize any tooltips if you're using Bootstrap's tooltip component
    if (typeof bootstrap !== 'undefined') {
      const tooltipTriggerList = document.querySelectorAll('[data-bs-toggle="tooltip"]')
      const tooltipList = [...tooltipTriggerList].map(tooltipTriggerEl => new bootstrap.Tooltip(tooltipTriggerEl))
    }
  }

  copy(event) {
    const text = event.currentTarget.dataset.clipboardText
    navigator.clipboard.writeText(text).then(() => {
      const button = event.currentTarget
      const originalHTML = button.innerHTML
      button.innerHTML = '<i class="bi bi-check"></i> Copied!'
      
      setTimeout(() => {
        button.innerHTML = originalHTML
      }, 2000)
    }).catch(err => {
      console.error('Failed to copy text: ', err)
    })
  }
} 