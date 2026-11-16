# Runs the tasks in config/schedule.yml when the app is used, instead of on a
# clock. For an install that sleeps when nobody is using it (no worker process,
# no Sidekiq::Cron): each request checks which tasks have come due since they
# last ran and enqueues those, so a task that was missed while the app was idle
# runs once on the next visit.
#
# Off unless ON_ACCESS_SCHEDULER=true, so the default behaviour is unchanged.
class OnAccessScheduler
  SCHEDULE_FILE = Rails.root.join("config/schedule.yml")

  # Tasks with nothing to do for a single household without bank connections or
  # the managed (hosted) mode. Everything else in schedule.yml is kept.
  EXCLUDED_TASKS = %w[
    process_financekit_inbox
    clean_inactive_families
    refresh_demo_family
    sync_property_valuations
    run_security_health_checks
  ].freeze

  # Bounds the work one request can trigger after a long idle period; the rest
  # runs on the following requests.
  MAX_TASKS_PER_TICK = 4
  MIN_SECONDS_BETWEEN_TICKS = 60

  @mutex = Mutex.new
  @last_tick_at = nil

  class << self
    def enabled?
      ENV["ON_ACCESS_SCHEDULER"] == "true"
    end

    # Returns the names of the tasks it enqueued. Never raises: a scheduling
    # problem must not break the page that triggered it.
    def tick(now: Time.current)
      return [] unless enabled?
      return [] unless claim_tick(now)

      enqueue_due_tasks(now)
    rescue StandardError => error
      Rails.logger.error("OnAccessScheduler failed: #{error.class}: #{error.message}")
      []
    end

    def tasks
      @tasks ||= YAML.load_file(SCHEDULE_FILE).except(*EXCLUDED_TASKS)
    end

    def reset_throttle!
      @mutex.synchronize { @last_tick_at = nil }
    end

    private
      def claim_tick(now)
        @mutex.synchronize do
          return false if @last_tick_at && (now - @last_tick_at) < MIN_SECONDS_BETWEEN_TICKS

          @last_tick_at = now
          true
        end
      end

      def enqueue_due_tasks(now)
        enqueued = []

        tasks.each do |name, config|
          break if enqueued.size >= MAX_TASKS_PER_TICK
          next unless claim_run(name, config["cron"], now)

          config.fetch("class").constantize.perform_later
          enqueued << name
        end

        enqueued
      end

      # Marks the task as run, under a row lock so two web processes never both
      # start the same occurrence. A task that has never run counts as due.
      def claim_run(name, cron, now)
        due_at = latest_occurrence(cron, now)
        return false if due_at.nil?

        ScheduledTaskRun.transaction do
          run = ScheduledTaskRun.lock.find_or_create_by!(name: name)
          return false if run.last_run_at && run.last_run_at.to_f >= due_at

          run.update!(last_run_at: now)
          true
        end
      rescue ActiveRecord::RecordNotUnique
        false
      end

      # Epoch seconds of the most recent time the cron expression fired, up to
      # and including `now`.
      def latest_occurrence(cron, now)
        Fugit::Cron.parse(cron)&.previous_time(now + 1.second)&.to_f
      end
  end
end
