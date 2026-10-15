defmodule Valimc.MiningStoreTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias Valimc.Protocol.{Data, ItemStack}
  alias Valimc.World.{Chunk, ItemRecords, Items, MiningRecord, Store}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-mining-store-#{nonce}")
    previous = Valimc.config(:world_path)
    Application.put_env(:valimc, :world_path, base)
    key = {10_000 + rem(nonce, 10_000), 300}
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
          do: DynamicSupervisor.terminate_child(Valimc.RegionStoreSupervisor, pid)

      Application.put_env(:valimc, :world_path, previous)
      File.rm_rf!(base)
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

  defp paths(ctx) do
    {rx, rz} = ctx.key

    {Path.join(ctx.base, "r.#{rx}.#{rz}.etf"), Store.item_path(ctx.base, ctx.key),
     Store.mining_path(ctx.base, ctx.key)}
  end

  defp assert_outcome(writer, ctx) do
    assert Store.load(writer) == ctx.proposal.edits
    assert {:ok, %{records: records, receipts: receipts}} = Store.load_items(writer)
    assert records == Items.records(ctx.proposal.items)
    assert receipts == ctx.proposal.receipts
  end

  test "successful mining persists both sides before acknowledgement; later snapshots stay later",
       ctx do
    token = make_ref()
    Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
    assert_receive {:resource, epoch, {:mining_saved, writer, ^token, :ok}}
    assert epoch == ctx.epoch and writer == ctx.writer
    assert_outcome(writer, ctx)
    {_, _, journal} = paths(ctx)
    refute File.exists?(journal)
    assert :ok = Store.close(writer, ctx.lease)
    assert {:ok, writer, lease} = Store.open(ctx.key)
    assert_outcome(writer, ctx)
    later = Map.put(ctx.proposal.edits, ctx.position, Data.block("dirt"))
    assert :ok = Store.flush(writer, lease, later)
    assert :ok = Store.close(writer, lease)
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert Store.load(writer) == later
  end

  test "restart finishes journal before neither, one or both normal files were replaced", ctx do
    {block_path, item_path, journal_path} = paths(ctx)
    old_blocks = File.read!(block_path)
    old_items = File.read!(item_path)

    {:ok, new_items} =
      ItemRecords.encode(ctx.key, Items.records(ctx.proposal.items), ctx.proposal.receipts)

    {:ok, journal} = MiningRecord.encode(ctx.key, ctx.proposal.changes, new_items)
    assert :ok = Store.close(ctx.writer, ctx.lease)

    for boundary <- [:journal_only, :blocks_written, :both_written] do
      File.write!(block_path, old_blocks)
      File.write!(item_path, old_items)
      File.write!(journal_path, journal)

      if boundary != :journal_only,
        do:
          File.write!(block_path, :erlang.term_to_binary({:valimc_region, 1, ctx.proposal.edits}))

      if boundary == :both_written, do: File.write!(item_path, new_items)
      assert {:ok, writer, lease} = Store.open(ctx.key)
      assert_outcome(writer, ctx)
      refute File.exists?(journal_path)
      assert :ok = Store.close(writer, lease)
    end
  end

  test "failed item replacement retains the durable intent and retires the writer before later writes",
       ctx do
    {_, item_path, journal_path} = paths(ctx)
    File.rm!(item_path)
    File.mkdir!(item_path)
    token = make_ref()
    ref = Process.monitor(ctx.writer)

    capture_log(fn ->
      Store.commit_mining(ctx.writer, ctx.lease, ctx.proposal, {self(), ctx.epoch}, token)
      # Same-sender ordering puts this after the transaction; it must never revive the block.
      Store.snapshot(ctx.writer, ctx.lease, ctx.before_edits, {self(), ctx.epoch}, 99)
      assert_receive {:resource, _, {:mining_saved, _, ^token, {:error, _}}}, 1000
      assert_receive {:DOWN, ^ref, :process, _, {:mining_storage_failed, _}}, 1000
    end)

    assert File.regular?(journal_path)
    File.rmdir!(item_path)
    assert {:ok, writer, _} = Store.open(ctx.key)
    assert_outcome(writer, ctx)
    refute File.exists?(journal_path)
  end

  test "corrupt journal blocks acquisition without altering either canonical file", ctx do
    {block_path, item_path, journal_path} = paths(ctx)
    before = {File.read!(block_path), File.read!(item_path)}
    assert :ok = Store.close(ctx.writer, ctx.lease)
    File.write!(journal_path, "corrupt")

    capture_log(fn ->
      assert {:error, {:mining_recovery_failed, :invalid_mining_record}} = Store.open(ctx.key)
    end)

    assert {File.read!(block_path), File.read!(item_path)} == before
    assert File.read!(journal_path) == "corrupt"
  end

  test "stale leases and mismatched block outcomes cannot commit an item ledger", ctx do
    {block_path, item_path, journal_path} = paths(ctx)
    before = {File.read!(block_path), File.read!(item_path)}
    token = make_ref()
    Store.commit_mining(ctx.writer, make_ref(), ctx.proposal, {self(), ctx.epoch}, token)
    assert_receive {:resource, _, {:mining_saved, _, ^token, {:error, :stale_store_lease}}}
    invalid = %{ctx.proposal | edits: ctx.before_edits}
    Store.commit_mining(ctx.writer, ctx.lease, invalid, {self(), ctx.epoch}, token)
    assert_receive {:resource, _, {:mining_saved, _, ^token, {:error, :invalid_mining_proposal}}}
    assert {File.read!(block_path), File.read!(item_path)} == before
    refute File.exists?(journal_path)
    assert Process.alive?(ctx.writer)

    # Returning a placed block to generated air has no sparse edit after recovery.
    {x, _, z} = ctx.position
    default_pos = {x, 64, z}
    assert Chunk.base(64) == 0

    {:ok, items} =
      ItemRecords.encode(ctx.key, Items.records(ctx.proposal.items), ctx.proposal.receipts)

    {:ok, journal} = MiningRecord.encode(ctx.key, %{default_pos => 0}, items)
    assert :ok = Store.close(ctx.writer, ctx.lease)
    File.write!(journal_path, journal)
    assert {:ok, writer, _} = Store.open(ctx.key)
    refute Map.has_key?(Store.load(writer), default_pos)
  end
end
