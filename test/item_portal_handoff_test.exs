defmodule Valimc.ItemPortalHandoffTest do
  # Item handoffs across dimensions (VMC-026c): section keys as ends, separate receipts.
  use ExUnit.Case, async: true
  alias Valimc.World.Dimension
  alias Valimc.Entity.ItemMotionState
  alias Valimc.TestScope
  alias Valimc.Protocol.ItemStack
  alias Valimc.Entity.{Handoffs, Store}
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {41_000 + rem(nonce, 3_333) * 3, 900}
    beside = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-portal-handoff-#{nonce}")
    # Separate groups: Nether neighbours hand over durably, not inside a group.
    TestScope.isolate(TestScope.neighborhood(key), world_path: base, regionizer: false)
    File.mkdir_p!(base)

    record = fn {rx, rz}, n ->
      %{
        uuid: <<n::128>>,
        x: rx * 128 + 5.5,
        y: 64.25,
        z: rz * 128 + 5.5,
        stack: ItemStack.new("stone", 3),
        motion: %ItemMotionState{no_gravity: true}
      }
    end

    Valimc.TestDisk.write(base, key, :items, %{records: [record.(key, 1)]})

    on_exit(fn ->
      for region <- [key, beside, {:the_nether, key}, {:the_nether, beside}],
          {pid, _} <- Valimc.TestWorld.registered(region),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, beside: beside, base: base, record: record}
  end

  defp resource(owner), do: Valimc.TestRegion.section(owner)
  defp section(dimension, {x, z}), do: {dimension, x, z}
  defp wait(fun), do: Valimc.TestWait.until(fun)
  defp nether(fun), do: Dimension.within(:the_nether, fun)

  defp owner(:the_nether, key), do: nether(fn -> elem(Valimc.TestWorld.item_owner(key), 1) end)
  defp owner(:overworld, key), do: elem(Valimc.TestWorld.item_owner(key), 1)

  # One step of `uuid` to `position`, as a portal's destination places it.
  defp step(owner, uuid, position, cooldown) do
    {:ok, {_epoch, id, revision}} = Store.find(resource(owner).entities.store, uuid)

    %{
      id: id,
      revision: revision,
      position: position,
      motion: %ItemMotionState{
        velocity: {0.0, -0.1, 0.0},
        age: 9,
        no_gravity: true,
        portal_cooldown: cooldown
      }
    }
  end

  defp settled(owner) do
    wait(fn ->
      s = resource(owner)
      s.entities.store.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s)
    end)
  end

  defp holds?(owner, uuid),
    do: match?({:ok, _}, Store.find(resource(owner).entities.store, uuid))

  test "an overworld item crosses into the Nether, durably, and survives both owners' restarts",
       ctx do
    {bx, bz} = ctx.beside
    source = owner(:overworld, ctx.key)
    target = owner(:the_nether, ctx.beside)
    arrival = {bx * 128 + 9.5, 70.0, bz * 128 + 9.5}

    assert {:ok, 1} =
             Region.handoff_items(
               source,
               section(:the_nether, ctx.beside),
               [step(source, <<1::128>>, arrival, 300)]
             )

    settled(source)
    wait(fn -> holds?(target, <<1::128>>) end)
    refute holds?(source, <<1::128>>)

    {:ok, {_, id, _}} = Store.find(resource(target).entities.store, <<1::128>>)
    entry = resource(target).entities.store.entries[id]
    assert {entry.entity.x, entry.entity.y, entry.entity.z} == arrival
    assert entry.motion.portal_cooldown > 0 and entry.motion.age >= 9

    assert Map.keys(resource(target).entities.store.ledger.incoming) == [
             section(:overworld, ctx.key)
           ]

    # Both owners restart from disk: the item stays in the Nether, once.
    for {pid, _} <- [source, target], do: TestScope.kill(pid)
    source = owner(:overworld, ctx.key)
    target = owner(:the_nether, ctx.beside)
    wait(fn -> holds?(target, <<1::128>>) end)
    refute holds?(source, <<1::128>>)

    assert Map.keys(resource(target).entities.store.ledger.incoming) == [
             section(:overworld, ctx.key)
           ]
  end

  test "a same-coordinate Nether neighbour and the overworld region keep separate receipts",
       ctx do
    {bx, bz} = ctx.beside
    # The Nether region at the overworld source's coordinates, with an item of its own.
    Valimc.TestDisk.write(Dimension.storage(ctx.base, :the_nether), ctx.key, :items, %{
      records: [ctx.record.(ctx.key, 2)]
    })

    nether_source = owner(:the_nether, ctx.key)
    target = owner(:the_nether, ctx.beside)
    source = owner(:overworld, ctx.key)

    assert {:ok, 1} =
             Region.handoff_items(
               nether_source,
               section(:the_nether, ctx.beside),
               [step(nether_source, <<2::128>>, {bx * 128 + 1.5, 64.25, bz * 128 + 1.5}, 0)]
             )

    assert {:ok, 1} =
             Region.handoff_items(
               source,
               section(:the_nether, ctx.beside),
               [step(source, <<1::128>>, {bx * 128 + 2.5, 64.25, bz * 128 + 2.5}, 300)]
             )

    settled(nether_source)
    settled(source)
    wait(fn -> holds?(target, <<1::128>>) and holds?(target, <<2::128>>) end)

    assert Enum.sort(Map.keys(resource(target).entities.store.ledger.incoming)) ==
             Enum.sort([section(:the_nether, ctx.key), section(:overworld, ctx.key)])
  end

  test "handoff digests name both ends by section key, never a plain one", ctx do
    {bx, bz} = ctx.beside
    records = [%{ctx.record.(ctx.beside, 7) | x: bx * 128 + 3.5, z: bz * 128 + 3.5}]

    transfer = %{
      source: section(:overworld, ctx.key),
      sequence: 1,
      destination: section(:the_nether, ctx.beside),
      records: records,
      merge: nil
    }

    assert {:ok, <<_::256>> = digest} = Handoffs.digest(transfer)
    # A network id is the VM's and never part of the digest.
    with_id = %{transfer | records: Enum.map(records, &Map.put(&1, :entity_id, 9))}
    assert {:ok, ^digest} = Handoffs.digest(with_id)

    assert {:error, :invalid_item_handoff} =
             Handoffs.digest(%{transfer | destination: ctx.beside})

    assert {:error, :invalid_item_handoff} =
             Handoffs.digest(%{transfer | destination: transfer.source})
  end
end
