defmodule Valimc.CookingOrbTransferStoreTest do
  use ExUnit.Case, async: false
  alias Valimc.CookingAwards

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbTransfers,
    CookingOrbs,
    CookingOrbBodies,
    CookingOrbConsumptions,
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

  test "v8 imported launch/expiry survives lost ACK and writer replacement",
       ctx do
    [uuid] = Map.keys(CookingOrbs.records(ctx.id, ctx.request.award))

    {:ok, p} =
      CookingOrbBodies.initialize(ctx.adopted, ctx.dest, ctx.id, %{
        uuid => {{0, 0, 0}, {0.2, 0.7, 0.9}}
      })

    {:ok, initialized, :applied} = CookingOrbBodies.install(ctx.adopted, ctx.dest, p)
    {:ok, taken} = CookingOrbConsumptions.take(initialized, uuid, 3, 0)
    row = taken.orb_bodies.awards[ctx.id][uuid]

    updates = %{
      uuid => %{
        expected_revision: row.revision,
        position: row.position,
        velocity: row.velocity,
        age: 6000,
        on_ground: true
      }
    }

    {:ok, p} = CookingOrbBodies.checkpoint(taken, ctx.dest, updates)
    {:ok, expired, :applied} = CookingOrbBodies.install(taken, ctx.dest, p)
    {writer, lease} = commit_and_crash(ctx.dest, expired)
    assert {:ok, ^expired} = Store.load_containers(writer)
    assert CookingOrbBodies.project(expired)[ctx.id] == %{}

    assert {:ok, ^expired, :already_applied} =
             CookingOrbTransfers.accept(expired, ctx.dest, ctx.request)

    assert :ok = Store.close(writer, lease)
    {:ok, writer, lease} = Store.open(ctx.dest)
    assert {:ok, ^expired} = Store.load_containers(writer)
    assert :ok = Store.close(writer, lease)
  end

  test "destination write failure leaves the source intent and prior destination bytes intact",
       ctx do
    {:ok, source_writer, source_lease} = Store.open(ctx.source)
    assert :ok = Store.flush_containers(source_writer, source_lease, ctx.routed)
    {:ok, writer, lease} = Store.open(ctx.dest)
    assert :ok = Store.flush_containers(writer, lease, %Containers{})
    bytes = Valimc.TestDisk.read(ctx.base, ctx.dest, :containers)
    Valimc.TestDisk.break_writer(writer)
    epoch = make_ref()
    token = make_ref()
    Store.commit_containers(writer, lease, ctx.adopted, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, {:error, _}}}, 1000
    assert {:ok, restored} = Store.load_containers(source_writer)
    assert restored == ctx.routed
    assert {:ok, request} = CookingOrbTransfers.request(restored, ctx.source, ctx.id)
    assert request == ctx.request
    assert Valimc.TestDisk.read(ctx.base, ctx.dest, :containers) == bytes
    Valimc.TestDisk.repair_writer(writer)
    assert {:ok, %Containers{}} = Store.load_containers(writer)
    assert :ok = Store.flush_containers(writer, lease, ctx.adopted)
    assert {:ok, adopted} = Store.load_containers(writer)

    assert {:ok, ^adopted, :already_applied} =
             CookingOrbTransfers.accept(adopted, ctx.dest, request)
  end
end
