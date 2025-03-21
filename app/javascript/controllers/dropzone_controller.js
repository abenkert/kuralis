import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "preview", "template"]
  static values = {
    maxFiles: { type: Number, default: 10 },
    maxSize: { type: Number, default: 5 * 1024 * 1024 } // 5MB default
  }
  
  connect() {
    this.selectedFiles = new Set()
    this.setupDragAndDrop()
  }
  
  setupDragAndDrop() {
    ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
      this.element.addEventListener(eventName, (e) => {
        e.preventDefault()
        e.stopPropagation()
      })
    });

    ['dragenter', 'dragover'].forEach(eventName => {
      this.element.addEventListener(eventName, () => this.element.classList.add('dropzone-active'))
    })

    ['dragleave', 'drop'].forEach(eventName => {
      this.element.addEventListener(eventName, () => this.element.classList.remove('dropzone-active'))
    })
  }

  browse(e) {
    e.preventDefault()
    e.stopPropagation()
    this.inputTarget.click()
  }

  handleDrop(e) {
    const files = Array.from(e.dataTransfer.files)
    this.addFiles(files)
  }

  handleFileSelect(e) {
    const files = Array.from(e.target.files || [])
    if (files.length > 0) {
      this.addFiles(files)
    }
  }

  addFiles(files) {
    const validFiles = files.filter(file => {
      // Validate file type and size
      if (!file.type.startsWith('image/')) {
        this.showError(`${file.name} is not an image file`)
        return false
      }
      if (file.size > this.maxSizeValue) {
        this.showError(`${file.name} is too large (max ${this.formatSize(this.maxSizeValue)})`)
        return false
      }
      if (this.selectedFiles.size >= this.maxFilesValue) {
        this.showError(`Maximum ${this.maxFilesValue} files allowed`)
        return false
      }
      return true
    })

    validFiles.forEach(file => {
      // Use file.name as a unique identifier
      const existingFile = Array.from(this.selectedFiles).find(f => f.name === file.name)
      if (existingFile) {
        this.selectedFiles.delete(existingFile)
      }
      this.selectedFiles.add(file)
      this.createPreview(file)
    })

    if (validFiles.length > 0) {
      this.updateFormInput()
    }
  }

  createPreview(file) {
    // Skip if preview already exists
    if (this.previewTarget.querySelector(`[data-preview-id="${file.name}"]`)) {
      return
    }

    // Create preview element from template
    const preview = this.templateTarget.content.cloneNode(true)
    const previewElement = preview.querySelector('.image-preview-item')
    previewElement.dataset.previewId = file.name

    // Set the file name and size immediately
    preview.querySelector('.file-name').textContent = file.name
    preview.querySelector('.file-size').textContent = this.formatSize(file.size)

    // Create a loading state
    const img = preview.querySelector('img')
    img.alt = file.name
    img.style.opacity = '0.5'
    
    // Add a loading spinner
    const loadingSpinner = document.createElement('div')
    loadingSpinner.className = 'position-absolute top-50 start-50 translate-middle'
    loadingSpinner.innerHTML = '<div class="spinner-border spinner-border-sm text-primary" role="status"><span class="visually-hidden">Loading...</span></div>'
    preview.querySelector('.position-relative').appendChild(loadingSpinner)

    // Add the preview to the DOM first
    this.previewTarget.appendChild(preview)

    // Then start loading the image
    const reader = new FileReader()
    reader.onload = (e) => {
      const image = new Image()
      image.onload = () => {
        img.src = e.target.result
        img.style.opacity = '1'
        loadingSpinner.remove()
      }
      image.src = e.target.result
    }
    reader.readAsDataURL(file)
  }

  removeFile(e) {
    e.preventDefault()
    e.stopPropagation()
    const preview = e.target.closest('.image-preview-item')
    if (!preview) return

    const fileId = preview.dataset.previewId
    const file = Array.from(this.selectedFiles).find(f => f.name === fileId)
    if (file) {
      this.selectedFiles.delete(file)
      this.updateFormInput()
    }
    preview.remove()
  }

  removeExistingFile(e) {
    e.preventDefault()
    e.stopPropagation()
    const preview = e.target.closest('[data-image-id]')
    if (!preview) return

    const imageId = preview.dataset.imageId
    // Add a hidden field to mark this image for deletion
    const input = document.createElement('input')
    input.type = 'hidden'
    input.name = 'product[images_to_delete][]'
    input.value = imageId
    this.element.closest('form').appendChild(input)
    preview.remove()
  }

  updateFormInput() {
    const dt = new DataTransfer()
    this.selectedFiles.forEach(file => dt.items.add(file))
    this.inputTarget.files = dt.files
  }

  formatSize(bytes) {
    const units = ['B', 'KB', 'MB', 'GB']
    let size = bytes
    let unitIndex = 0
    
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024
      unitIndex++
    }
    
    return `${size.toFixed(1)} ${units[unitIndex]}`
  }

  showError(message) {
    console.error(message)
    // You could enhance this to show errors in the UI
    this.element.dispatchEvent(new CustomEvent('dropzone:error', { 
      detail: { message }, 
      bubbles: true 
    }))
  }
} 