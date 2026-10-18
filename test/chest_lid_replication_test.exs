defmodule Valimc.World.ChestLidReplicationTest do
  use ExUnit.Case, async: true
  alias Valimc.World.ChestLidReplication, as: Lids

  test "one monitor covers an owner's visible lids and stale deaths cannot retire a replacement" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    owner = {pid, make_ref()}
    other = {pid, make_ref()}
    a = {1, 64, 1}
    b = {2, 64, 2}
    state = %Lids{} |> Lids.observe(owner, a, true) |> Lids.observe(owner, b, true)
    assert map_size(state.owners) == 1
    {monitor, positions} = state.owners[owner]
    assert MapSet.size(positions) == 2
    assert Lids.observe(state, owner, a, true) == state
    state = Lids.observe(state, owner, a, false)
    assert state.owners[owner] == {monitor, MapSet.new([b])}
    state = Lids.observe(state, other, b, true)
    assert state.owners[owner] == nil
    assert {^state, []} = Lids.down(state, monitor, pid)
    {current, _} = state.owners[other]
    assert {%Lids{positions: empty, owners: owners}, [^b]} = Lids.down(state, current, pid)
    assert empty == %{} and owners == %{}
  end

  test "unloaded chunks retire observations and a real owner death closes all retained lids" do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    owner = {pid, make_ref()}
    a = {-1, 64, -1}
    b = {17, 64, 17}
    state = %Lids{} |> Lids.observe(owner, a, true) |> Lids.observe(owner, b, true)
    state = Lids.retain(state, MapSet.new([{-1, -1}]))
    assert state.positions == %{a => owner}
    {monitor, _} = state.owners[owner]
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {%Lids{positions: empty}, [^a]} = Lids.down(state, monitor, pid)
    assert empty == %{}
  end
end
