defmodule Valimc.CookingOrbDeliveryTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  alias Valimc.CookingAwards
  alias Valimc.Protocol.ItemStack
  alias Valimc.World

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbDelivery,
    CookingOrbRuntime,
    CookingOrbTransfers,
    PendingCookingAwards,
    Region,
    RegionData,
    Store
  }

  setup :scope

  def scope(_context) do
    Process.flag(:trap_exit, true)
    nonce = System.unique_integer([:positive])
    source = {110_000 + rem(nonce, 1000), 2291}
    dest = {elem(source, 0) + 1, elem(source, 1)}
    peer = {elem(source, 0) + 2, elem(source, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-orb-delivery-#{nonce}")
    TestScope.isolate(TestScope.neighborhood(dest, 2), world_path: base)
    File.mkdir_p!(base)

    on_exit(fn ->
      for registry <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          key <- [source, dest, peer],
          {pid, _} <- Registry.lookup(registry, key),
          do: TestScope.kill(pid)

      File.rm_rf!(base)
    end)

    %{source: source, dest: dest, peer: peer, base: base, at: at(dest)}
  end

  defp at({x, z}), do: {x * 128 + 8.5, 64.5, z * 128 + 8.5}

  defp award(key, position, state \\ %Containers{}, zero \\ false) do
    recipe =
      if zero, do: "minecraft:smooth_stone", else: "minecraft:gold_ingot_from_smelting_gold_ore"

    {:ok, decision} =
      CookingAwards.plan(
        %{recipe => if(zero, do: 1, else: 6)},
        if(zero, do: %{recipe => 16_777_215}, else: %{})
      )

    n = map_size(state.pending_awards) + 1
    digest = :crypto.hash(:sha256, <<n::32>>)
    source = <<91::128>>

    {:ok, pending, id} =
      PendingCookingAwards.put(state.pending_awards, key, source, n, digest, position, decision)

    {%{
       state
       | pending_awards: pending,
         receipts:
           Map.put(state.receipts, source, %{
             sequence: n,
             digest: ContainerTransfers.result_digest(digest, :applied)
           })
     }, id}
  end

  defp seed(key, cs) do
    {:ok, writer, lease} = Store.open(key)
    :ok = Store.flush_containers(writer, lease, cs)
    :ok = Store.close(writer, lease)
  end

  def fixture(ctx) do
    {cs, id} = award(ctx.source, ctx.at)
    {:ok, routed, request, :prepared} = CookingOrbTransfers.prepare(cs, ctx.source, id)
    seed(ctx.source, routed)
    {routed, request}
  end

  defp start_adoption(state, request, tag) do
    {:ok, bytes} = CookingOrbTransfers.encode_request(request)

    assert {:noreply, next} =
             RegionData.handle_call(
               {:cooking_orb_spawn, state.items.epoch, bytes, now() + 6000},
               {self(), tag},
               state
             )

    next
  end

  defp result(state) do
    %{worker: worker, token: token} = state.cooking_orbs.job
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_orb_plan, ^worker, ^token, _} = message}, 3000
    assert {:noreply, next} = RegionData.handle_info(message, state)
    next
  end

  defp saved(state) do
    token = state.item_pending.token
    epoch = state.items.epoch
    writer = state.store
    assert_receive {:resource, ^epoch, {:containers_saved, ^writer, ^token, _} = message}, 3000
    RegionData.handle_info(message, state)
  end

  defp published(state),
    do:
      :ets.match_object(state.item_publication, {{:orbs, :_}, :_, :_})
      |> Enum.flat_map(fn {_, _, views} -> Map.to_list(views) end)
      |> Map.new()

  def disk(ctx, key),
    do: Containers.decode(Valimc.TestDisk.read(ctx.base, key, :containers), key)

  defp resource(pid), do: Valimc.TestConn.state(pid).resource
  def now, do: System.monotonic_time(:millisecond)

  def wait(fun, left \\ 800) do
    if value = fun.(),
      do: value,
      else:
        (
          assert left > 0
          Process.sleep(10)
          wait(fun, left - 1)
        )
  end

  test "destination rebases concurrent cooking/receipts and exposes no entity or ACK before durability",
       ctx do
    {routed, request} = fixture(ctx)
    seed(ctx.dest, %Containers{})
    state = RegionData.load(ctx.dest)
    tag = make_ref()
    state = start_adoption(state, request, tag)
    assert state.item_pending == nil
    {x, _, z} = ctx.at
    pos = {floor(x), 64, floor(z)}
    {:ok, cs, entry} = Containers.create_cooking(state.containers, ctx.dest, pos, :furnace)
    cooking = %Valimc.Cooking{slots: {ItemStack.new("raw_iron"), nil, nil}, progress: 17}
    {:ok, cs, _} = Containers.replace_cooking(cs, pos, entry.revision, cooking, %{})
    {cs, local} = award(ctx.dest, ctx.at, cs)
    state = %{state | containers: cs, cooking: %{state.cooking | dirty: true}}
    :sys.suspend(state.store)

    try do
      state = result(state)
      assert state.containers === cs and state.item_pending.kind == :cooking_orbs
      assert published(state) == %{}
      refute_receive {^tag, _}, 30
      assert {:ok, %Containers{orb_transfers: %{incoming: incoming}}} = disk(ctx, ctx.dest)
      assert incoming == %{}
      :sys.resume(state.store)
      assert {:noreply, installed} = saved(state)
      assert_receive {^tag, {:ok, :applied}}
      assert installed.containers.entries == cs.entries
      assert installed.containers.pending_awards == cs.pending_awards
      assert installed.containers.receipts == cs.receipts and not installed.cooking.dirty
      assert map_size(published(installed)) == 1
      assert disk(ctx, ctx.source) == {:ok, routed}
      installed = CookingOrbRuntime.tick(installed, now()) |> result()
      {:noreply, installed} = saved(installed)
      assert map_size(installed.containers.cooking_orbs[local]) == 1
      assert map_size(published(installed)) == 2
      before = installed
      tag = make_ref()
      duplicate = start_adoption(installed, request, tag) |> result()
      assert_receive {^tag, {:ok, :already_applied}}
      assert duplicate.item_pending == nil and duplicate.containers == before.containers
      assert duplicate.cooking_orbs.views == before.cooking_orbs.views
      RegionData.terminate(:shutdown, duplicate)
    after
      if Process.alive?(state.store), do: :sys.resume(state.store)
    end
  end

  test "source settlement rebases new awards, typed receipts and cooking progress", ctx do
    {_routed, request} = fixture(ctx)
    {:ok, adopted, _} = CookingOrbTransfers.accept(%Containers{}, ctx.dest, request)
    seed(ctx.dest, adopted)
    state = RegionData.load(ctx.source) |> CookingOrbRuntime.tick(now()) |> result()
    {:ok, digest} = CookingOrbTransfers.digest(request)
    state = put_in(state.cooking_orbs.receipt, {request.id, digest})
    state = CookingOrbRuntime.tick(state, now())
    {x, _, z} = at(ctx.source)
    pos = {floor(x), 64, floor(z)}
    {:ok, cs, entry} = Containers.create_cooking(state.containers, ctx.source, pos, :furnace)
    cooking = %Valimc.Cooking{slots: {ItemStack.new("raw_iron"), nil, nil}, progress: 17}
    {:ok, cs, _} = Containers.replace_cooking(cs, pos, entry.revision, cooking, %{})
    {cs, _} = award(ctx.source, at(ctx.source), cs)
    state = result(%{state | containers: cs, cooking: %{state.cooking | dirty: true}})
    assert state.containers.orb_transfers.outgoing[request.id] == :pending
    {:noreply, settled} = saved(state)
    assert settled.containers.orb_transfers.outgoing[request.id] == :delivered
    assert settled.cooking_orbs.receipt == nil and published(settled) == %{}
    assert settled.containers.pending_awards == cs.pending_awards
    assert settled.containers.receipts == cs.receipts and settled.containers.entries == cs.entries
    assert disk(ctx, ctx.dest) == {:ok, adopted}
    RegionData.terminate(:shutdown, settled)
  end

  test "bounded inbox rejects stale/expired/busy work and late CPU results cannot acknowledge",
       ctx do
    {_routed, request} = fixture(ctx)
    state = RegionData.load(ctx.dest)
    {:ok, bytes} = CookingOrbTransfers.encode_request(request)

    for {epoch, body, deadline, reason} <- [
          {make_ref(), bytes, now() + 6000, :stale_region},
          {state.items.epoch, bytes, now() - 1, :expired_cooking_orb_transfer},
          {state.items.epoch, :binary.copy(<<0>>, 1634), now() + 6000,
           :invalid_cooking_orb_transfer}
        ] do
      assert {:reply, {:error, ^reason}, ^state} =
               CookingOrbRuntime.adopt(state, epoch, body, deadline, nil)
    end

    tag = make_ref()
    working = start_adoption(state, request, tag)

    assert {:reply, {:error, :item_storage_busy}, ^working} =
             CookingOrbRuntime.adopt(working, state.items.epoch, bytes, now() + 6000, nil)

    job = working.cooking_orbs.job
    epoch = state.items.epoch
    assert_receive {:resource, ^epoch, {:cooking_orb_plan, _, _, _} = late}, 3000
    {:noreply, expired} = CookingOrbRuntime.expired(working, job.token)
    assert_receive {^tag, {:error, :cooking_orb_plan_timeout}}
    assert {:noreply, ^expired} = RegionData.handle_info(late, expired)
    assert expired.item_pending == nil and published(expired) == %{}
    tag = make_ref()
    working = start_adoption(expired, request, tag)
    {other_cs, other_id} = award(ctx.source, ctx.at, %Containers{}, true)
    {:ok, _, other, _} = CookingOrbTransfers.prepare(other_cs, ctx.source, other_id)
    {:ok, concurrent, _} = CookingOrbTransfers.accept(working.containers, ctx.dest, other)
    state = result(%{working | containers: concurrent})
    assert_receive {^tag, {:error, :stale_cooking_orb_plan}}

    assert state.containers == concurrent and state.item_pending == nil and
             published(state) == %{}

    RegionData.terminate(:injected, state)
  end

  test "writer failure after adoption durability but before ACK restores only one native effect",
       ctx do
    {routed, request} = fixture(ctx)
    state = RegionData.load(ctx.dest)
    tag = make_ref()
    state = start_adoption(state, request, tag) |> result()
    writer = state.store
    monitor = state.store_monitor
    assert {:ok, committed} = Store.load_containers(writer)
    assert committed == state.item_pending.containers and published(state) == %{}
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^writer, :killed} = message
    assert {:stop, {:store_failed, :killed}, stopped} = RegionData.handle_info(message, state)
    RegionData.terminate(:injected, stopped)
    assert_receive {^tag, {:error, :item_commit_uncertain}}
    restored = RegionData.load(ctx.dest) |> CookingOrbRuntime.tick(now()) |> result()
    assert restored.containers == committed and map_size(published(restored)) == 1
    tag = make_ref()
    restored = start_adoption(restored, request, tag) |> result()
    assert_receive {^tag, {:ok, :already_applied}}
    assert restored.item_pending == nil and disk(ctx, ctx.source) == {:ok, routed}
    RegionData.terminate(:shutdown, restored)
  end

  test "destination I/O refusal sends no successful ACK and leaves source retry intent intact",
       ctx do
    {routed, request} = fixture(ctx)
    state = RegionData.load(ctx.dest)
    tag = make_ref()
    state = start_adoption(state, request, tag)
    Valimc.TestDisk.break_writer(state.store)
    state = result(state)
    assert {:stop, {:cooking_orb_storage_failed, _}, stopped} = saved(state)
    assert_receive {^tag, {:error, :cooking_orb_commit_uncertain}}
    assert published(stopped) == %{} and disk(ctx, ctx.source) == {:ok, routed}
    RegionData.terminate(:injected, stopped)
  end

  test "simultaneous opposite deliveries including zero XP settle without an owner deadlock",
       ctx do
    {a, aid} = award(ctx.source, ctx.at)
    {b, bid} = award(ctx.dest, at(ctx.source), %Containers{}, true)
    seed(ctx.source, a)
    seed(ctx.dest, b)
    {:ok, {ap, ae}} = World.item_owner(ctx.source)
    {:ok, {bp, be}} = World.item_owner(ctx.dest)

    wait(fn ->
      resource(ap).containers.orb_transfers.outgoing[aid] == :delivered and
        resource(bp).containers.orb_transfers.outgoing[bid] == :delivered
    end)

    ar = resource(ap)
    br = resource(bp)

    assert ar.containers.pending_awards == a.pending_awards and
             br.containers.pending_awards == b.pending_awards

    assert ar.cooking_orbs.views == %{} and map_size(br.cooking_orbs.views) == 1
    assert map_size(ar.cooking_orbs.ledger) == 1
    assert ar.containers.cooking_orbs == %{} and br.containers.cooking_orbs == %{}
    before = br.cooking_orbs.views
    request = br.containers.orb_transfers.incoming[aid]
    {:ok, bytes} = CookingOrbTransfers.encode_request(request)
    assert {:ok, :already_applied} = Region.apply_cooking_orb_spawn({bp, be}, bytes)
    assert resource(bp).cooking_orbs.views == before
    assert {:error, :stale_region} = Region.apply_cooking_orb_spawn({bp, ae}, bytes)
    for pid <- [ap, bp], do: Process.exit(pid, :kill)
    wait(fn -> not Process.alive?(ap) and not Process.alive?(bp) end)
    {:ok, {ap2, _}} = World.item_owner(ctx.source)
    {:ok, {bp2, _}} = World.item_owner(ctx.dest)
    wait(fn -> map_size(resource(bp2).cooking_orbs.views) == 1 end)
    assert resource(ap2).containers == ar.containers and resource(bp2).containers == br.containers

    assert MapSet.new(for {_, v} <- before, do: v.uuid) ==
             MapSet.new(for {_, v} <- resource(bp2).cooking_orbs.views, do: v.uuid)

    assert MapSet.disjoint?(
             MapSet.new(Map.keys(before)),
             MapSet.new(Map.keys(resource(bp2).cooking_orbs.views))
           )
  end

  test "source death while destination writes loses its ACK but replay preserves the same native entity",
       ctx do
    {a, id} = award(ctx.source, ctx.at)
    seed(ctx.source, a)
    {:ok, {bp, _}} = World.item_owner(ctx.dest)
    writer = resource(bp).store
    :sys.suspend(writer)

    try do
      {:ok, {ap, _}} = World.item_owner(ctx.source)
      wait(fn -> match?(%{kind: :cooking_orbs}, resource(bp).item_pending) end)
      source = resource(ap)
      assert source.item_pending == nil and source.cooking_orbs.delivery != nil
      assert source.containers.orb_transfers.outgoing[id] == :pending
      assert source.cooking_orbs.views == %{}
      worker = source.cooking_orbs.delivery.worker
      Process.exit(ap, :kill)
      wait(fn -> not Process.alive?(ap) and not Process.alive?(worker) end)
      :sys.resume(writer)
      wait(fn -> map_size(resource(bp).cooking_orbs.views) == 1 end)
      views = resource(bp).cooking_orbs.views
      {:ok, {ap2, _}} = World.item_owner(ctx.source)
      wait(fn -> resource(ap2).containers.orb_transfers.outgoing[id] == :delivered end)
      assert resource(bp).cooking_orbs.views == views
      assert resource(ap2).containers.pending_awards == a.pending_awards
      assert resource(ap2).cooking_orbs.views == %{}
    after
      if Process.alive?(writer), do: :sys.resume(writer)
    end
  end

  test "a full destination retains its intent while another destination makes progress", ctx do
    origin = {elem(ctx.source, 0) - 2, elem(ctx.source, 1)}

    {original, imports} =
      Enum.reduce(1..256, {%Containers{}, %{}}, fn _, {cs, imports} ->
        {cs, id} = award(origin, ctx.at, cs)
        request = %{source: origin, destination: ctx.dest, id: id, award: cs.pending_awards[id]}
        {cs, Map.put(imports, id, request)}
      end)

    original = %{
      original
      | orb_transfers: %{
          revision: 512,
          incoming: %{},
          outgoing: Map.new(imports, fn {id, _} -> {id, :delivered} end)
        }
    }

    {:ok, bytes} = Containers.encode(origin, original)
    Valimc.TestDisk.write(ctx.base, origin, :containers, bytes)
    full = %Containers{orb_transfers: %{revision: 256, outgoing: %{}, incoming: imports}}
    seed(ctx.dest, full)
    {cs, blocked} = award(ctx.source, ctx.at)
    {cs, available} = award(ctx.source, at(ctx.peer), cs)
    seed(ctx.source, cs)
    {:ok, {ap, _}} = World.item_owner(ctx.source)
    {:ok, {bp, be}} = World.item_owner(ctx.dest)
    {:ok, {cp, _}} = World.item_owner(ctx.peer)

    wait(fn ->
      r = resource(ap)

      r.containers.orb_transfers.outgoing[blocked] == :pending and
        r.containers.orb_transfers.outgoing[available] == :delivered and
        r.cooking_orbs.delivery_cursor == blocked and is_integer(r.cooking_orbs.delivery_retry_at)
    end)

    assert resource(bp).containers == full
    assert map_size(resource(cp).containers.orb_transfers.incoming) == 1
    assert map_size(resource(cp).cooking_orbs.views) == 1
    assert resource(ap).containers.pending_awards == cs.pending_awards
    assert resource(ap).cooking_orbs.views == %{}
    {:ok, request} = CookingOrbTransfers.request(resource(ap).containers, ctx.source, blocked)
    {:ok, bytes} = CookingOrbTransfers.encode_request(request)

    assert {:error, :cooking_orb_transfer_capacity} =
             Region.apply_cooking_orb_spawn({bp, be}, bytes)
  end
end

defmodule Valimc.CookingOrbDeliveryTest.Serial do
  use ExUnit.Case, async: false
  # Serial: saturates a global worker pool that concurrent owners also use.
  import Valimc.CookingOrbDeliveryTest, only: [fixture: 1, disk: 2, now: 0, wait: 1]
  alias Valimc.World
  alias Valimc.World.{CookingOrbDelivery, RegionData}

  setup {Valimc.CookingOrbDeliveryTest, :scope}

  test "transfer worker saturation, failed attempts and late results preserve durable intent",
       ctx do
    {routed, _request} = fixture(ctx)
    state = RegionData.load(ctx.source)

    workers =
      for _ <- 1..(System.schedulers_online() * 4) do
        {:ok, pid} =
          Task.Supervisor.start_child(Valimc.TransferWorkers, fn ->
            receive do: (:finish -> :ok)
          end)

        pid
      end

    try do
      backed = CookingOrbDelivery.tick(state, now())
      assert backed.cooking_orbs.delivery == nil and backed.cooking_orbs.delivery_retry_at > now()
      assert backed.item_pending == nil and disk(ctx, ctx.source) == {:ok, routed}
    after
      for pid <- workers, do: send(pid, :finish)
    end

    wait(fn -> Enum.all?(workers, &(not Process.alive?(&1))) end)
    {:ok, {bp, _}} = World.item_owner(ctx.dest)
    Valimc.TestRegionGate.stall(bp)

    try do
      working = CookingOrbDelivery.tick(state, now())
      job = working.cooking_orbs.delivery
      {:noreply, expired} = CookingOrbDelivery.expired(working, job.token)
      assert expired.cooking_orbs.receipt == nil and expired.cooking_orbs.delivery == nil

      assert {:noreply, ^expired} =
               CookingOrbDelivery.returned(
                 expired,
                 job.worker,
                 job.token,
                 {:ok, job.id, <<0::256>>}
               )

      assert disk(ctx, ctx.source) == {:ok, routed}
      RegionData.terminate(:shutdown, expired)
    after
      Valimc.TestRegionGate.resume(bp)
    end
  end
end
