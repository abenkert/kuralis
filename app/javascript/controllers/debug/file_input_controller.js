import { Controller } from "@hotwired/stimulus"

// This is a simple debug controller to help diagnose file input issues
export default class extends Controller {
  static targets = ["input"]
  
  connect() {
    console.log("File input debug controller connected")
    this.setupListeners()
  }
  
  setupListeners() {
    if (!this.hasInputTarget) {
      console.error("No input target found for file input debug controller")
      return
    }
    
    console.log("Setting up listeners for file input:", this.inputTarget)
    
    this.inputTarget.addEventListener('change', this.handleChange.bind(this))
    this.inputTarget.addEventListener('click', this.handleClick.bind(this))
  }
  
  handleChange(event) {
    const files = event.target.files
    console.log("File input changed:", files)
    console.log("Number of files:", files.length)
    
    if (files.length > 0) {
      for (let i = 0; i < files.length; i++) {
        console.log(`File ${i + 1}:`, {
          name: files[i].name,
          type: files[i].type,
          size: files[i].size
        })
      }
    }
  }
  
  handleClick(event) {
    console.log("File input clicked")
  }
  
  // This can be called from a button or link
  triggerFileInput(event) {
    event.preventDefault()
    console.log("Manually triggering file input")
    this.inputTarget.click()
  }
} 