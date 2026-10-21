defmodule Valimc.RegionGenerationTest do
  @moduledoc """
  Regions generate their chunks per chunk when wanted, nearest first, off the
  owner, and install them once durable (VMC-075; terrain worlds).
  """
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.{Native, TestScope}
  alias Valimc.World
  alias Valimc.World.{BlockSnapshot, Directory, Generator, Region, RegionGeneration, Store, View}

  @seed 20_261_020

  setup do
    nonce = System.unique_integer([:positive])
    key = {100_000 + rem(nonce, 3_333) * 3, 2_300}
    east = {elem(key, 0) + 1, elem(key, 1)}
    base = Path.join(System.tmp_dir!(), "valimc-per-chunk-#{nonce}")
    # Terrain only: the proto owners of decorated worlds have their own tests.
    :ok = Generator.create(base, @seed, features: false)
    TestScope.isolate([key, east], world_path: base, region_ticks: :manual)

    on_exit(fn ->
      stop([key, east])
      File.rm_rf(base)
    end)

    size = Valimc.config(:region_size)
    %{key: key, east: east, base: base, origin: {elem(key, 0) * size, elem(key, 1) * size}}
  end

  # Gracefully, so final writes finish before the world is removed (VMC-073).
  defp stop(keys), do: Enum.each(keys, &TestScope.stop_neighbourhood/1)

  defp table(key) do
    {_, _, %{items: table}} = Directory.lookup(key)
    table
  end

  # Generated columns as regions store them: each with its light alone (VMC-077c).
  defp columns(chunks),
    do: World.Blocks.lit_images(Generator.columns({:vanilla, @seed}, chunks), true)

  defp column(chunk), do: columns([chunk])[chunk]

  # A block of `chunk` as the generator makes it.
  defp generated_block(chunk, position) do
    {:ok, blocks} = World.Blocks.new(World.region_key(chunk), %{}, %{chunk => column(chunk)})
    World.Blocks.get(blocks, position)
  end

  defp inside({cx, cz}, y \\ 40), do: {cx * 16 + 4, y, cz * 16 + 9}

  # A light image's 24 world sections as {sky, block} nibble arrays.
  defp sections(image), do: image |> decode() |> Enum.slice(1, 24)

  defp decode(<<>>), do: []

  defp decode(bytes) do
    {sky, rest} = take(bytes)
    {block, rest} = take(rest)
    [{sky, block} | decode(rest)]
  end

  defp take(<<1, value, rest::binary>>), do: {:binary.copy(<<value>>, 2048), rest}
  defp take(<<2, data::binary-size(2048), rest::binary>>), do: {data, rest}

  # Light of `chunk` computed from scratch over its generated 3 × 3: light
  # travels at most 15 blocks, so it is exact.
  defp reference_light({cx, cz} = chunk) do
    area = for x <- (cx - 1)..(cx + 1), z <- (cz - 1)..(cz + 1), do: {x, z}
    images = Generator.columns({:vanilla, @seed}, area)
    list = for {{x, z}, image} <- images, do: {x, z, image}
    {:ok, lit} = Native.light_columns(list, cx - 1, cz - 1, 3, 3)
    {_, _, bytes} = Enum.find(lit, fn {x, z, _} -> {x, z} == chunk end)
    for <<sky::binary-size(2048), block::binary-size(2048) <- bytes>>, do: {sky, block}
  end

  defp light_update?(frame) do
    id = Data.id(:play, :clientbound, "light_update")

    case Wire.next_frame(
           IO.iodata_to_binary(frame),
           2_097_152,
           Valimc.config(:compression_threshold)
         ) do
      {:ok, ^id, _payload, <<>>} -> true
      _ -> false
    end
  end

  defp light_updates(chunk, acc \\ 0) do
    receive do
      {:event, {:block_batch, updates}} ->
        found = Enum.count(updates, fn {c, frame} -> c == chunk and light_update?(frame) end)
        light_updates(chunk, acc + found)
    after
      200 -> acc
    end
  end

  test "a region loads without generating and generates the chunk a call needs", ctx do
    {:ok, _} = World.owner(ctx.key)
    {cx, cz} = ctx.origin
    chunk = {cx + 3, cz + 5}
    position = inside(chunk)
    assert Store.durable(ctx.base, ctx.key, :columns) == %{}
    assert BlockSnapshot.absent?(table(ctx.key), chunk)
    assert View.fetch(View.new(), position) == :error

    # A raw read waits for its chunk; only that chunk is generated, equal to
    # the generator's column byte for byte.
    assert Valimc.TestBlocks.get(position) == generated_block(chunk, position)
    assert Store.durable(ctx.base, ctx.key, :columns) == %{chunk => column(chunk)}
    refute BlockSnapshot.absent?(table(ctx.key), chunk)
    assert BlockSnapshot.absent?(table(ctx.key), {cx + 4, cz + 5})

    assert {:ok, block} = View.fetch(View.new(), position)
    assert block == generated_block(chunk, position)

    # A chunk packet waits for its chunk as well.
    frame = World.chunk({cx + 7, cz})
    assert IO.iodata_length(frame) > 0
    assert Map.has_key?(Store.durable(ctx.base, ctx.key, :columns), {cx + 7, cz})
  end

  test "an absent chunk refuses edits and observations until it is generated", ctx do
    {:ok, owner} = World.owner(ctx.key)
    {cx, cz} = ctx.origin
    chunk = {cx + 6, cz + 6}
    position = inside(chunk, 100)
    glass = Valimc.Registry.Blocks.default_state("glass")
    assert Region.set_blocks(owner, 0, %{position => glass}) == {:error, :chunk_generating}

    # The observation wants the chunk.
    assert Region.observe_blocks(owner, [position]) == {:error, :chunk_generating}
    Valimc.TestWait.until(fn -> not BlockSnapshot.absent?(table(ctx.key), chunk) end)
    {:ok, observed} = Region.observe_blocks(owner, [position])
    assert observed.blocks[position] == generated_block(chunk, position)
    {:ok, _} = Region.set_blocks(owner, observed.fence, %{position => glass})
    assert Valimc.TestBlocks.get(position) == glass
  end

  test "a view's ticket generates its chunks; a restart keeps them and the rest stay absent",
       ctx do
    {:ok, {pid, _}} = World.owner(ctx.key)
    {cx, cz} = ctx.origin
    wanted = for x <- cx..(cx + 2), z <- cz..(cz + 2), do: {x, z}
    Region.ticket(pid, :player_loading, {cx, cz}, wanted)

    Valimc.TestWait.until(fn ->
      Enum.all?(wanted, &(not BlockSnapshot.absent?(table(ctx.key), &1)))
    end)

    columns = Store.durable(ctx.base, ctx.key, :columns)
    assert Enum.sort(Map.keys(columns)) == Enum.sort(wanted)
    assert columns == columns(wanted)

    # A withdrawn ticket generates nothing more; an edit over generated terrain is kept.
    Region.ticket(pid, :player_loading, {cx, cz}, [])
    edited = inside({cx + 2, cz + 2}, 20)
    glass = Valimc.Registry.Blocks.default_state("glass")
    :ok = Valimc.TestBlocks.set(edited, glass)
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, _} = World.owner(ctx.key)
    assert Enum.all?(wanted, &(not BlockSnapshot.absent?(table(ctx.key), &1)))
    assert BlockSnapshot.absent?(table(ctx.key), {cx + 5, cz + 5})
    position = inside({cx + 1, cz + 1})
    assert Valimc.TestBlocks.get(position) == generated_block({cx + 1, cz + 1}, position)
    assert Valimc.TestBlocks.get(edited) == glass
    assert Store.durable(ctx.base, ctx.key, :columns) == columns
  end

  test "loading tickets' chunks generate nearest to their center first, urgent ones before all" do
    absent = for x <- 0..7, z <- 0..7, into: MapSet.new(), do: {x, z}
    a = spawn(fn -> Process.sleep(:infinity) end)
    b = spawn(fn -> Process.sleep(:infinity) end)

    tickets =
      Valimc.World.Tickets.new(0)
      |> Valimc.World.Tickets.put(a, :player_loading, {0, 0}, [{3, 3}, {1, 0}, {0, 2}, {7, 7}], 0)
      |> Valimc.World.Tickets.put(b, :forced, {7, 7}, [{6, 7}, {7, 7}], 0)
      |> Valimc.World.Tickets.put(b, :player_simulation, {7, 7}, [{4, 4}], 0)

    gen = %RegionGeneration{
      mode: :terrain,
      absent: absent,
      urgent: MapSet.new([{5, 1}]),
      jobs: %{make_ref() => %{chunks: [{0, 2}]}}
    }

    # {0, 2} is being generated; {7, 7} is nearest to b; simulation does not load.
    assert RegionGeneration.queue(gen, tickets) == [{5, 1}, {7, 7}, {1, 0}, {6, 7}, {3, 3}]
  end

  # A fixed region where the chunk's light provably depends on its neighbours
  # (caves near its borders); only this test uses it.
  @light_key {-30_000, 9_000}

  test "a served chunk's light is corrected when its neighbours generate", ctx do
    TestScope.isolate([@light_key], world_path: ctx.base, region_ticks: :manual)
    on_exit(fn -> stop([@light_key]) end)
    World.subscribe(MapSet.new([@light_key]), MapSet.new())
    {:ok, owner} = World.owner(@light_key)
    {rx, rz} = @light_key
    size = Valimc.config(:region_size)
    chunk = {rx * size + 1, rz * size + 1}
    _ = World.chunk(chunk)
    before = Region.light_image(owner, chunk)
    {cx, cz} = chunk

    neighbours = for x <- (cx - 1)..(cx + 1), z <- (cz - 1)..(cz + 1), {x, z} != chunk, do: {x, z}

    neighbours
    |> Task.async_stream(&Valimc.TestBlocks.get(inside(&1)), timeout: 120_000)
    |> Stream.run()

    # Lit first with its neighbours unknown, then across each face as they
    # arrived, equal to lighting the generated 3 × 3 together; clients got the
    # change.
    lit = Region.light_image(owner, chunk)
    assert lit != before
    assert sections(lit) == reference_light(chunk)
    assert light_updates(chunk) > 0
  end
end
