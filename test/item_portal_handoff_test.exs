defmodule Valimc.ItemPortalHandoffTest do
  # Item handoffs across dimensions (VMC-026c): tagged ends, separate receipts.
  use ExUnit.Case, async: true
  alias Valimc.{Dimension, ItemMotionState, TestScope}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World
  alias Valimc.World.{ItemHandoffs, ItemLedger, ItemRecords, Items, Region}

  setup do
    nonce = System.unique_integer([:positive])
    key = {41_000 + rem(nonce, 3_333) * 3, 900}
    beside = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-portal-handoff-#{nonce}")
    TestScope.isolate(TestScope.neighborhood(key), world_path: base)
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

    {:ok, bytes} = ItemRecords.encode(key, [record.(key, 1)])
    Valimc.TestDisk.write(base, key, :items, bytes)

    on_exit(fn ->
      for region <- [key, beside, {:the_nether, key}, {:the_nether, beside}],
          {pid, _} <- Registry.lookup(Valimc.RegionRegistry, region),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{key: key, beside: beside, base: base, record: record}
  end

  defp resource({pid, _}), do: Valimc.TestConn.state(pid).resource
  defp wait(fun), do: Valimc.TestWait.until(fun)
  defp nether(fun), do: Dimension.within(:the_nether, fun)

  defp owner(:the_nether, key), do: nether(fn -> elem(World.item_owner(key), 1) end)
  defp owner(:overworld, key), do: elem(World.item_owner(key), 1)

  # One step of `uuid` to `position`, as a portal's destination places it.
  defp step(owner, uuid, position, cooldown) do
    {:ok, {_epoch, id, revision}} = Items.find(resource(owner).entities.items, uuid)

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
      s.entities.items.ledger.outgoing == nil and not Valimc.TestRegion.writing?(s)
    end)
  end

  defp holds?(owner, uuid), do: match?({:ok, _}, Items.find(resource(owner).entities.items, uuid))

  test "an overworld item crosses into the Nether, durably, and survives both owners' restarts",
       ctx do
    {bx, bz} = ctx.beside
    source = owner(:overworld, ctx.key)
    target = owner(:the_nether, ctx.beside)
    arrival = {bx * 128 + 9.5, 70.0, bz * 128 + 9.5}

    assert {:ok, 1} =
             Region.handoff_items(
               source,
               {:the_nether, ctx.beside},
               [step(source, <<1::128>>, arrival, 300)]
             )

    settled(source)
    wait(fn -> holds?(target, <<1::128>>) end)
    refute holds?(source, <<1::128>>)

    {:ok, {_, id, _}} = Items.find(resource(target).entities.items, <<1::128>>)
    entry = resource(target).entities.items.entries[id]
    assert {entry.entity.x, entry.entity.y, entry.entity.z} == arrival
    assert entry.motion.portal_cooldown > 0 and entry.motion.age >= 9
    assert Map.keys(resource(target).entities.items.ledger.incoming) == [{:overworld, ctx.key}]

    # Both owners restart from disk: the item stays in the Nether, once.
    for {pid, _} <- [source, target], do: TestScope.kill(pid)
    source = owner(:overworld, ctx.key)
    target = owner(:the_nether, ctx.beside)
    wait(fn -> holds?(target, <<1::128>>) end)
    refute holds?(source, <<1::128>>)
    assert Map.keys(resource(target).entities.items.ledger.incoming) == [{:overworld, ctx.key}]
  end

  test "a same-coordinate Nether neighbour and the overworld region keep separate receipts",
       ctx do
    {bx, bz} = ctx.beside
    # The Nether region at the overworld source's coordinates, with an item of its own.
    {:ok, bytes} = ItemRecords.encode(ctx.key, [ctx.record.(ctx.key, 2)])
    Valimc.TestDisk.write(Dimension.storage(ctx.base, :the_nether), ctx.key, :items, bytes)
    nether_source = owner(:the_nether, ctx.key)
    target = owner(:the_nether, ctx.beside)
    source = owner(:overworld, ctx.key)

    assert {:ok, 1} =
             Region.handoff_items(
               nether_source,
               ctx.beside,
               [step(nether_source, <<2::128>>, {bx * 128 + 1.5, 64.25, bz * 128 + 1.5}, 0)]
             )

    assert {:ok, 1} =
             Region.handoff_items(
               source,
               {:the_nether, ctx.beside},
               [step(source, <<1::128>>, {bx * 128 + 2.5, 64.25, bz * 128 + 2.5}, 300)]
             )

    settled(nether_source)
    settled(source)
    wait(fn -> holds?(target, <<1::128>>) and holds?(target, <<2::128>>) end)

    assert Enum.sort(Map.keys(resource(target).entities.items.ledger.incoming)) ==
             Enum.sort([ctx.key, {:overworld, ctx.key}])
  end

  test "crossing digests and ledgers: tagged ends round-trip, own-dimension tags are refused",
       ctx do
    {bx, bz} = ctx.beside
    records = [%{ctx.record.(ctx.beside, 7) | x: bx * 128 + 3.5, z: bz * 128 + 3.5}]
    generations = %{<<7::128>> => 1}

    transfer = %{
      source: {:overworld, ctx.key},
      sequence: 1,
      destination: {:the_nether, ctx.beside},
      records: records,
      generations: generations
    }

    assert {:ok, digest} = ItemHandoffs.digest(transfer.destination, transfer)
    assert byte_size(digest) == 32

    # Both ends in one dimension is not a crossing.
    assert {:error, :invalid_item_handoff} =
             ItemHandoffs.digest({:overworld, ctx.beside}, %{
               transfer
               | destination: {:overworld, ctx.beside}
             })

    # A ledger with a crossing outgoing intent and a tagged receipt is version 2,
    # and decodes to itself; one without keeps version 1.
    ledger = %ItemLedger{
      sequence: 1,
      outgoing: %{
        destination: {:the_nether, ctx.beside},
        records: records,
        generations: generations
      },
      incoming: %{{:the_end, ctx.beside} => %{sequence: 3, digest: <<5::256>>}}
    }

    assert {:ok, <<"VMCLEDGR", 2, _::binary>> = bytes} =
             ItemLedger.encode(ctx.key, [], %{}, ledger)

    assert {:ok, %{ledger: ^ledger}} = ItemLedger.decode(bytes, ctx.key)

    plain = %ItemLedger{
      sequence: 1,
      incoming: %{ctx.beside => %{sequence: 3, digest: <<5::256>>}}
    }

    assert {:ok, <<"VMCLEDGR", 1, _::binary>>} = ItemLedger.encode(ctx.key, [], %{}, plain)
  end
end
