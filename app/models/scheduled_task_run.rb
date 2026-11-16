# When OnAccessScheduler last ran each task from config/schedule.yml.
class ScheduledTaskRun < ApplicationRecord
  validates :name, presence: true, uniqueness: true
end
