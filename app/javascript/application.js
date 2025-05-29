// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import * as Popper from "@popperjs/core"
import * as bootstrap from "bootstrap"
import "./components/ebay_category_selector"

// Make Popper globally available for Bootstrap
window.Popper = Popper

// Initialize Bootstrap tooltips
const initTooltips = () => {
  // Dispose existing tooltips
  document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(el => {
    const tooltip = bootstrap.Tooltip.getInstance(el);
    if (tooltip) {
      tooltip.dispose();
    }
  });
  
  // Initialize new tooltips
  const tooltipTriggerList = document.querySelectorAll('[data-bs-toggle="tooltip"]');
  const tooltipList = [...tooltipTriggerList].map(el => new bootstrap.Tooltip(el));
};

// Initialize on first load and after Turbo navigation
document.addEventListener("turbo:load", initTooltips);
document.addEventListener("turbo:render", initTooltips);

// Add a global event handler to ensure JavaScript is properly initialized with Turbo
document.addEventListener("turbo:before-cache", () => {
  // Cleanup any global elements that might cause issues when the page is cached
  // For example, disposing tooltips, popovers, etc.
  document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(el => {
    const tooltip = bootstrap.Tooltip.getInstance(el);
    if (tooltip) {
      tooltip.dispose();
    }
  });

  // Mark all file inputs as processed to prevent reopening dialogs
  document.querySelectorAll('input[type="file"]').forEach(input => {
    input.dataset.processed = 'true';
  });
});

document.addEventListener('turbo:before-render', () => {
  // Avoid disrupting file inputs that are currently being interacted with
  document.querySelectorAll('input[type="file"]').forEach(input => {
    if (document.activeElement === input) {
      console.log('Active file input detected during navigation');
      // We don't prevent the navigation, but mark it for special handling
      window._activeFileInputNavigation = true;
    }
  });
});

document.addEventListener('turbo:render', () => {
  if (window._activeFileInputNavigation) {
    console.log('Navigation occurred during file input interaction');
    window._activeFileInputNavigation = false;
    // Give extra time for things to settle before reinitializing
    setTimeout(() => {
      // You might want to do something specific here
    }, 500);
  }
});
