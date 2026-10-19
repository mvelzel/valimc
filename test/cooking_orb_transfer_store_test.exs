defmodule Valimc.CookingOrbTransferStoreTest do
  use ExUnit.Case, async: false
  alias Valimc.CookingAwards
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbTransfers,
    ItemLedger,
    Items,
    MiningRecord,
    PendingCookingAwards,
    Store
  }

  setup do
    nonce = System.unique_integer([:positive])
    source = {31_000 + rem(nonce, 1000), 1191}
    dest = {elem(source, 0) + 1, 1191}
    base = Path.join(System.tmp_dir!(), "valimc-orb-transfer-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    File.mkdir_p!(base)
    player = <<71::128>>
    digest = :crypto.hash(:sha256, "remote XP fixture")

    {:ok, decision} =
      CookingAwards.plan(%{"minecraft:gold_ingot_from_smelting_gold_ore" => 6}, %{})

    position = {elem(dest, 0) * 128 + 0.5, 64.25, elem(dest, 1) * 128 + 0.5}

    {:ok, awards, id} =
      PendingCookingAwards.put(%{}, source, player, 1, digest, position, decision)

    original = %Containers{
      pending_awards: awards,
      receipts: %{
        player => %{sequence: 1, digest: ContainerTransfers.result_digest(digest, :applied)}
      }
    }

    {:ok, routed, request, _} = CookingOrbTransfers.prepare(original, source, id)
    {:ok, adopted, _} = CookingOrbTransfers.accept(%Containers{}, dest, request)

    on_exit(fn ->
      for key <- [source, dest],
          {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
    end)

    %{
      source: source,
      dest: dest,
      base: base,
      id: id,
      original: original,
      routed: routed,
      request: request,
      adopted: adopted
    }
  end

  defp commit_and_crash(key, containers) do
    {:ok, writer, lease} = Store.open(key)
    epoch = make_ref()
    token = make_ref()
    Store.commit_containers(writer, lease, containers, {self(), epoch}, token)
    # Same-sender ordering proves durability; leave the success ACK unread.
    assert {:ok, ^containers} = Store.load_containers(writer)
    monitor = Process.monitor(writer)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed}, 1000
    {:ok, replacement, next_lease} = Store.open(key)
    assert {:ok, ^containers} = Store.load_containers(replacement)

    assert {:error, :stale_store_lease} =
             Store.flush_containers(replacement, lease, %Containers{})

    assert {:ok, ^containers} = Store.load_containers(replacement)
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, :ok}}
    {replacement, next_lease}
  end

  test "lost endpoint ACKs and writer replacement cannot duplicate adoption or forget routing",
       ctx do
    {source_writer, source_lease} = commit_and_crash(ctx.source, ctx.routed)
    {:ok, restored_source} = Store.load_containers(source_writer)
    assert {:ok, request} = CookingOrbTransfers.request(restored_source, ctx.source, ctx.id)
    assert request == ctx.request
    {dest_writer, dest_lease} = commit_and_crash(ctx.dest, ctx.adopted)
    {:ok, restored_dest} = Store.load_containers(dest_writer)

    assert {:ok, ^restored_dest, :already_applied} =
             CookingOrbTransfers.accept(restored_dest, ctx.dest, request)

    assert {:ok, digest} = CookingOrbTransfers.digest(request)

    assert {:ok, done, :delivered} =
             CookingOrbTransfers.acknowledge(restored_source, ctx.source, ctx.id, digest)

    assert done.pending_awards == ctx.original.pending_awards and done.cooking_orbs == %{}
    assert :ok = Store.flush_containers(source_writer, source_lease, done)
    assert :ok = Store.close(source_writer, source_lease)
    {:ok, source_writer, source_lease} = Store.open(ctx.source)
    assert {:ok, ^done} = Store.load_containers(source_writer)

    assert {:ok, ^done, :already_delivered} =
             CookingOrbTransfers.acknowledge(done, ctx.source, ctx.id, digest)

    assert :ok = Store.close(source_writer, source_lease)
    assert :ok = Store.close(dest_writer, dest_lease)
  end

  test "destination write failure leaves the source intent and prior destination bytes intact",
       ctx do
    {:ok, source_writer, source_lease} = Store.open(ctx.source)
    assert :ok = Store.flush_containers(source_writer, source_lease, ctx.routed)
    {:ok, writer, lease} = Store.open(ctx.dest)
    path = Store.container_path(ctx.base, ctx.dest)
    assert :ok = Store.flush_containers(writer, lease, %Containers{})
    bytes = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    epoch = make_ref()
    token = make_ref()
    Store.commit_containers(writer, lease, ctx.adopted, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, {:error, _}}}, 1000
    assert {:ok, restored} = Store.load_containers(source_writer)
    assert restored == ctx.routed
    assert {:ok, request} = CookingOrbTransfers.request(restored, ctx.source, ctx.id)
    assert request == ctx.request
    File.rmdir!(path)
    File.write!(path, bytes)
    assert {:ok, %Containers{}} = Store.load_containers(writer)
    assert :ok = Store.flush_containers(writer, lease, ctx.adopted)
    assert {:ok, adopted} = Store.load_containers(writer)

    assert {:ok, ^adopted, :already_applied} =
             CookingOrbTransfers.accept(adopted, ctx.dest, request)
  end

  test "joint recovery repairs every interrupted block/item/v6 replacement subset at either endpoint",
       ctx do
    for {key, before_cs, after_cs} <- [
          {ctx.source, ctx.original, ctx.routed},
          {ctx.dest, %Containers{}, ctx.adopted}
        ] do
      {rx, rz} = key
      position = {rx * 128 + 2, 63, rz * 128 + 2}
      edits = %{position => 0}
      block_path = Path.join(ctx.base, "r.#{rx}.#{rz}.etf")
      item_path = Store.item_path(ctx.base, key)
      container_path = Store.container_path(ctx.base, key)
      journal_path = Store.mining_path(ctx.base, key)
      {:ok, before_containers} = Containers.encode(key, before_cs)
      {:ok, after_containers} = Containers.encode(key, after_cs)
      {:ok, empty_items} = ItemLedger.encode(key, [], %{})

      {:ok, items, _} =
        Items.create(
          Items.new(),
          key,
          ItemStack.new("dirt"),
          {rx * 128 + 2.5, 64.0, rz * 128 + 2.5}
        )

      records = Items.records(items)
      {:ok, item_bytes} = ItemLedger.encode(key, records, %{})
      {:ok, journal} = MiningRecord.encode(key, edits, item_bytes, after_containers)

      before_bytes = [
        :erlang.term_to_binary({:valimc_region, 1, %{}}),
        empty_items,
        before_containers
      ]

      after_bytes = [
        :erlang.term_to_binary({:valimc_region, 1, edits}),
        item_bytes,
        after_containers
      ]

      paths = [block_path, item_path, container_path]

      for subset <- 0..7 do
        # Restore the complete stopped dataset before injecting one crash boundary.
        for {path, old, new, bit} <- Enum.zip([paths, before_bytes, after_bytes, [0, 1, 2]]) do
          File.write!(
            path,
            if(Bitwise.band(subset, Bitwise.bsl(1, bit)) == 0, do: old, else: new)
          )
        end

        File.write!(journal_path, journal)
        {:ok, writer, lease} = Store.open(key)
        assert Store.load(writer) == edits
        assert Store.load_containers(writer) == {:ok, after_cs}
        assert {:ok, %{records: ^records}} = Store.load_items(writer)
        refute File.exists?(journal_path)
        assert :ok = Store.close(writer, lease)
      end
    end
  end
end
