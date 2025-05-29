import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [
    "form", "input", "dropzone", "previewContainer", "fileList", "fileCount",
    "submitButton", "progressContainer", "progressBar", "progressCurrent", 
    "progressTotal", "progressStatus"
  ]
  
  static values = {
    maxFiles: { type: Number, default: 500 },
    maxSize: { type: Number, default: 10 * 1024 * 1024 } // 10MB
  }

  connect() {
    this.selectedFiles = []
    this.isUploading = false
    this.previewCache = new Map() // Cache for faster preview generation
    this.uploadStartTime = null
    this.performanceMetrics = {
      fileSelection: 0,
      previewGeneration: 0,
      upload: 0
    }
    console.log("AI Upload controller connected with performance monitoring")
  }

  disconnect() {
    this.selectedFiles = []
    this.previewCache.clear()
  }

  // Browse button clicked
  browse(event) {
    event.preventDefault()
    event.stopPropagation()
    this.inputTarget.click()
  }

  // File input changed
  handleFileSelect(event) {
    const files = Array.from(event.target.files)
    this.addFiles(files)
  }

  // Drag and drop handlers
  dragEnter(event) {
    event.preventDefault()
    event.stopPropagation()
    this.dropzoneTarget.classList.add('dropzone-active')
  }

  dragOver(event) {
    event.preventDefault()
    event.stopPropagation()
    this.dropzoneTarget.classList.add('dropzone-active')
  }

  dragLeave(event) {
    event.preventDefault()
    event.stopPropagation()
    // Only remove active state if we're leaving the dropzone entirely
    if (!this.dropzoneTarget.contains(event.relatedTarget)) {
      this.dropzoneTarget.classList.remove('dropzone-active')
    }
  }

  handleDrop(event) {
    event.preventDefault()
    event.stopPropagation()
    this.dropzoneTarget.classList.remove('dropzone-active')
    
    const files = Array.from(event.dataTransfer.files)
    this.addFiles(files)
  }

  // Add files to selection
  addFiles(files) {
    const validFiles = []
    const errors = []

    files.forEach(file => {
      // Check file type
      if (!file.type.startsWith('image/')) {
        errors.push(`${file.name} is not an image file`)
        return
      }

      // Check file size
      if (file.size > this.maxSizeValue) {
        errors.push(`${file.name} is too large (max ${this.formatFileSize(this.maxSizeValue)})`)
        return
      }

      // Check if we're at max files
      if (this.selectedFiles.length + validFiles.length >= this.maxFilesValue) {
        errors.push(`Maximum ${this.maxFilesValue} files allowed`)
        return
      }

      // Check for duplicates
      const isDuplicate = this.selectedFiles.some(existingFile => 
        existingFile.name === file.name && existingFile.size === file.size
      )
      
      if (!isDuplicate) {
        validFiles.push(file)
      }
    })

    // Show errors if any
    if (errors.length > 0) {
      this.showErrors(errors)
    }

    // Add valid files
    if (validFiles.length > 0) {
      this.selectedFiles.push(...validFiles)
      this.updateFileInput()
      this.updatePreview()
    }
  }

  // Remove a specific file
  removeFile(event) {
    const index = parseInt(event.target.dataset.index)
    const file = this.selectedFiles[index]
    
    // Remove from cache
    if (file && this.previewCache.has(file.name + file.size)) {
      this.previewCache.delete(file.name + file.size)
    }
    
    this.selectedFiles.splice(index, 1)
    this.updateFileInput()
    this.updatePreview()
  }

  // Clear all files
  clearFiles() {
    this.selectedFiles = []
    this.previewCache.clear()
    this.updateFileInput()
    this.updatePreview()
  }

  // Update the hidden file input
  updateFileInput() {
    try {
      const dataTransfer = new DataTransfer()
      this.selectedFiles.forEach(file => dataTransfer.items.add(file))
      this.inputTarget.files = dataTransfer.files
    } catch (error) {
      console.error("Error updating file input:", error)
    }
  }

  // Update the preview display with optimized rendering
  updatePreview() {
    if (this.selectedFiles.length === 0) {
      this.previewContainerTarget.classList.add('d-none')
      return
    }

    this.previewContainerTarget.classList.remove('d-none')
    this.fileCountTarget.textContent = this.selectedFiles.length

    // Clear existing preview
    this.fileListTarget.innerHTML = ''

    // Show condensed view for many files (faster rendering)
    if (this.selectedFiles.length > 10) {
      this.showCondensedPreview()
    } else {
      this.showDetailedPreview()
    }
  }

  // Show detailed preview for smaller file counts
  showDetailedPreview() {
    this.selectedFiles.forEach((file, index) => {
      const fileItem = document.createElement('div')
      fileItem.className = 'file-item d-flex align-items-center p-2 mb-2 border rounded'
      
      // Create thumbnail placeholder first for immediate feedback
      const thumbnailContainer = document.createElement('div')
      thumbnailContainer.className = 'file-thumbnail me-3'
      thumbnailContainer.style.cssText = 'width: 40px; height: 40px; background: #f8f9fa; border-radius: 4px; display: flex; align-items: center; justify-content: center;'
      thumbnailContainer.innerHTML = '<i class="fas fa-image text-muted"></i>'
      
      fileItem.innerHTML = `
        <div class="file-info flex-grow-1 ms-3">
          <div class="file-name fw-bold text-truncate">${file.name}</div>
          <div class="file-size text-muted small">${this.formatFileSize(file.size)}</div>
        </div>
        <button type="button" 
                class="btn btn-sm btn-outline-danger"
                data-index="${index}"
                data-action="click->ai-upload#removeFile">
          <i class="fas fa-times"></i>
        </button>
      `
      
      fileItem.insertBefore(thumbnailContainer, fileItem.firstChild)
      this.fileListTarget.appendChild(fileItem)
      
      // Generate thumbnail asynchronously for better performance
      this.generateThumbnail(file, thumbnailContainer)
    })
  }

  // Generate optimized thumbnail
  generateThumbnail(file, container) {
    const cacheKey = file.name + file.size
    
    // Check cache first
    if (this.previewCache.has(cacheKey)) {
      const cachedUrl = this.previewCache.get(cacheKey)
      this.updateThumbnail(container, cachedUrl)
      return
    }
    
    // Generate new thumbnail
    const reader = new FileReader()
    reader.onload = (e) => {
      // Create a small canvas for thumbnail generation
      const img = new Image()
      img.onload = () => {
        const canvas = document.createElement('canvas')
        const ctx = canvas.getContext('2d')
        
        // Calculate thumbnail size (max 40x40)
        const maxSize = 40
        let { width, height } = img
        
        if (width > height) {
          if (width > maxSize) {
            height = (height * maxSize) / width
            width = maxSize
          }
        } else {
          if (height > maxSize) {
            width = (width * maxSize) / height
            height = maxSize
          }
        }
        
        canvas.width = width
        canvas.height = height
        
        // Draw resized image
        ctx.drawImage(img, 0, 0, width, height)
        
        // Convert to data URL and cache
        const thumbnailUrl = canvas.toDataURL('image/jpeg', 0.7)
        this.previewCache.set(cacheKey, thumbnailUrl)
        this.updateThumbnail(container, thumbnailUrl)
      }
      img.src = e.target.result
    }
    reader.readAsDataURL(file)
  }
  
  updateThumbnail(container, url) {
    container.innerHTML = `<img src="${url}" style="width: 100%; height: 100%; object-fit: cover; border-radius: 4px;">`
  }

  // Show condensed preview for large file counts
  showCondensedPreview() {
    // Group files by extension
    const groups = {}
    this.selectedFiles.forEach((file, index) => {
      const ext = file.name.split('.').pop().toLowerCase()
      if (!groups[ext]) groups[ext] = []
      groups[ext].push({ file, index })
    })

    Object.entries(groups).forEach(([ext, items]) => {
      const totalSize = items.reduce((sum, item) => sum + item.file.size, 0)
      
      const groupItem = document.createElement('div')
      groupItem.className = 'file-group mb-3 border rounded'
      groupItem.innerHTML = `
        <div class="group-header p-3 bg-light d-flex align-items-center">
          <div class="me-3">
            <i class="fas fa-file-image text-primary fa-2x"></i>
          </div>
          <div class="flex-grow-1">
            <div class="fw-bold">${items.length} ${ext.toUpperCase()} files</div>
            <div class="text-muted small">Total size: ${this.formatFileSize(totalSize)}</div>
          </div>
          <button type="button" 
                  class="btn btn-sm btn-outline-secondary"
                  data-action="click->ai-upload#toggleGroup">
            <i class="fas fa-chevron-down"></i>
          </button>
        </div>
        <div class="group-files d-none p-2">
          ${items.map(item => `
            <div class="d-flex align-items-center p-2 border-bottom">
              <div class="flex-grow-1">
                <div class="file-name small text-truncate">${item.file.name}</div>
                <div class="file-size text-muted" style="font-size: 0.75rem">${this.formatFileSize(item.file.size)}</div>
              </div>
              <button type="button" 
                      class="btn btn-sm btn-outline-danger"
                      data-index="${item.index}"
                      data-action="click->ai-upload#removeFile">
                <i class="fas fa-times"></i>
              </button>
            </div>
          `).join('')}
        </div>
      `
      this.fileListTarget.appendChild(groupItem)
    })
  }

  // Toggle group expansion
  toggleGroup(event) {
    const groupHeader = event.target.closest('.group-header')
    const groupFiles = groupHeader.nextElementSibling
    const icon = groupHeader.querySelector('i.fa-chevron-down, i.fa-chevron-up')
    
    if (groupFiles.classList.contains('d-none')) {
      groupFiles.classList.remove('d-none')
      icon.classList.remove('fa-chevron-down')
      icon.classList.add('fa-chevron-up')
    } else {
      groupFiles.classList.add('d-none')
      icon.classList.remove('fa-chevron-up')
      icon.classList.add('fa-chevron-down')
    }
  }

  // Handle form submission with improved progress tracking
  async handleSubmit(event) {
    event.preventDefault()
    
    if (this.isUploading) return
    if (this.selectedFiles.length === 0) {
      alert('Please select at least one image to upload.')
      return
    }

    this.isUploading = true
    this.showProgress()

    try {
      // Always use batch upload for better progress tracking
      await this.uploadInBatches()
      
      // Show completion message
      this.updateProgress(this.selectedFiles.length, this.selectedFiles.length, 'Upload complete! Processing images...')
      
      // Redirect after a short delay to show completion
      setTimeout(() => {
        window.location.reload()
      }, 1500)
    } catch (error) {
      console.error('Upload failed:', error)
      alert('Upload failed. Please try again.')
      this.hideProgress()
      this.isUploading = false
    }
  }

  // Optimized batch upload with better progress tracking
  async uploadInBatches() {
    const batchSize = 10  // Smaller batches for better progress feedback
    const totalBatches = Math.ceil(this.selectedFiles.length / batchSize)
    let uploadedCount = 0

    for (let i = 0; i < totalBatches; i++) {
      const start = i * batchSize
      const end = Math.min(start + batchSize, this.selectedFiles.length)
      const batch = this.selectedFiles.slice(start, end)

      this.updateProgress(uploadedCount, this.selectedFiles.length, 
        `Uploading batch ${i + 1} of ${totalBatches}... (${batch.length} files)`)

      const formData = new FormData()
      formData.append('authenticity_token', 
        document.querySelector('[name="authenticity_token"]').value)
      
      batch.forEach(file => {
        formData.append('images[]', file)
      })

      const response = await fetch(this.formTarget.action, {
        method: 'POST',
        body: formData
      })

      if (!response.ok) {
        throw new Error(`Batch ${i + 1} upload failed`)
      }

      uploadedCount += batch.length
      this.updateProgress(uploadedCount, this.selectedFiles.length, 
        `Uploaded ${uploadedCount} of ${this.selectedFiles.length} files`)

      // Shorter delay between batches for faster overall upload
      if (i < totalBatches - 1) {
        await new Promise(resolve => setTimeout(resolve, 200))
      }
    }
  }

  // Show progress UI
  showProgress() {
    this.progressContainerTarget.classList.remove('d-none')
    this.submitButtonTarget.disabled = true
    this.submitButtonTarget.innerHTML = '<i class="fas fa-spinner fa-spin me-2"></i>Uploading...'
  }

  // Hide progress UI
  hideProgress() {
    this.progressContainerTarget.classList.add('d-none')
    this.submitButtonTarget.disabled = false
    this.submitButtonTarget.innerHTML = '<i class="fas fa-magic me-2"></i>Upload & Analyze Images'
  }

  // Update progress display
  updateProgress(current, total, status) {
    const percentage = total > 0 ? (current / total) * 100 : 0
    
    this.progressCurrentTarget.textContent = current
    this.progressTotalTarget.textContent = total
    this.progressStatusTarget.textContent = status
    this.progressBarTarget.style.width = `${percentage}%`
  }

  // Show error messages
  showErrors(errors) {
    const errorMessage = errors.length === 1 
      ? errors[0] 
      : `${errors.length} files were skipped:\n${errors.join('\n')}`
    
    alert(errorMessage)
  }

  // Format file size
  formatFileSize(bytes) {
    if (bytes === 0) return '0 Bytes'
    const k = 1024
    const sizes = ['Bytes', 'KB', 'MB', 'GB']
    const i = Math.floor(Math.log(bytes) / Math.log(k))
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i]
  }
} 