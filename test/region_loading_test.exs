defmodule Valimc.RegionLoadingTest do
  use ExUnit.Case, async: false
  # Serial: asserts production latency deadlines that concurrent CPU load can exceed.
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region
  import ExUnit.CaptureLog

  test "a failed cold legacy block import preserves its file and leaves unrelated owners available" do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-bad-cold-#{nonce}")
    key = {-752, -nonce}
    independent = {-753, -nonce}
    path = Valimc.World.Store.block_path(base, key)
    File.mkdir_p!(base)
    File.write!(path, <<0>>)
    TestScope.isolate([key, independent], world_path: base)

    try do
      capture_log(fn -> assert {:error, _} = World.owner(key) end)
      assert File.read!(path) == <<0>>
      assert World.existing_owner(key) == {:error, :region_unavailable}
      assert World.item_snapshot(key) == %{}
      assert {:ok, owner} = World.owner(independent)
      assert {:ok, _} = Region.observe_blocks(owner, [])
      assert Process.alive?(Process.whereis(Valimc.RegionSupervisor))
    after
      for k <- [key, independent],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, k),
          do: TestScope.kill(pid)

      File.rm_rf!(base)
    end
  end

  test "a cold file read cannot hold the supervisor or publish an incomplete owner" do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-cold-#{nonce}")
    key = {-750, -nonce}
    independent = {-751, -nonce}
    path = Valimc.World.Store.block_path(base, key)
    File.mkdir_p!(base)
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

      # The writer receives actual persisted bytes, not a fake completion message.
      bytes = :erlang.term_to_binary({:valimc_region, 1, %{}})
      File.write!(path, bytes, [:raw])
      assert {:ok, {^pid, epoch}} = Task.await(loading, 1000)
      for task <- waiters, do: assert(Task.await(task, 1000) == {:ok, {pid, epoch}})
      assert is_reference(epoch)
      assert World.existing_owner(key) == {:ok, {pid, epoch}}
      assert {:ok, %{revision: 0}} = Region.observe_blocks({pid, epoch}, [])
    after
      # Unblock File.read even when the assertion above fails against a regression.
      if Process.alive?(loading.pid) do
        release =
          Task.async(fn ->
            File.write(path, :erlang.term_to_binary({:valimc_region, 1, %{}}), [:raw])
          end)

        Task.yield(loading, 1000)
        Task.shutdown(release, :brutal_kill)
      end

      Task.shutdown(loading, :brutal_kill)

      for k <- [key, independent],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, k),
          do: TestScope.kill(pid)

      File.rm_rf!(base)
    end
  end

  defp wait_registered(key, retries \\ 200)
  defp wait_registered(_key, 0), do: flunk("cold owner was not registered")

  defp wait_registered(key, retries) do
    case Registry.lookup(Valimc.RegionRegistry, key) do
      [{pid, _}] ->
        pid

      [] ->
        Process.sleep(1)
        wait_registered(key, retries - 1)
    end
  end
end
