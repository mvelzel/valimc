defmodule Valimc.MiningStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  import ExUnit.CaptureLog
  alias Valimc.Protocol.{Data, ItemStack}

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    CookingBatch,
    Items,
    Store
  }

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-store-#{nonce}")
    key = {10_000 + rem(nonce, 10_000), 300}
    TestScope.isolate(key, world_path: base)
    {rx, rz} = key
    span = Valimc.config(:region_size) * 16
    position = {rx * span, 63, rz * span}
    other = {rx * span + 1, 63, rz * span}
    source = <<nonce::128>>
    receipt = %{source => %{sequence: 1, digest: :crypto.hash(:sha256, "before")}}
    next_receipt = %{source => %{sequence: 2, digest: :crypto.hash(:sha256, "mined")}}
    {:ok, writer, lease} = Store.open(key)
    edits = %{position => Data.block("stone"), other => Data.block("bedrock")}
    assert :ok = Store.flush(writer, lease, edits)
    epoch = make_ref()
    token = make_ref()
    old_items = Items.new()
    Store.commit_items(writer, lease, old_items, receipt, {self(), epoch}, token)
    assert_receive {:resource, ^epoch, {:items_saved, ^writer, ^token, :ok}}
    {x, _, z} = position

    {:ok, items, _} =
      Items.create(old_items, key, ItemStack.new("cobblestone"), {x + 0.5, 63.5, z + 0.5})

    on_exit(fn ->
      for {pid, _} <- Registry.lookup(Valimc.RegionStoreRegistry, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    %{
      base: base,
      key: key,
      writer: writer,
      lease: lease,
      epoch: epoch,
      position: position,
      other: other,
      before_edits: edits,
      proposal: %{
        edits: Map.put(edits, position, 0),
        changes: %{position => 0},
        items: items,
        receipts: next_receipt
      }
    }
  end

  defp durable(ctx) do
    for part <- [:blocks, :items, :containers], do: Valimc.TestDisk.read(ctx.base, ctx.key, part)
  end

  defp assert_outcome(writer, ctx) do
    assert Store.load(writer) == ctx.proposal.edits
    assert {:ok, %{records: records, receipts: receipts}} = Store.load_items(writer)
    assert records == Items.records(ctx.proposal.items)
    assert receipts == ctx.proposal.receipts
  end

  defp container_proposal(ctx) do
    chest = hd(JSON.decode!(File.read!("priv/protocol/chest_states.json"))["single_states"])
    before_blocks = Map.put(ctx.before_edits, ctx.position, chest)
    :ok = Store.flush(ctx.writer, ctx.lease, before_blocks)
    {:ok, containers, entry} = Containers.create(%Containers{}, ctx.key, ctx.position, 3)
    slots = put_elem(entry.slots, 0, ItemStack.new("diamond", 3))
    {:ok, containers, entry} = Containers.replace(containers, ctx.position, entry.revision, slots)
    :ok = Store.flush_containers(ctx.writer, ctx.lease, containers)
    {:ok, after_containers, _} = Containers.remove(containers, ctx.position, entry.revision)
    {x, y, z} = ctx.position

    {:ok, items, _} =
      Items.create(Items.new(), ctx.key, ItemStack.new("chest"), {x + 0.5, y + 0.5, z + 0.5})

    {:ok, items, _} =
      Items.create(items, ctx.key, ItemStack.new("diamond", 3), {x + 0.25, y + 0.5, z + 0.5})

    proposal = ctx.proposal |> Map.put(:containers, after_containers) |> Map.put(:items, items)
    %{ctx | proposal: proposal}
  end

  defp cooking_proposal(ctx) do
    block = Data.item_block(Data.item("furnace"))
    before_blocks = Map.put(ctx.before_edits, ctx.position, block)
    :ok = Store.flush(ctx.writer, ctx.lease, before_blocks)

    {:ok, containers, entry} =
      Containers.create_cooking(%Containers{}, ctx.key, ctx.position, :furnace)

    fuel = %{ItemStack.new("lava_bucket", 2) | components: %{"minecraft:max_stack_size" => 99}}

    initial = %Valimc.Cooking{
      slots: {ItemStack.new("raw_iron", 2), fuel, nil},
      progress: 199,
      total: 200
    }

    {:ok, recipe} = Valimc.CookingRecipes.find(elem(initial.slots, 0), block)
    source = ctx.proposal.receipts |> Map.keys() |> hd()
    typed = %{source => %{sequence: 77, digest: :crypto.hash(:sha256, "cooking-typed")}}
    containers = %{containers | receipts: typed}

    {:ok, containers, _entry} =
      Containers.replace_cooking(containers, ctx.position, entry.revision, initial, %{
        recipe.key => 42
      })

    :ok = Store.flush_containers(ctx.writer, ctx.lease, containers)

    {:ok, plan} =
      CookingBatch.plan(containers, Items.new(), ctx.key, %{ctx.position => block})

    assert plan.refused == %{}
    assert plan.containers.entries[ctx.position].recipes == %{recipe.key => 43}
    assert [%{stack: bucket}] = Items.records(plan.items)
    assert bucket == ItemStack.new("bucket")
    {:ok, %{receipts: original_receipts}} = Store.load_items(ctx.writer)

    # Native26.3 tick fixture: north-facing furnace6884 unlit /6883 lit.
    6884 = block
    lit_block = 6883

    proposal = %{
      ctx.proposal
      | edits: Map.put(before_blocks, ctx.position, lit_block),
        changes: plan.changes,
        items: plan.items,
        receipts: original_receipts
    }

    assert plan.changes == %{ctx.position => lit_block}
    %{ctx | proposal: Map.put(proposal, :containers, plan.containers)}
  end

  defp cooking_award_proposal(ctx) do
    block = Data.item_block(Data.item("furnace"))
    :ok = Store.flush(ctx.writer, ctx.lease, Map.put(ctx.before_edits, ctx.position, block))
    source = <<96::128>>
    recipe = "minecraft:iron_ingot_from_smelting_raw_iron"
    {:ok, cs, entry} = Containers.create_cooking(%Containers{}, ctx.key, ctx.position, :furnace)
    cooking = %Valimc.Cooking{slots: {nil, nil, ItemStack.new("iron_ingot", 4)}, total: 200}

    {:ok, cs, entry} =
      Containers.replace_cooking(cs, ctx.position, entry.revision, cooking, %{recipe => 7})

    {:ok, cs, _} = ContainerTransfers.reserve(cs, source)

    request = %{
      source: source,
      sequence: 1,
      permit: <<97::128>>,
      position: ctx.position,
      revision: entry.revision,
      kind: :furnace,
      slots: cooking.slots,
      inventory: %Valimc.Inventory{},
      action: :pickup,
      slot: 2,
      button: 1
    }

    {x, y, z} = ctx.position
    context = %{position: {x + 0.5, y * 1.0, z + 0.5}, draws: %{recipe => 0}}

    {:ok, %{containers: cs, result: :applied}} =
      ContainerTransfers.plan_cooking_award(cs, ctx.key, request, true, context)

    :ok = Store.flush_containers(ctx.writer, ctx.lease, cs)
    {:ok, next, _} = Containers.remove(cs, ctx.position, cs.entries[ctx.position].revision)
    assert next.pending_awards == cs.pending_awards

    {:ok, items, _} =
      Items.create(Items.new(), ctx.key, ItemStack.new("furnace"), {x + 0.5, y + 0.5, z + 0.5})

    {:ok, items, _} =
      Items.create(items, ctx.key, ItemStack.new("iron_ingot", 2), {x + 0.25, y + 0.5, z + 0.5})

    %{ctx | proposal: ctx.proposal |> Map.put(:containers, next) |> Map.put(:items, items)}
  end

  test "joint block/items/container commit acknowledges all outputs and survives writer replacement",
       ctx do
    ctx = container_proposal(ctx)
    token = make_ref()
    Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
    assert_receive {:resource, _, {:mining_saved, _, ^token, :ok}}, 1000
    assert_outcome(ctx.writer, ctx)
    assert Store.load_containers(ctx.writer) == {:ok, ctx.proposal.containers}
    monitor = Process.monitor(ctx.writer)
    Process.exit(ctx.writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1000
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert_outcome(writer, ctx)
    assert Store.load_containers(writer) == {:ok, ctx.proposal.containers}
  end

  for kind <- [:cooking, :cooking_award, :cooking_orbs] do
    test "joint #{kind} commit is recovered whole after writer replacement", ctx do
      ctx =
        case unquote(kind) do
          :cooking ->
            cooking_proposal(ctx)

          :cooking_award ->
            cooking_award_proposal(ctx)

          :cooking_orbs ->
            ctx = cooking_award_proposal(ctx)
            [id] = Map.keys(ctx.proposal.containers.pending_awards)

            {:ok, containers, :materialized} =
              CookingOrbs.materialize(ctx.proposal.containers, ctx.key, id)

            put_in(ctx.proposal.containers, containers)
        end

      token = make_ref()
      Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
      assert_receive {:resource, _, {:mining_saved, _, ^token, :ok}}, 1000
      assert :ok = Store.close(ctx.writer, ctx.lease)
      assert {:ok, writer, lease} = Store.open(ctx.key)
      assert_outcome(writer, ctx)
      assert Store.load_containers(writer) == {:ok, ctx.proposal.containers}
      assert :ok = Store.close(writer, lease)
    end
  end

  test "a failed joint write changes no output and retires its writer", ctx do
    ctx = cooking_award_proposal(ctx)
    [id] = Map.keys(ctx.proposal.containers.pending_awards)

    {:ok, materialized, :materialized} =
      CookingOrbs.materialize(ctx.proposal.containers, ctx.key, id)

    ctx = put_in(ctx.proposal.containers, materialized)
    before = durable(ctx)
    {:ok, containers} = Store.load_containers(ctx.writer)
    Valimc.TestDisk.break_writer(ctx.writer)
    token = make_ref()
    monitor = Process.monitor(ctx.writer)

    capture_log(fn ->
      Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
      assert_receive {:resource, _, {:mining_saved, _, ^token, {:error, _}}}, 1000
      assert_receive {:DOWN, ^monitor, :process, _, {:storage_failed, _}}, 1000
    end)

    assert durable(ctx) == before
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert Store.load(writer) == hd(before)
    assert Store.load_containers(writer) == {:ok, containers}
  end

  test "an invalid container proposal cannot change any of the three outputs", ctx do
    ctx = container_proposal(ctx)
    before = durable(ctx)
    token = make_ref()

    Store.commit_mining(
      ctx.writer,
      ctx.lease,
      %{ctx.proposal | containers: :invalid},
      {self(), ctx.epoch},
      token
    )

    assert_receive {:resource, _, {:mining_saved, _, ^token, {:error, :invalid_mining_proposal}}},
                   1000

    assert durable(ctx) == before
    assert Process.alive?(ctx.writer)
  end
end
