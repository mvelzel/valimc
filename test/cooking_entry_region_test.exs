defmodule Valimc.CookingEntryRegionTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.{Cooking, World}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.{Containers, Region}

  test "cold owners retain mixed cooking entries and refuse raw removal until lifecycle admission exists" do
    nonce = System.unique_integer([:positive])
    key = {84_000 + rem(nonce, 10_000), 1991}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pos = {rx * span + 40, 64, rz * span + 40}
    blank = {elem(pos, 0) + 1, 64, elem(pos, 2)}
    base = Path.join(System.tmp_dir!(), "valimc-cooking-entry-#{nonce}")
    TestScope.isolate(key, world_path: base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {:ok, containers, entry} = Containers.create_cooking(%Containers{}, key, pos, :furnace)

    cooking = %Cooking{
      slots: {ItemStack.new("raw_iron", 2), ItemStack.new("coal", 2), nil},
      burn_left: 99,
      burn_total: 1600,
      progress: 19,
      total: 200
    }

    {:ok, containers, _} =
      Containers.replace_cooking(containers, pos, entry.revision, cooking, %{})

    {:ok, containers, _} = Containers.create_cooking(containers, key, blank, :smoker)
    containers = %{containers | receipts: %{<<1::128>> => %{sequence: 77, digest: <<1::256>>}}}
    {:ok, bytes} = Containers.encode(key, containers)
    File.mkdir_p!(base)
    Valimc.TestDisk.write(base, key, :containers, bytes)

    edits = %{
      pos => Data.item_block(Data.item("furnace")) - 1,
      blank => Data.item_block(Data.item("smoker"))
    }

    Valimc.TestDisk.write(base, key, :blocks, edits)

    {:ok, {pid, epoch}} = World.item_owner(key)

    request = %{
      source: <<2::128>>,
      sequence: 1,
      permit: <<3::128>>,
      position: blank,
      revision: containers.entries[blank].revision,
      kind: :smoker,
      slots: containers.entries[blank].cooking.slots,
      inventory: %Valimc.Inventory{carried: ItemStack.new("cod")},
      action: :pickup,
      slot: 0,
      button: 0
    }

    assert {:ok, _} = Valimc.World.ContainerRequest.encode(key, request)

    assert {:error, :invalid_container_context} =
             Region.admit_container_transfer({pid, epoch}, request, %{
               uuid: request.source,
               mode: :survival
             })

    for position <- [pos, blank] do
      assert {:error, :occupied_container} = World.set_block(position, 0)
    end

    assert Valimc.TestConn.state(pid).resource.containers == containers
    assert :ok = Region.flush(pid)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, {replacement, _}} = World.item_owner(key)
    assert replacement != pid
    assert :sys.get_state(replacement).resource.containers == containers
    assert {:error, :occupied_container} = World.set_block(pos, Data.block("stone"))
  end
end
