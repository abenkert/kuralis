import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["dropzone", "fileInput"]
  
  connect() {
    console.log("Dropzone controller connected")
    if (this.hasDropzoneTarget && this.hasFileInputTarget) {
      this.setupDropzone()
    } else {
      console.error("Missing required targets", {
        hasDropzone: this.hasDropzoneTarget,
        hasFileInput: this.hasFileInputTarget
      })
    }
  }
  
  setupDropzone() {
    console.log("Setting up dropzone with file input:", this.fileInputTarget)
    
    // Bind the preventDefaults method to this instance
    const preventDefaults = this.preventDefaults.bind(this)
    
    // Prevent default drag behaviors
    ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
      this.dropzoneTarget.addEventListener(eventName, preventDefaults, false)
      document.body.addEventListener(eventName, preventDefaults, false)
    })
    
    // Highlight drop area when item is dragged over it
    ['dragenter', 'dragover'].forEach(eventName => {
      this.dropzoneTarget.addEventListener(eventName, () => {
        this.dropzoneTarget.classList.add('dropzone-active')
      }, false)
    })
    
    ['dragleave', 'drop'].forEach(eventName => {
      this.dropzoneTarget.addEventListener(eventName, () => {
        this.dropzoneTarget.classList.remove('dropzone-active')
      }, false)
    })
    
    // Handle dropped files
    this.dropzoneTarget.addEventListener('drop', (e) => {
      const dt = e.dataTransfer
      const files = dt.files
      
      console.log("Files dropped:", files)
      this.fileInputTarget.files = files
      this.updateFilePreview()
    }, false)
  }
  
  // Stimulus action for file input change
  fileSelected() {
    console.log("File input changed:", this.fileInputTarget.files)
    this.updateFilePreview()
  }
  
  // Stimulus action for dropzone click
  openFileBrowser(event) {
    // Don't trigger if they clicked on a button or link inside the dropzone
    if (event.target.tagName !== 'BUTTON' && event.target.tagName !== 'A' && 
        event.target.tagName !== 'LABEL' && event.target.tagName !== 'INPUT') {
      console.log("Dropzone clicked, triggering file input")
      this.fileInputTarget.click()
    }
  }
  
  // Stimulus action for browse button click
  browse(event) {
    event.preventDefault()
    console.log("Browse button clicked")
    this.fileInputTarget.click()
  }
  
  // Stimulus action for clear button click
  clearFiles(event) {
    event.preventDefault()
    event.stopPropagation()
    console.log("Clear button clicked")
    this.fileInputTarget.value = ''
    this.resetDropzone()
  }
  
  updateFilePreview() {
    const files = this.fileInputTarget.files
    console.log("Updating file preview with files:", files)
    
    if (!files || files.length === 0) {
      console.log("No files selected")
      return
    }
    
    const dropzoneContent = this.dropzoneTarget.querySelector('.dropzone-content')
    if (!dropzoneContent) {
      console.error("Dropzone content not found")
      return
    }
    
    // Create a preview of selected files
    let previewHTML = `
      <div class="selected-files p-3">
        <div class="d-flex align-items-center justify-content-between mb-3">
          <h6 class="mb-0 font-weight-bold">${files.length} ${files.length === 1 ? 'file' : 'files'} selected</h6>
          <button type="button" class="btn btn-sm btn-outline-secondary" data-action="dropzone#clearFiles">Clear</button>
        </div>
        <div class="selected-files-list">
    `
    
    // Add preview for up to 5 files
    const previewCount = Math.min(files.length, 5)
    for (let i = 0; i < previewCount; i++) {
      const file = files[i]
      previewHTML += `
        <div class="selected-file d-flex align-items-center mb-2">
          <i class="fas fa-file-image text-primary me-2"></i>
          <span class="small text-truncate">${file.name}</span>
          <span class="ms-2 small text-muted">(${this.formatFileSize(file.size)})</span>
        </div>
      `
    }
    
    // If there are more files than shown in preview
    if (files.length > previewCount) {
      previewHTML += `<div class="small text-muted">And ${files.length - previewCount} more...</div>`
    }
    
    previewHTML += `
        </div>
      </div>
    `
    
    dropzoneContent.innerHTML = previewHTML
  }
  
  resetDropzone() {
    console.log("Resetting dropzone")
    const dropzoneContent = this.dropzoneTarget.querySelector('.dropzone-content')
    if (dropzoneContent) {
      dropzoneContent.innerHTML = `
        <i class="fas fa-cloud-upload-alt fa-3x mb-3 text-muted"></i>
        <p class="mb-1">Drag and drop images here</p>
        <p class="text-muted small mb-3">or</p>
        <button type="button" class="btn btn-outline-primary mb-3" data-action="dropzone#browse">
          Browse Files
        </button>
        <p class="text-muted small mt-2">You can upload multiple images</p>
      `
    }
  }
  
  formatFileSize(bytes) {
    if (bytes === 0) return '0 Bytes'
    const k = 1024
    const sizes = ['Bytes', 'KB', 'MB', 'GB']
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i]
  }
  
  preventDefaults(e) {
    e.preventDefault()
    e.stopPropagation()
  }
} 