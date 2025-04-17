class AddProgressDataToJobRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :job_runs, :progress_data, :jsonb
  end
end
