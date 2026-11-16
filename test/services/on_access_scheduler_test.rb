require "test_helper"

class OnAccessSchedulerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    OnAccessScheduler.stubs(:enabled?).returns(true)
    OnAccessScheduler.reset_throttle!
    ScheduledTaskRun.delete_all
    @now = Time.utc(2026, 11, 16, 10, 20)
  end

  test "a first tick enqueues at most the per-tick limit and records each run" do
    enqueued = OnAccessScheduler.tick(now: @now)

    assert_equal OnAccessScheduler::MAX_TASKS_PER_TICK, enqueued.size
    assert_equal enqueued.sort, ScheduledTaskRun.pluck(:name).sort
    assert_enqueued_jobs OnAccessScheduler::MAX_TASKS_PER_TICK
  end

  test "a second tick within a minute does nothing" do
    OnAccessScheduler.tick(now: @now)

    assert_no_enqueued_jobs do
      assert_equal [], OnAccessScheduler.tick(now: @now + 30.seconds)
    end
  end

  test "later ticks work through every remaining task exactly once" do
    ran = []
    5.times { |i| ran.concat(OnAccessScheduler.tick(now: @now + (i * 2).minutes)) }

    assert_equal OnAccessScheduler.tasks.keys.sort, ran.sort
  end

  test "a task does not run again until its next occurrence" do
    last_run = Time.utc(2026, 11, 16, 10, 0)
    OnAccessScheduler.tasks.each_key { |name| ScheduledTaskRun.create!(name: name, last_run_at: last_run) }

    # 10:20: only the every-15-minutes task has fired since 10:00 (at 10:15).
    assert_equal [ "sweep_expired_goal_pledges" ], OnAccessScheduler.tick(now: @now)
  end

  test "a daily task missed while the app was idle runs on the next visit" do
    last_run = Time.utc(2026, 11, 16, 10, 0)
    OnAccessScheduler.tasks.each_key { |name| ScheduledTaskRun.create!(name: name, last_run_at: last_run) }
    ScheduledTaskRun.find_by!(name: "clean_sessions").update!(last_run_at: Time.utc(2026, 11, 13, 10, 0))

    assert_equal [ "clean_sessions", "sweep_expired_goal_pledges" ], OnAccessScheduler.tick(now: @now).sort
  end

  test "tasks that only matter for bank connections or the hosted mode are never scheduled" do
    OnAccessScheduler::EXCLUDED_TASKS.each do |name|
      assert_not_includes OnAccessScheduler.tasks.keys, name
    end
  end

  test "every scheduled task points at a job class that exists" do
    OnAccessScheduler.tasks.each_value do |config|
      assert config.fetch("class").safe_constantize, "#{config['class']} is not defined"
    end
  end

  test "does nothing when disabled" do
    OnAccessScheduler.stubs(:enabled?).returns(false)

    assert_no_enqueued_jobs do
      assert_equal [], OnAccessScheduler.tick(now: @now)
    end
    assert_equal 0, ScheduledTaskRun.count
  end

  test "a failure while enqueuing is logged and does not raise" do
    SyncCleanerJob.stubs(:perform_later).raises(StandardError, "queue down")

    assert_nothing_raised do
      assert_equal [], OnAccessScheduler.tick(now: @now)
    end
  end
end
