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
