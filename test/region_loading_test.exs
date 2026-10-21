defmodule Valimc.RegionLoadingTest do
  use ExUnit.Case, async: false
  # Serial: asserts production latency deadlines that concurrent CPU load can exceed.
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region
  import ExUnit.CaptureLog

  test "a region saved before the region log fails clearly, keeps its file and leaves others available" do
    nonce = rem(System.unique_integer([:positive]), 10_000) + 1
    base = Path.join(System.tmp_dir!(), "valimc-pre-log-#{nonce}")
    key = {-752, -nonce}
    independent = {-753, -nonce}
    {rx, rz} = key
    # A pre-M1 per-file snapshot: no longer read, never replaced by an empty region.
    path = Path.join(base, "r.#{rx}.#{rz}.etf")
    File.mkdir_p!(base)
    File.write!(path, :erlang.term_to_binary({:valimc_region, 1, %{{0, 70, 0} => 1}}))
    TestScope.isolate([key, independent], world_path: base)

    try do
      assert capture_log(fn -> assert {:error, _} = World.owner(key) end) =~
               "saved before the region log"

      assert File.read!(path) == :erlang.term_to_binary({:valimc_region, 1, %{{0, 70, 0} => 1}})
      refute File.exists?(Valimc.World.Store.log_dir(base, key))
      assert_raise ArgumentError, fn -> Valimc.World.Store.durable(base, key, :blocks) end
      assert World.existing_owner(key) == {:error, :region_unavailable}
      assert World.item_snapshot(key) == %{}
      assert {:ok, owner} = World.owner(independent)
      assert {:ok, _} = Region.observe_blocks(owner, [])
      assert Process.alive?(Process.whereis(Valimc.RegionSupervisor))
    after
      for k <- [key, independent],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, k),
          do: TestScope.kill(pid)

      Valimc.TestScope.stop_neighbourhood(key)

      File.rm_rf!(base)
    end
  end

  test "a cold file read cannot hold the supervisor or publish an incomplete owner" do
    nonce = rem(System.unique_integer([:positive]), 10_000) + 1
    base = Path.join(System.tmp_dir!(), "valimc-cold-#{nonce}")
    key = {-750, -nonce}
    independent = {-751, -nonce}
    # The region's checkpoint is a FIFO: its cold read blocks until bytes arrive.
    seed = Path.join(base, "seed")
    {:ok, log, _} = Valimc.World.RegionLog.open(seed)
    {:ok, _} = Valimc.World.RegionLog.checkpoint(log, %{})
    [checkpoint] = seed |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "ckpt."))
    bytes = File.read!(Path.join(seed, checkpoint))
    dir = Valimc.World.Store.log_dir(base, key)
    File.mkdir_p!(dir)
    path = Path.join(dir, checkpoint)
    assert {_, 0} = System.cmd("mkfifo", [path])
    TestScope.isolate([key, independent], world_path: base)
    loading = Task.async(fn -> World.owner(key) end)

    try do
      pid = wait_registered(key)
      assert Task.yield(loading, 20) == nil
      assert Registry.lookup(Valimc.RegionRegistry, key) == [{pid, nil}]
      assert World.existing_owner(key) == {:error, :region_unavailable}
      assert World.item_snapshot(key) == %{}
      waiters = for _ <- 1..8, do: Task.async(fn -> World.owner(key) end)

      healthy = Task.async(fn -> World.owner(independent) end)

      try do
        assert {:ok, {:ok, {other, epoch}}} = Task.yield(healthy, 1000)
        size = Valimc.config(:region_size) * 16
        position = {elem(independent, 0) * size, 64, elem(independent, 1) * size}
        assert :ok = GenServer.call(other, {:set_block, position, 1}, 250)

        assert {:ok, %{blocks: %{^position => 1}}} =
                 Region.observe_blocks({other, epoch}, [position])

        clock = :sys.get_state(other).tick_clock

        :sys.replace_state(
          other,
          &put_in(&1.tick_clock.deadline, System.monotonic_time(:millisecond))
        )

        send(other, {:tick, clock.token})
        assert {:ok, _} = Region.observe_blocks({other, epoch}, [])
        assert :sys.get_state(other).tick_clock.tick > clock.tick
        assert Task.yield(loading, 0) == nil
      after
        Task.shutdown(healthy, :brutal_kill)
      end

      # The reader receives actual persisted bytes, not a fake completion message.
      File.write!(path, bytes, [:raw])
      assert {:ok, {^pid, epoch}} = Task.await(loading, 60_000)
      for task <- waiters, do: assert(Task.await(task, 60_000) == {:ok, {pid, epoch}})
      assert is_reference(epoch)
      assert World.existing_owner(key) == {:ok, {pid, epoch}}
      assert {:ok, %{revision: 0}} = Region.observe_blocks({pid, epoch}, [])
    after
      # Unblock File.read even when the assertion above fails against a regression.
      if Process.alive?(loading.pid) do
        release =
          Task.async(fn -> File.write(path, bytes, [:raw]) end)

        Task.yield(loading, 1000)
        Task.shutdown(release, :brutal_kill)
      end

      Task.shutdown(loading, :brutal_kill)

      for k <- [key, independent],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, k),
          do: TestScope.kill(pid)

      Valimc.TestScope.stop_neighbourhood(key)

      File.rm_rf!(base)
    end
  end

  defp wait_registered(key, _budget \\ nil) do
    Valimc.TestWait.until(fn ->
      case Registry.lookup(Valimc.RegionRegistry, key) do
        [{pid, _}] -> pid
        [] -> nil
      end
    end)
  end
end
