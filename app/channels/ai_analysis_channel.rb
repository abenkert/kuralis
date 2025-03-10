class AiAnalysisChannel < ApplicationCable::Channel
  def subscribed
    if current_shop
      stream_from "ai_analysis_#{current_shop.id}"
    else
      reject
    end
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end 