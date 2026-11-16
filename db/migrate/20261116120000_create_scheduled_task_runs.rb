class CreateScheduledTaskRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_task_runs, id: :uuid do |t|
      t.string :name, null: false
      t.datetime :last_run_at

      t.timestamps
    end

    add_index :scheduled_task_runs, :name, unique: true
  end
end
