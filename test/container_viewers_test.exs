defmodule Valimc.ContainerViewersTest do
  use ExUnit.Case, async: true
  alias Valimc.World.ContainerViewers, as: Viewers
  @a {0, 64, 0}
  @b {1, 64, 0}

  defp pid, do: spawn(fn -> :ok end)

  defp add(state, position, opener \\ true, revision \\ 1) do
    pid = pid()
    ref = make_ref()
    monitor = make_ref()

    {:ok, state, [], lids} =
      Viewers.register(state, pid, ref, monitor, position, opener, revision)

    {state, state.views[pid], lids}
  end

  test "only eligible first/last viewers change the lid, while spectators retain observations" do
    {state, first, [{@a, true}]} = add(%Viewers{}, @a)
    {state, spectator, []} = add(state, @a, false)
    {state, second, []} = add(state, @a)
    assert Viewers.open_count(state, @a) == 2
    {state, [^first], []} = Viewers.unregister(state, first.pid, first.ref)
    assert Viewers.open_count(state, @a) == 1
    {state, [^second], [{@a, false}]} = Viewers.unregister(state, second.pid, second.ref)
    assert state.views == %{spectator.pid => spectator}
    {state, [^spectator], []} = Viewers.down(state, spectator.pid, spectator.monitor)
    assert state.views == %{} and state.positions == %{}
  end

  test "duplicate registration is idempotent; old close/down cannot retire a replacement" do
    {state, first, _} = add(%Viewers{}, @a)

    assert {:ok, ^state, [], []} =
             Viewers.register(state, first.pid, first.ref, first.monitor, @a, true, 1)

    new_ref = make_ref()
    new_monitor = make_ref()

    {:ok, replaced, [^first], []} =
      Viewers.register(state, first.pid, new_ref, new_monitor, @a, true, 1)

    assert Viewers.open_count(replaced, @a) == 1
    assert {^replaced, [], []} = Viewers.unregister(replaced, first.pid, first.ref)
    assert {^replaced, [], []} = Viewers.down(replaced, first.pid, first.monitor)
    assert {^replaced, [], []} = Viewers.unregister(replaced, pid(), new_ref)

    assert {:error, :container_view_reference_conflict} =
             Viewers.register(replaced, first.pid, new_ref, new_monitor, @b, true, 1)

    {empty, [_], [{@a, false}]} = Viewers.down(replaced, first.pid, new_monitor)
    assert empty.views == %{} and empty.positions == %{}
  end

  test "one outstanding notice coalesces writes; an old snapshot cannot acknowledge newer content" do
    {state, a, _} = add(%Viewers{}, @a)
    {state, b, _} = add(state, @a)
    {state, c, _} = add(state, @b)
    {state, notices} = Viewers.changed(state, @a, 2)
    assert Enum.sort(notices) == Enum.sort([{a.pid, a.ref, 2}, {b.pid, b.ref, 2}])
    assert state.views[c.pid] == c
    {state, []} = Viewers.changed(state, @a, 3)
    assert state.views[a.pid].pending and state.views[a.pid].revision == 3
    assert Viewers.observed(state, a.pid, a.ref, 2) == state
    assert Viewers.observed(state, a.pid, make_ref(), 3) == state
    state = Viewers.observed(state, a.pid, a.ref, 3)
    refute state.views[a.pid].pending
    {state, [{pid, ref, 4}]} = Viewers.changed(state, @a, 4)
    assert pid == a.pid and ref == a.ref and state.views[b.pid].pending
    assert {^state, []} = Viewers.changed(state, @a, 4)
    assert {^state, []} = Viewers.changed(state, @a, 3)
  end

  test "full capacity permits replacement and wire occupancy never wraps at256 viewers" do
    state =
      Enum.reduce(1..Viewers.max_views(), %Viewers{}, fn _, current ->
        {next, _, _} = add(current, @a)
        next
      end)

    assert map_size(state.views) == Viewers.max_views()
    assert Viewers.open_count(state, @a) == Viewers.max_views()

    assert {:error, :container_viewer_limit} =
             Viewers.register(state, pid(), make_ref(), make_ref(), @b, true, 1)

    [{pid, view} | _] = Map.to_list(state.views)
    {:ok, state, [^view], []} = Viewers.register(state, pid, make_ref(), make_ref(), @a, true, 1)
    assert map_size(state.views) == Viewers.max_views()
    {_, body} = Valimc.Protocol.Packets.chest_lid(@a, Viewers.open_count(state, @a) > 0)
    {_, <<1, 1, rest::binary>>} = Valimc.Protocol.Wire.take_position(IO.iodata_to_binary(body))
    assert {245, <<>>} = Valimc.Protocol.Wire.take_varint(rest)
  end
end
