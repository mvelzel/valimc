defmodule Valimc.WorldJobsTest do
  # A slot worker is watched like every job (VMC-077y): one killed from
  # outside fails through its monitor and its owner frees the slot.
  use ExUnit.Case, async: true
  alias Valimc.World.Jobs

  test "a killed slot worker fails through its monitor and frees its slot" do
    name = :"jobs_test_#{System.unique_integer([:positive])}"
    Jobs.init_slots!(name, 1)
    wrap = &{:tagged, &1}

    {:ok, jobs, job} =
      Jobs.start(%Jobs{}, :work, fn -> Process.sleep(:infinity) end, slots: name, wrap: wrap)

    assert {:error, {:retry, :workers_busy}} =
             Jobs.start(jobs, :other, fn -> :ok end, slots: name)

    Process.exit(job.pid, :kill)
    assert_receive {{:tagged, :job_down}, ref, :process, _, :killed}
    assert {:ok, %{kind: :work}, jobs} = Jobs.down(jobs, ref, :killed)

    {:ok, _jobs, %{token: token}} =
      Jobs.start(jobs, :other, fn -> :done end, slots: name, wrap: wrap)

    assert_receive {:tagged, {:job, :other, ^token, :done}}
  end
end
