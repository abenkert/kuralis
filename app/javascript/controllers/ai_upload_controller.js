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
    this.directUploads = new Map() // Track direct uploads
    this.performanceMetrics = {
      fileSelection: 0,
      previewGeneration: 0,
      upload: 0
    }
    console.log("AI Upload controller connected with direct upload support")
    
    // Listen for direct upload events
    this.element.addEventListener('direct-upload:initialize', this.handleDirectUploadInitialize.bind(this))
    this.element.addEventListener('direct-upload:start', this.handleDirectUploadStart.bind(this))
    this.element.addEventListener('direct-upload:progress', this.handleDirectUploadProgress.bind(this))
    this.element.addEventListener('direct-upload:error', this.handleDirectUploadError.bind(this))
    this.element.addEventListener('direct-upload:end', this.handleDirectUploadEnd.bind(this))
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

  // Handle form submission with modern best practices
  async handleSubmit(event) {
    event.preventDefault()
    
    if (this.isUploading) return
    if (this.selectedFiles.length === 0) {
      alert('Please select at least one image to upload.')
      return
    }

    console.log(`Starting upload of ${this.selectedFiles.length} files`)
    this.isUploading = true
    this.showProgress()

    // For direct uploads, we need to wait for Active Storage to complete
    if (this.inputTarget.hasAttribute('data-direct-upload')) {
      console.log('Using Active Storage direct uploads - waiting for completion')
      this.updateProgress(0, this.selectedFiles.length, 'Starting direct upload...')
      
      // Don't submit immediately - wait for direct uploads to complete
      // The handleDirectUploadEnd method will handle the final submission
    } else {
      // Fallback to traditional upload for development/testing
      console.log('Using traditional upload')
      await this.handleTraditionalUpload()
    }
  }

  // Traditional upload method (fallback)
  async handleTraditionalUpload() {
    try {
      const formData = new FormData()
      formData.append('authenticity_token', 
        document.querySelector('[name="authenticity_token"]').value)
      
      this.selectedFiles.forEach(file => {
        formData.append('images[]', file)
      })

      formData.append('format', 'json')
      this.updateProgress(0, this.selectedFiles.length, 'Uploading files...')

      const response = await fetch(this.formTarget.action, {
        method: 'POST',
        body: formData,
        headers: {
          'X-Requested-With': 'XMLHttpRequest',
          'Accept': 'application/json'
        }
      })

      if (response.ok) {
        const contentType = response.headers.get('content-type')
        if (contentType && contentType.includes('application/json')) {
          const result = await response.json()
          console.log('Upload successful:', result)
          
          this.updateProgress(this.selectedFiles.length, this.selectedFiles.length, 'Upload complete! Starting AI analysis...')
          
          // Show a success message before redirecting
          this.showSuccessMessage(result)
          
          setTimeout(() => {
            window.location.href = result.redirect_url || '/kuralis/ai_product_analyses?tab=processing'
          }, 2000) // Longer delay to show success message
        } else {
          const htmlContent = await response.text()
          console.error('Expected JSON but got HTML:', htmlContent.substring(0, 200))
          throw new Error('Server returned HTML instead of JSON. This usually means an authentication or routing issue.')
        }
      } else {
        const contentType = response.headers.get('content-type')
        if (contentType && contentType.includes('application/json')) {
          const errorData = await response.json()
          throw new Error(errorData.error || `Upload failed: ${response.statusText}`)
        } else {
          const htmlContent = await response.text()
          console.error('Error response HTML:', htmlContent.substring(0, 200))
          throw new Error(`Upload failed: ${response.status} ${response.statusText}`)
        }
      }
    } catch (error) {
      console.error('Upload failed:', error)
      this.showUploadError(error)
      this.hideProgress()
      this.isUploading = false
    }
  }

  // Show upload error with better messaging
  showUploadError(error) {
    let errorMessage = 'Upload failed. Please try again.'
    
    if (error.message.includes('413') || error.message.includes('too large')) {
      errorMessage = 'Files are too large. Please reduce file sizes and try again.'
    } else if (error.message.includes('timeout')) {
      errorMessage = 'Upload timed out. Please try with fewer files or check your connection.'
    } else if (error.message.includes('network')) {
      errorMessage = 'Network error. Please check your connection and try again.'
    }
    
    // Show error in a more user-friendly way
    const errorDiv = document.createElement('div')
    errorDiv.className = 'alert alert-danger mt-3'
    errorDiv.innerHTML = `
      <strong>Upload Error:</strong> ${errorMessage}
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    `
    
    this.formTarget.appendChild(errorDiv)
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

  // Direct upload event handlers
  handleDirectUploadInitialize(event) {
    const { target, detail } = event
    const { id, file } = detail
    
    console.log(`Initializing direct upload for ${file.name}`)
    this.directUploads.set(id, {
      file: file,
      progress: 0,
      status: 'initializing'
    })
    
    this.showProgress()
    this.updateProgress(0, this.selectedFiles.length, 'Starting direct upload...')
  }

  handleDirectUploadStart(event) {
    const { id } = event.detail
    const upload = this.directUploads.get(id)
    
    if (upload) {
      upload.status = 'uploading'
      console.log(`Direct upload started for ${upload.file.name}`)
    }
  }

  handleDirectUploadProgress(event) {
    const { id, progress } = event.detail
    const upload = this.directUploads.get(id)
    
    if (upload) {
      upload.progress = progress
      
      // Calculate overall progress
      const totalProgress = Array.from(this.directUploads.values())
        .reduce((sum, upload) => sum + upload.progress, 0) / this.directUploads.size
      
      this.updateProgress(
        Math.floor(totalProgress / 100 * this.selectedFiles.length), 
        this.selectedFiles.length, 
        `Uploading directly to cloud storage... ${Math.round(totalProgress)}%`
      )
    }
  }

  handleDirectUploadError(event) {
    const { id, error } = event.detail
    const upload = this.directUploads.get(id)
    
    if (upload) {
      upload.status = 'error'
      console.error(`Direct upload failed for ${upload.file.name}:`, error)
      
      // Check if we should continue or abort
      const errorCount = Array.from(this.directUploads.values())
        .filter(upload => upload.status === 'error').length
      
      const completedCount = Array.from(this.directUploads.values())
        .filter(upload => upload.status === 'complete').length
      
      if (errorCount === this.directUploads.size) {
        // All uploads failed
        this.showUploadError(new Error(`All direct uploads failed. Please try again or check your internet connection.`))
        this.hideProgress()
        this.isUploading = false
      } else if (completedCount + errorCount === this.directUploads.size) {
        // Some succeeded, some failed - let user decide
        const message = `${errorCount} of ${this.directUploads.size} uploads failed. Continue with ${completedCount} successful uploads?`
        if (confirm(message)) {
          console.log('Continuing with partial uploads')
          this.updateProgress(completedCount, this.selectedFiles.length, `Submitting ${completedCount} successful uploads...`)
          setTimeout(() => {
            this.formTarget.submit()
          }, 500)
        } else {
          this.hideProgress()
          this.isUploading = false
        }
      } else {
        // Still have uploads in progress
        this.updateProgress(
          completedCount, 
          this.selectedFiles.length, 
          `Upload error occurred. ${completedCount}/${this.selectedFiles.length} complete, ${errorCount} failed`
        )
      }
    }
  }

  handleDirectUploadEnd(event) {
    const { id } = event.detail
    const upload = this.directUploads.get(id)
    
    if (upload) {
      upload.status = 'complete'
      upload.progress = 100
      console.log(`Direct upload completed for ${upload.file.name}`)
      
      // Check if all uploads are complete
      const allComplete = Array.from(this.directUploads.values())
        .every(upload => upload.status === 'complete' || upload.status === 'error')
      
      const completedCount = Array.from(this.directUploads.values())
        .filter(upload => upload.status === 'complete').length
      
      console.log(`${completedCount}/${this.directUploads.size} uploads completed`)
      
      if (allComplete && this.directUploads.size === this.selectedFiles.length) {
        console.log('All direct uploads completed - submitting form')
        this.updateProgress(this.selectedFiles.length, this.selectedFiles.length, 'All uploads complete! Submitting...')
        
        // Now submit the form with the signed IDs
        setTimeout(() => {
          this.formTarget.submit()
        }, 500) // Small delay to ensure all signed IDs are properly set
      } else {
        // Update progress for partial completion
        this.updateProgress(
          completedCount, 
          this.selectedFiles.length, 
          `Uploading to cloud storage... ${completedCount}/${this.selectedFiles.length} complete`
        )
      }
    }
  }

  // Show success message
  showSuccessMessage(result) {
    const successMessage = document.createElement('div')
    successMessage.className = 'alert alert-success mt-3'
    successMessage.innerHTML = `
      <strong>Upload Successful!</strong>
      <p>${result.message || 'Your images have been successfully uploaded and are being processed.'}</p>
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    `
    
    this.formTarget.appendChild(successMessage)
  }
} 