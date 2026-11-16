# Lets OnAccessScheduler run due tasks as a side effect of normal page loads.
module OnAccessScheduling
  extend ActiveSupport::Concern

  included do
    after_action :run_due_scheduled_tasks, if: -> { request.get? && OnAccessScheduler.enabled? }
  end

  private
    def run_due_scheduled_tasks
      OnAccessScheduler.tick
    end
end
