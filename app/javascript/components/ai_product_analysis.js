// Global variables to track timers and subscriptions
let pollingTimer = null;

// Cleanup function to prevent duplicates
function cleanup() {
  // Clear any existing polling timers
  if (pollingTimer) {
    clearTimeout(pollingTimer);
    pollingTimer = null;
  }
  
  // Unsubscribe from ActionCable if needed
  if (typeof App !== 'undefined' && App.cable && App.aiAnalysis) {
    App.cable.subscriptions.remove(App.aiAnalysis);
    App.aiAnalysis = null;
  }
}

// Change from DOMContentLoaded to Turbo events
document.addEventListener('turbo:load', function() {
  cleanup();
  setupDropzone();
  setupRealTimeUpdates();
  pollAnalysisStatus();
});

// Also listen for turbo:render to handle page updates without full reload
document.addEventListener('turbo:render', function() {
  cleanup();
  setupDropzone();
  setupRealTimeUpdates();
  pollAnalysisStatus();
});

// Add cleanup when navigating away
document.addEventListener('turbo:before-render', cleanup);

function setupDropzone() {
  const form = document.getElementById('file-upload-form');
  // If we're not on a page with the dropzone, exit early
  if (!form) return;
  
  // Hide the fallback input and show the dropzone when JS is available
  const fallbackInput = document.querySelector('.fallback-file-input');
  if (fallbackInput) {
    fallbackInput.classList.add('d-none');
  }
  
  const dropzoneEl = document.getElementById('dropzone');
  if (dropzoneEl) {
    dropzoneEl.classList.remove('d-none');
  }
  
  // Skip setup if the form is already being interacted with (prevents reopening file dialog)
  if (document.activeElement && document.activeElement.closest('#file-upload-form')) {
    console.log('Skipping dropzone setup during active interaction');
    return;
  }
  
  // Get all the necessary elements
  const dropzone = document.getElementById('dropzone');
  const browseButton = document.getElementById('browse-button');
  const fileCount = document.getElementById('file-count');
  const filePreviewList = document.getElementById('file-preview-list');
  const previewContainer = document.getElementById('preview-container');
  const clearButton = document.getElementById('clear-button');
  const fallbackFileInput = document.getElementById('fallback-file-input');
  
  // Clean up any existing event listeners by replacing the file input
  const hiddenFileInput = document.getElementById('hidden-file-input');
  const newInput = hiddenFileInput.cloneNode(true);
  
  // Store file references if available
  let existingFiles = null;
  try {
    if (hiddenFileInput.files && hiddenFileInput.files.length > 0) {
      existingFiles = hiddenFileInput.files;
    } else if (fallbackFileInput && fallbackFileInput.files && fallbackFileInput.files.length > 0) {
      // Check fallback input as well
      existingFiles = fallbackFileInput.files;
    }
  } catch (e) {
    console.log('Could not preserve existing files');
  }
  
  hiddenFileInput.parentNode.replaceChild(newInput, hiddenFileInput);
  
  // Re-get reference to the new input
  const fileInput = document.getElementById('hidden-file-input');
  
  // Restore existing files if available
  if (existingFiles) {
    try {
      const dataTransfer = new DataTransfer();
      for (let i = 0; i < existingFiles.length; i++) {
        dataTransfer.items.add(existingFiles[i]);
      }
      fileInput.files = dataTransfer.files;
      updateFilePreview(existingFiles);
    } catch (e) {
      console.log('Could not restore existing files');
    }
  }
  
  // Also handle the fallback input if it exists
  if (fallbackFileInput) {
    fallbackFileInput.addEventListener('change', function(e) {
      e.stopPropagation();
      if (this.files && this.files.length > 0) {
        handleFiles(this.files);
        
        // Also update the hidden input
        try {
          const dataTransfer = new DataTransfer();
          for (let i = 0; i < this.files.length; i++) {
            dataTransfer.items.add(this.files[i]);
          }
          fileInput.files = dataTransfer.files;
        } catch (err) {
          console.error("Could not copy files to hidden input", err);
        }
      }
    });
  }

  function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
  }

  function highlight() {
    dropzone.classList.add('dropzone-active');
  }

  function unhighlight() {
    dropzone.classList.remove('dropzone-active');
  }

  function formatFileSize(bytes) {
    if (bytes === 0) return '0 Bytes';
    const k = 1024;
    const sizes = ['Bytes', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function handleDrop(e) {
    const dt = e.dataTransfer;
    const files = dt.files;
    handleFiles(files);
  }

  function handleFiles(files) {
    if (!files || files.length === 0) return;
    
    try {
      console.log("Handling files:", files.length);
      
      // Use DataTransfer for better cross-browser compatibility
      const dataTransfer = new DataTransfer();
      for (let i = 0; i < files.length; i++) {
        dataTransfer.items.add(files[i]);
        console.log("Added file to DataTransfer:", files[i].name);
      }
      
      // Replace the file input directly to ensure it's clean
      const fileInput = document.getElementById('hidden-file-input');
      fileInput.files = dataTransfer.files;
      
      // Double-check the file attachment
      console.log("Files attached to input:", fileInput.files.length);
      
      // Update the preview
      updateFilePreview(files);
      
      // Make sure the button knows there are files
      const uploadButton = document.getElementById('upload-button');
      if (uploadButton) {
        uploadButton.disabled = false;
        uploadButton.classList.remove('disabled');
      }
    } catch (error) {
      console.error('Error handling files:', error);
      
      // Fallback for browsers not supporting DataTransfer
      const fileInput = document.getElementById('hidden-file-input');
      
      // Create a new input and replace the old one
      const newInput = document.createElement('input');
      newInput.type = 'file';
      newInput.id = 'hidden-file-input';
      newInput.name = 'images[]';
      newInput.multiple = true;
      newInput.accept = 'image/*';
      newInput.className = 'd-none';
      
      // Try to copy the files if possible
      try {
        // This only works in some browsers but is worth trying
        newInput.files = files;
      } catch (e) {
        console.error("Couldn't set files directly:", e);
      }
      
      fileInput.parentNode.replaceChild(newInput, fileInput);
      
      // Update the preview
      updateFilePreview(files);
      
      // Re-attach the change listener
      document.getElementById('hidden-file-input').addEventListener('change', function(e) {
        e.stopPropagation();
        if (this.files.length > 0) {
          handleFiles(this.files);
        }
      });
    }
  }

  function updateFilePreview(files) {
    if (files.length > 0) {
      previewContainer.classList.remove('d-none');
      fileCount.textContent = files.length;
      filePreviewList.innerHTML = '';

      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        const item = document.createElement('div');
        item.className = 'file-preview-item';
        item.innerHTML = `
          <span class="file-icon"><i class="fas fa-file-image"></i></span>
          <span class="file-name">${file.name}</span>
          <span class="file-size">${formatFileSize(file.size)}</span>
        `;
        filePreviewList.appendChild(item);
      }
    } else {
      previewContainer.classList.add('d-none');
    }
  }

  function clearFiles() {
    // Create a new file input element
    const newInput = document.createElement('input');
    newInput.type = 'file';
    newInput.id = 'hidden-file-input';
    newInput.name = 'images[]';
    newInput.multiple = true;
    newInput.accept = 'image/*';
    newInput.className = 'd-none';
    
    // Replace the old input
    fileInput.parentNode.replaceChild(newInput, fileInput);
    
    // Update UI
    previewContainer.classList.add('d-none');
    filePreviewList.innerHTML = '';
    
    // Re-attach event listener to the new input
    document.getElementById('hidden-file-input').addEventListener('change', function() {
      handleFiles(this.files);
    });
  }

  // Remove existing event listeners from document body to prevent duplicates
  ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
    document.body.removeEventListener(eventName, preventDefaults);
    document.body.addEventListener(eventName, preventDefaults, false);
  });

  // Set up new drag and drop listeners
  ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
    dropzone.removeEventListener(eventName, preventDefaults);
    dropzone.addEventListener(eventName, preventDefaults, false);
  });

  ['dragenter', 'dragover'].forEach(eventName => {
    dropzone.removeEventListener(eventName, highlight);
    dropzone.addEventListener(eventName, highlight, false);
  });

  ['dragleave', 'drop'].forEach(eventName => {
    dropzone.removeEventListener(eventName, unhighlight);
    dropzone.addEventListener(eventName, unhighlight, false);
  });

  // Remove existing drop listener and add a new one
  dropzone.removeEventListener('drop', handleDrop);
  dropzone.addEventListener('drop', handleDrop, false);

  // Add click listener to dropzone
  dropzone.addEventListener('click', function(e) {
    e.preventDefault();
    e.stopPropagation();
    // Prevent multiple triggers using a small delay
    if (!dropzone.dataset.clicking) {
      dropzone.dataset.clicking = 'true';
      // Small delay to ensure we don't conflict with current file events
      setTimeout(() => {
        fileInput.click();
        setTimeout(() => {
          delete dropzone.dataset.clicking;
        }, 500);
      }, 10);
    }
  });

  // Add click listener to browse button
  browseButton.addEventListener('click', function(e) {
    e.preventDefault();
    e.stopPropagation();
    // Prevent multiple triggers using a small delay
    if (!browseButton.dataset.clicking) {
      browseButton.dataset.clicking = 'true';
      // Small delay to ensure we don't conflict with current file events
      setTimeout(() => {
        fileInput.click();
        setTimeout(() => {
          delete browseButton.dataset.clicking;
        }, 500);
      }, 10);
    }
  });

  // Add change listener to file input
  fileInput.addEventListener('change', function(e) {
    // Stop propagation to prevent the event from bubbling up
    e.stopPropagation();
    if (this.files.length > 0) {
      handleFiles(this.files);
    }
  });

  // Add click listener to clear button
  clearButton.addEventListener('click', clearFiles);

  // Add submit listener to form
  form.addEventListener('submit', function(e) {
    const fileInput = document.getElementById('hidden-file-input');
    
    console.log("Form submitting, checking files...");
    console.log("Files in input:", fileInput.files ? fileInput.files.length : 0);
    
    // Also check if the preview is showing files
    const hasPreviewFiles = !previewContainer.classList.contains('d-none');
    console.log("Preview is showing files:", hasPreviewFiles);
    
    if (!fileInput.files || fileInput.files.length === 0) {
      if (!hasPreviewFiles) {
        console.log("No files found, preventing submission");
        e.preventDefault();
        alert('Please select at least one image to upload.');
        return false;
      } else {
        // Preview suggests files but input doesn't have them - try to recover
        console.log("Preview suggests files but input lacks them - continuing anyway");
      }
    }
    
    // Disable the button to prevent double submission
    const uploadButton = this.querySelector('button[type="submit"]');
    if (uploadButton) {
      uploadButton.disabled = true;
      uploadButton.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Uploading...';
    }
    
    // Add a flag to the form to help with debugging
    const debugInput = document.createElement('input');
    debugInput.type = 'hidden';
    debugInput.name = 'debug_info';
    debugInput.value = JSON.stringify({
      filesCount: fileInput.files ? fileInput.files.length : 0,
      hasPreview: hasPreviewFiles,
      timestamp: new Date().toISOString()
    });
    this.appendChild(debugInput);
    
    console.log("Form submission continuing");
    return true;
  });
}

function setupRealTimeUpdates() {
  // Only set up ActionCable if we're on the AI analysis page
  if (!document.querySelector('[data-analysis-id]')) return;
  
  if (typeof App !== 'undefined' && App.cable) {
    console.log('Connecting to AI Analysis channel');

    // Only create a new subscription if one doesn't already exist
    if (!App.aiAnalysis) {
      App.aiAnalysis = App.cable.subscriptions.create("AiAnalysisChannel", {
        connected: function() {
          console.log("Connected to AI Analysis channel");
        },
        disconnected: function() {
          console.log("Disconnected from AI Analysis channel");
        },
        received: function(data) {
          console.log("Received update:", data);
          updateAnalysisStatus(data);
        }
      });
    }
  } else {
    console.log('ActionCable not available, falling back to polling');
  }
}

function updateAnalysisStatus(data) {
  const element = document.querySelector(`[data-analysis-id="${data.analysis_id}"]`);
  if (!element) return;

  const statusElement = element.querySelector('.analysis-status');
  if (statusElement) {
    statusElement.textContent = data.status;
    statusElement.className = `analysis-status status-${data.status}`;
  }

  if (data.completed) {
    const createButton = element.querySelector('.create-product-btn');
    if (createButton) {
      createButton.classList.remove('disabled');
      createButton.removeAttribute('disabled');
    }

    if (data.results) {
      const titleElement = element.querySelector('h6.font-weight-bold');
      if (titleElement && data.results.title) {
        titleElement.textContent = data.results.title;
      }

      const descriptionContainer = element.querySelector('.small.text-muted.mb-3');
      if (descriptionContainer && data.results.description) {
        descriptionContainer.innerHTML = `
          <p class="mb-1">${truncateString(data.results.description, 100)}</p>
          ${data.results.price ? `<p class="mb-0">Price: $${data.results.price}</p>` : ''}
        `;
      }
    }
  } else if (data.status === 'failed') {
    const contentContainer = element.querySelector('.p-3');
    if (contentContainer) {
      const errorElement = contentContainer.querySelector('.small.text-danger.mb-3') || document.createElement('p');
      errorElement.className = 'small text-danger mb-3';
      errorElement.textContent = data.error || 'Analysis failed. Please try again.';

      const titleElement = contentContainer.querySelector('h6.font-weight-bold');
      if (titleElement && titleElement.nextElementSibling) {
        titleElement.nextElementSibling.replaceWith(errorElement);
      } else if (titleElement) {
        titleElement.after(errorElement);
      }
    }
  }
}

window.updateAnalysisStatus = updateAnalysisStatus;

function truncateString(str, maxLength) {
  if (!str) return '';
  if (str.length <= maxLength) return str;
  return str.substr(0, maxLength) + '...';
}

function pollAnalysisStatus() {
  // Skip if we're not on the AI analysis page
  if (!document.querySelector('[data-analysis-id]')) {
    return;
  }

  document.querySelectorAll('[data-analysis-id]').forEach(element => {
    const analysisId = element.dataset.analysisId;
    const statusElement = element.querySelector('.analysis-status');

    if (statusElement && statusElement.classList.contains('status-pending') || 
        statusElement && statusElement.classList.contains('status-processing')) {

      fetch(`/kuralis/ai_product_analyses/${analysisId}`)
        .then(response => response.json())
        .then(data => {
          updateAnalysisStatus({
            analysis_id: analysisId,
            status: data.status,
            completed: data.completed,
            results: data.completed ? data.results : null
          });
        })
        .catch(error => console.error('Error polling analysis status:', error));
    }
  });

  // Store the timer reference so we can clear it later
  pollingTimer = setTimeout(pollAnalysisStatus, 10000);
} 