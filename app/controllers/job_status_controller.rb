class JobStatusController < AuthenticatedController
  def index
    @job_runs = current_shop.job_runs.recent

    @job_runs = case params[:status]
    when "running"
                  @job_runs.running
    when "failed"
                  @job_runs.failed
    when "completed"
                  @job_runs.completed
    else
                  @job_runs
    end

    @status = params[:status] || "all"
    @job_runs = @job_runs.page(params[:page]).per(10)
  end

  def show
    @job_run = current_shop.job_runs.find(params[:id])

    respond_to do |format|
      format.html
      format.json { render json: job_run_json(@job_run) }
    end
  end

  private

  def job_run_json(job_run)
    {
      id: job_run.id,
      job_class: job_run.job_class,
      status: job_run.status,
      started_at: job_run.started_at,
      completed_at: job_run.completed_at,
      duration: job_run.duration,
      progress: job_run.progress_data || {},
      error_message: job_run.error_message,
      created_at: job_run.created_at
    }
  end

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
end
