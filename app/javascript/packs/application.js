// This file is automatically compiled by Webpack, along with any other files
// present in this directory. You're encouraged to place your actual application logic in
// a relevant structure within app/javascript and only use these pack files to reference
// that code so it'll be compiled.

import Rails from "@rails/ujs"
import Turbo from "@hotwired/turbo-rails"
import * as ActiveStorage from "@rails/activestorage"
import "channels"

Rails.start()
Turbo.start()
ActiveStorage.start()

// Initialize ActionCable
import consumer from "../channels/consumer"
window.App = window.App || {};
window.App.cable = consumer; 