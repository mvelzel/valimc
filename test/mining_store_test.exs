defmodule Valimc.MiningStoreTest do
  use ExUnit.Case, async: true
  alias Valimc.TestScope
  import ExUnit.CaptureLog
  alias Valimc.Protocol.{Data, ItemStack}

  alias Valimc.World.{
    Containers,
    Items,
    Store
  }

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-store-#{nonce}")
    key = {10_000 + rem(nonce, 3_333) * 3, 300}
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

  test "joint block/items/container commit acknowledges all outputs and survives writer replacement",
       ctx do
    ctx = container_proposal(ctx)
    token = make_ref()
    Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
    assert_receive {:resource, _, {:mining_saved, _, ^token, :ok}}
    assert_outcome(ctx.writer, ctx)
    assert Store.load_containers(ctx.writer) == {:ok, ctx.proposal.containers}
    monitor = Process.monitor(ctx.writer)
    Process.exit(ctx.writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert_outcome(writer, ctx)
    assert Store.load_containers(writer) == {:ok, ctx.proposal.containers}
  end

  test "a failed joint write changes no output and retires its writer", ctx do
    ctx = container_proposal(ctx)
    before = durable(ctx)
    {:ok, containers} = Store.load_containers(ctx.writer)
    Valimc.TestDisk.break_writer(ctx.writer)
    token = make_ref()
    monitor = Process.monitor(ctx.writer)

    capture_log(fn ->
      Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
      assert_receive {:resource, _, {:mining_saved, _, ^token, {:error, _}}}
      assert_receive {:DOWN, ^monitor, :process, _, {:storage_failed, _}}
    end)

    assert durable(ctx) == before
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert Store.load(writer) == hd(before)
    assert Store.load_containers(writer) == {:ok, containers}
  end
end
