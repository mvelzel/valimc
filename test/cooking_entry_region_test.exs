defmodule Valimc.CookingEntryRegionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Cooking, World}
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.{Containers, Region, Store}

  test "cold owners retain mixed cooking entries and refuse raw removal until lifecycle admission exists" do
    nonce = System.unique_integer([:positive])
    key = {84_000 + rem(nonce, 10_000), 1991}
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    pos = {rx * span + 40, 64, rz * span + 40}
    blank = {elem(pos, 0) + 1, 64, elem(pos, 2)}
    base = Path.join(System.tmp_dir!(), "valimc-cooking-entry-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
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
    File.write!(Store.container_path(base, key), bytes)

    edits = %{
      pos => Data.item_block(Data.item("furnace")) - 1,
      blank => Data.item_block(Data.item("smoker"))
    }

    File.write!(
      Path.join(base, "r.#{rx}.#{rz}.etf"),
      :erlang.term_to_binary({:valimc_region, 1, edits})
    )

    {:ok, {pid, _}} = World.item_owner(key)

    for position <- [pos, blank] do
      assert {:error, :occupied_container} = World.set_block(position, 0)
    end

    assert :sys.get_state(pid).resource.containers == containers
    assert :ok = Region.flush(pid)
    assert :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, {replacement, _}} = World.item_owner(key)
    assert replacement != pid
    assert :sys.get_state(replacement).resource.containers == containers
    assert {:error, :occupied_container} = World.set_block(pos, Data.block("stone"))
  end
end
