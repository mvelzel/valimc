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

  test "moving a viewer changes only its old/new location and fences its earlier session" do
    {state, first, _} = add(%Viewers{}, @a)

    {:ok, next, [^first], [{@a, false}, {@b, true}]} =
      Viewers.register(state, first.pid, make_ref(), make_ref(), @b, true, 2)

    assert Viewers.open_count(next, @a) == 0 and Viewers.open_count(next, @b) == 1
    assert next.views[first.pid].position == @b
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

  test "position invalidation retires every exact registration once, without affecting other viewers" do
    {state, a, _} = add(%Viewers{}, @a)
    {state, b, _} = add(state, @a)
    {state, spectator, _} = add(state, @b, false)
    {next, retired, [{@a, false}]} = Viewers.invalidate(state, [@a, @a])
    assert Enum.sort(retired) == Enum.sort([a, b])
    assert next.views == %{spectator.pid => spectator}
    assert {^next, [], []} = Viewers.invalidate(next, [@a])
  end

  test "timer generations coalesce independently of content and each acknowledgment fences its own lane" do
    {state, a, _} = add(%Viewers{}, @a, false, 17)
    {state, b, _} = add(state, @b, false, 17)
    {state, [{pid, ref, 1}]} = Viewers.progressed(state, @a, 1)
    assert {pid, ref} == {a.pid, a.ref}
    assert state.views[a.pid].revision == 17 and not state.views[a.pid].pending
    assert state.views[b.pid] == b

    state =
      Enum.reduce(2..1000, state, fn generation, state ->
        {next, []} = Viewers.progressed(state, @a, generation)
        next
      end)

    {state, [{_, _, 18}]} = Viewers.changed(state, @a, 18)
    content_seen = Viewers.observed(state, a.pid, a.ref, 18)
    assert content_seen.views[a.pid].progress_pending
    refute content_seen.views[a.pid].pending
    assert Viewers.observed_progress(content_seen, a.pid, a.ref, 999) == content_seen
    assert Viewers.observed_progress(content_seen, a.pid, make_ref(), 1000) == content_seen
    state = Viewers.observed_progress(content_seen, a.pid, a.ref, 1000)
    refute state.views[a.pid].progress_pending
    {state, [{_, _, 1001}]} = Viewers.progressed(state, @a, 1001)
    {state, [{_, _, 19}]} = Viewers.changed(state, @a, 19)
    state = Viewers.observed_progress(state, a.pid, a.ref, 1001)
    assert state.views[a.pid].pending
    refute state.views[a.pid].progress_pending
    assert state.views[a.pid].revision == 19
  end

  test "retired timer sessions and invalid generations cannot acknowledge a replacement" do
    {state, a, _} = add(%Viewers{}, @a, false)
    {state, [_]} = Viewers.progressed(state, @a, 5)
    replacement = make_ref()
    {:ok, state, [_], []} = Viewers.register(state, a.pid, replacement, make_ref(), @a, false, 1)
    {state, [_]} = Viewers.progressed(state, @a, 6)
    assert Viewers.observed_progress(state, a.pid, a.ref, 6) == state

    for invalid <- [-1, nil, 1.5, 18_446_744_073_709_551_616] do
      assert {^state, []} = Viewers.progressed(state, @a, invalid)
      assert Viewers.observed_progress(state, a.pid, replacement, invalid) == state
    end

    {empty, [_], []} = Viewers.unregister(state, a.pid, replacement)
    assert empty.views == %{} and empty.positions == %{}
    assert {^empty, []} = Viewers.progressed(empty, @a, 7)
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

  test "invalid positions, revisions and actor identities allocate no observations" do
    empty = %Viewers{}

    for {position, revision} <- [
          {{0, -65, 0}, 1},
          {{0, 320, 0}, 1},
          {{30_000_000, 64, 0}, 1},
          {@a, 0},
          {@a, nil}
        ] do
      assert {:error, :invalid_container_view} =
               Viewers.register(empty, pid(), make_ref(), make_ref(), position, true, revision)
    end

    assert {:error, :invalid_container_view} =
             Viewers.register(empty, :actor, make_ref(), make_ref(), @a, true, 1)
  end
end
