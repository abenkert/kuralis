module JobTrackable
  extend ActiveSupport::Concern

  included do
    before_enqueue do |job|
      JobRun.create!(
        job_class: job.class.name,
        job_id: job.job_id,
        status: "queued",
        arguments: job.arguments,
        shop_id: job.arguments.first.is_a?(Integer) ? job.arguments.first : nil
      )
    end

    before_perform do |job|
      if job_run = JobRun.find_by(job_id: job.job_id)
        job_run.update!(
          status: "running",
          started_at: Time.current
        )
      end
    end

    after_perform do |job|
      if job_run = JobRun.find_by(job_id: job.job_id)
        job_run.update!(
          status: "completed",
          completed_at: Time.current
        )
      end
    end

    rescue_from(StandardError) do |exception|
      if job_run = JobRun.find_by(job_id: job_id)
        job_run.update!(
          status: "failed",
          error_message: "#{exception.class}: #{exception.message}",
          completed_at: Time.current
        )
      end
      raise exception
    end
  end
end
