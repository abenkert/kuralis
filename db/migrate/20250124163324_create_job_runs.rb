class CreateJobRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :job_runs do |t|
      t.string :job_class
      t.string :job_id
      t.string :status
      t.text :arguments
      t.text :error_message
      t.datetime :started_at
      t.datetime :completed_at
      t.references :shop, foreign_key: true
      
      t.timestamps
    end

    add_index :job_runs, :job_class
    add_index :job_runs, :status
    add_index :job_runs, :job_id
  end
end