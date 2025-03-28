// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"
import * as Popper from "@popperjs/core"
import * as bootstrap from "bootstrap"
import "./components/ebay_category_selector"
import "./components/ai_product_analysis"

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
});
