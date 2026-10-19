defmodule Valimc.Session.JobsTest do
  use ExUnit.Case, async: true
  alias Valimc.Session.Jobs

  defp next_message do
    receive do
      message -> message
    after
      1000 -> flunk("no message")
    end
  end

  test "a task result completes its job once; later messages are stale or unknown" do
    task = Task.async(fn -> :done end)
    {jobs, job} = Jobs.track(Jobs.new(), :pose, task, timeout: 1000, data: %{generation: 3})
    assert job.generation == 3 and Jobs.active?(jobs, :pose)
    assert {:result, :pose, %{generation: 3}, :done, jobs} = Jobs.classify(jobs, next_message())
    refute Jobs.active?(jobs, :pose)
    # The timer was cancelled and the monitor flushed.
    refute_receive _, 20
    assert Jobs.classify(jobs, {:job_timeout, :pose, job.ref}) == :stale
  end

  test "timeouts identify the job generation that armed them" do
    {jobs, old} = Jobs.track(Jobs.new(), :mining, nil, timeout: 0)
    assert {:timeout, :mining, ^old, jobs} = Jobs.classify(jobs, next_message())
    {jobs, _new} = Jobs.track(jobs, :mining, nil, timeout: 1000)
    assert Jobs.classify(jobs, {:job_timeout, :mining, old.ref}) == :stale
    assert {_, jobs} = Jobs.cancel(jobs, :mining)
    refute Jobs.active?(jobs, :mining)
  end

  test "a monitored process exit is a down outcome; cancel kills and flushes" do
    pid = spawn(fn -> receive do: (:exit -> exit(:boom)) end)
    {jobs, _} = Jobs.track(Jobs.new(), :auth, pid, timeout: 1000)
    send(pid, :exit)
    assert {:down, :auth, _, :boom, jobs} = Jobs.classify(jobs, next_message())
    refute Jobs.active?(jobs, :auth)

    sleeper = spawn(fn -> Process.sleep(:infinity) end)
    {jobs, _} = Jobs.track(jobs, :auth, sleeper)
    {job, jobs} = Jobs.cancel(jobs, :auth)
    assert job.pid == sleeper and not Process.alive?(sleeper)
    refute_receive {:DOWN, _, _, _, _}, 20
    assert jobs == %Jobs{}
  end

  test "attach moves a correlated job to its next stage and take completes it by ref" do
    {jobs, job} = Jobs.track(Jobs.new(), :table, nil, timeout: 1000, data: %{stage: :candidate})
    task = Task.async(fn -> :planned end)
    {jobs, staged} = Jobs.attach(Jobs.update(jobs, :table, %{stage: :plan}), :table, task)
    assert staged.ref == job.ref and staged.stage == :plan and staged.timer == job.timer
    assert {:result, :table, _, :planned, jobs} = Jobs.classify(jobs, next_message())

    {jobs, job} = Jobs.track(jobs, :experience, nil)
    assert {nil, ^jobs} = Jobs.take(jobs, :experience, make_ref())
    assert {%{kind: :experience}, jobs} = Jobs.take(jobs, :experience, job.ref)
    assert Jobs.cancel_all(jobs) == %Jobs{}
  end

  test "one job per kind" do
    {jobs, _} = Jobs.track(Jobs.new(), :motion, nil)
    assert_raise ArgumentError, fn -> Jobs.track(jobs, :motion, nil) end
    assert Jobs.classify(jobs, {:unrelated, 1}) == :unknown
  end
end
