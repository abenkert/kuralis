module Ebay
    class QuickSyncController < Ebay::BaseController
        def create
            last_run = JobRun.where(job_class: 'ImportEbayListingsJob', 
                                   shop_id: current_shop.id, 
                                   status: 'completed')
                            .order(completed_at: :desc)
                            .first
                            
            if last_run
              # Use the start time of the last successful run
              ImportEbayListingsJob.perform_later(current_shop.id, last_run.started_at)
              message = 'Quick syncing eBay listings since last successful sync.'
            else
              # No previous successful run, do a full sync
              ImportEbayListingsJob.perform_later(current_shop.id)
              message = 'No previous sync found. Running a full sync of eBay listings.'
            end
            
            respond_to do |format|
              format.html do
                flash[:notice] = message
                redirect_to ebay_listings_path
              end
              format.turbo_stream do
                flash.now[:notice] = message
              end
            end
        end
    end
  end 