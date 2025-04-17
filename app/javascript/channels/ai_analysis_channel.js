import consumer from "./consumer"

consumer.subscriptions.create("AiAnalysisChannel", {
  connected() {
    console.log("Connected to AiAnalysisChannel")
  },

  disconnected() {
    console.log("Disconnected from AiAnalysisChannel")
  },

  received(data) {
    console.log("Received data from AiAnalysisChannel:", data)
    
    // Find the element for this analysis
    const element = document.querySelector(`[data-analysis-id="${data.analysis_id}"]`)
    if (!element) return
    
    // This will be handled by the updateAnalysisStatus function in bulk_ai_creation.html.erb
    if (window.updateAnalysisStatus) {
      window.updateAnalysisStatus(data)
    }
  }
}) 