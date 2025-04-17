module Admin
  class JobsController < ApplicationController
    before_action :require_admin
    layout "admin"

    def index
      @job_runs = JobRun.recent

      @job_runs = case params[:status]
      when "running"
                    @job_runs.running
      when "failed"
                    @job_runs.failed
      else
                    @job_runs
      end

      @status = params[:status] || "all"
      @job_runs = @job_runs.page(params[:page]).per(50)
    end

    private

    helper_method :job_status_color
    def job_status_color(status)
      case status
      when "completed" then "bg-success"
      when "failed" then "bg-danger"
      when "running" then "bg-primary"
      when "queued" then "bg-warning"
      else "bg-secondary"
      end
    end

    def require_admin
      unless current_user&.admin?
        redirect_to root_path, alert: "Not authorized"
      end
    end
  end
end
