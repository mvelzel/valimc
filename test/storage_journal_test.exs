defmodule Valimc.StorageJournalTest do
  @moduledoc """
  Frames from journals (VMC-081h): a section's frames write the records its
  store's and ticks' journals named, so what its log holds is its state. An
  owner killed once its frames are durable reloads exactly what it held; one
  killed while its frames wait for the disk reloads the state after one of
  its changes, never part of one. (Every test also checks each journal
  against a whole comparison in the test build.)
  """
  use ExUnit.Case, async: true
  @moduletag capture_log: true
  alias Valimc.Data.Blocks, as: BlockRegistry
  alias Valimc.Protocol.ItemStack
  alias Valimc.TestScope
  alias Valimc.World.{Region, RegionStorage, ScheduledTicks}

  setup do
    nonce = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "valimc-journal-#{nonce}")
    key = {40_000 + rem(nonce, 3_333) * 3, 1700}
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for {pid, _} <- Valimc.TestWorld.registered(key), do: TestScope.kill(pid)
      File.rm_rf(base)
    end)

    {:ok, owner} = Valimc.TestWorld.item_owner(key)
    TestScope.simulate(owner, key)
    {rx, rz} = key
    %{base: base, key: key, owner: owner, origin: {rx * 128, rz * 128}}
  end

  # Items made, restacked and taken, water placed and flowing: each change
  # one call, and the live records after each.
  defp changes(ctx, rounds, seed) do
    :rand.seed(:exsss, {seed, seed, seed})
    {ox, oz} = ctx.origin
    water = BlockRegistry.default_state("water")

    Enum.reduce(1..rounds, {[], [live(ctx)]}, fn n, {handles, states} ->
      handles =
        case {:rand.uniform(5), handles} do
          {k, _} when k <= 2 or handles == [] ->
            position = {ox + :rand.uniform(120) + 0.5, 64.5, oz + :rand.uniform(120) + 0.5}
            {:ok, handle} = Region.create_item(ctx.owner, ItemStack.new("stone", n), position)
            [handle | handles]

          {3, [handle | rest]} ->
            {:ok, next} = Region.replace_item(handle, ItemStack.new("dirt", rem(n, 60) + 1))
            [next | rest]

          {4, [handle | rest]} ->
            :ok = Region.remove_item(handle)
            rest

          {5, _} ->
            at = {ox + :rand.uniform(120), 64, oz + :rand.uniform(120)}
            {:ok, observed} = Region.observe_blocks(ctx.owner, [at])
            {:ok, _} = Region.set_blocks(ctx.owner, observed.fence, %{at => water})
            {:ok, _} = Region.step(ctx.owner, 3)
            handles
        end

      {handles, [live(ctx) | states]}
    end)
    |> elem(1)
  end

  # The entity and tick records the section holds now.
  defp live(ctx) do
    section = Valimc.TestRegion.section(ctx.owner)
    ticks = section.scheduled_ticks

    entities =
      for {{:entity, _} = key, record} <-
            RegionStorage.part_records(:items, section.entities.store),
          into: %{},
          do: {key, record}

    for chunk <- ScheduledTicks.chunks(ticks),
        into: entities,
        do: {{:ticks, chunk}, ScheduledTicks.chunk_record(ticks, chunk)}
  end

  # The entity and tick records the checkpoint and log hold.
  defp durable(ctx) do
    {:ok, _seq, records} = RegionStorage.records(ctx.base, :overworld, ctx.key)

    for {{kind, part} = key, record} <- records,
        kind in [:entity, :ticks] and part != :shift,
        into: %{},
        do: {key, record}
  end

  defp settled?(ctx) do
    section = Valimc.TestRegion.section(ctx.owner)
    storage = section.storage

    storage.pending == %{} and storage.outbox == [] and storage.in_flight == %{} and
      storage.deferred == %{} and section.entities.store.dirty == %{} and
      section.scheduled_ticks.dirty == %{}
  end

  test "an owner killed once its frames are durable reloads exactly what it held", ctx do
    [last | _] = changes(ctx, 40, 1)
    assert Enum.any?(Map.keys(last), &match?({:entity, _}, &1))
    assert Enum.any?(Map.keys(last), &match?({:ticks, _}, &1))
    Valimc.TestWait.until(fn -> settled?(ctx) end)
    TestScope.kill(elem(ctx.owner, 0))

    assert durable(ctx) == last
  end

  test "an owner killed while its frames wait for the disk reloads one of its states", ctx do
    stripe = Valimc.TestDisk.stripe(ctx.base, ctx.key)
    :sys.suspend(stripe)

    # Killed right after its last change, while a commit may be cutting.
    states =
      try do
        states = changes(ctx, 20 + rem(System.unique_integer([:positive]), 20), 2)
        TestScope.kill(elem(ctx.owner, 0))
        states
      after
        :sys.resume(stripe)
      end

    :ok = Valimc.Storage.Log.sync(ctx.base, {:region, :overworld, ctx.key})
    durable = durable(ctx)
    assert durable in states
  end
end
