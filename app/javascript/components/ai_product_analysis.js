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
  
  const dropzone = document.getElementById('dropzone');
  const hiddenFileInput = document.getElementById('hidden-file-input');
  const browseButton = document.getElementById('browse-button');
  const fileCount = document.getElementById('file-count');
  const filePreviewList = document.getElementById('file-preview-list');
  const previewContainer = document.getElementById('preview-container');
  const clearButton = document.getElementById('clear-button');

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
    hiddenFileInput.files = files;
    updateFilePreview(files);
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
    hiddenFileInput.value = '';
    previewContainer.classList.add('d-none');
    filePreviewList.innerHTML = '';
  }

  ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
    dropzone.addEventListener(eventName, preventDefaults, false);
    document.body.addEventListener(eventName, preventDefaults, false);
  });

  ['dragenter', 'dragover'].forEach(eventName => {
    dropzone.addEventListener(eventName, highlight, false);
  });

  ['dragleave', 'drop'].forEach(eventName => {
    dropzone.addEventListener(eventName, unhighlight, false);
  });

  dropzone.addEventListener('drop', handleDrop, false);

  dropzone.addEventListener('click', function() {
    hiddenFileInput.click();
  });

  browseButton.addEventListener('click', function(e) {
    e.stopPropagation();
    hiddenFileInput.click();
  });

  hiddenFileInput.addEventListener('change', function() {
    handleFiles(this.files);
  });

  clearButton.addEventListener('click', clearFiles);

  form.addEventListener('submit', function(e) {
    if (hiddenFileInput.files.length === 0) {
      e.preventDefault();
      alert('Please select at least one image to upload.');
    } else {
      const uploadButton = this.querySelector('button[type="submit"]');
      if (uploadButton) {
        uploadButton.disabled = true;
        uploadButton.innerHTML = '<i class="fas fa-spinner fa-spin"></i> Uploading...';
      }
    }
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