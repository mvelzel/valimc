defmodule Valimc.RegionLightTest do
  @moduledoc "Region owners keep vanilla light current and send it (VMC-022c)."
  use ExUnit.Case, async: true
  import Bitwise
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.Registry.Blocks, as: BlockRegistry
  alias Valimc.TestScope
  alias Valimc.World
  alias Valimc.World.Region

  setup do
    nonce = System.unique_integer([:positive])
    key = {80_000 + rem(nonce, 10_000), 1850}
    base = Path.join(System.tmp_dir!(), "valimc-light-#{nonce}")
    TestScope.isolate(key, world_path: base, region_ticks: :manual)

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, key),
          do: TestScope.kill(pid)

      File.rm_rf(base)
    end)

    {rx, rz} = key
    size = Valimc.config(:region_size)
    {:ok, owner} = World.owner(key)
    %{key: key, owner: owner, origin: {rx * size * 16, rz * size * 16}}
  end

  # One cell's level from a light image (26 sections from y −80, sky then block).
  defp level(image, kind, {x, y, z}) do
    section = div(y + 80, 16)
    layers = decode(image)
    {sky, block} = Enum.at(layers, section)
    layer = if kind == :sky, do: sky, else: block
    i = (y &&& 15) <<< 8 ||| (z &&& 15) <<< 4 ||| (x &&& 15)
    byte = :binary.at(layer, i >>> 1)
    if (i &&& 1) == 0, do: byte &&& 15, else: byte >>> 4
  end

  defp decode(<<>>), do: []

  defp decode(bytes) do
    {sky, rest} = take(bytes)
    {block, rest} = take(rest)
    [{sky, block} | decode(rest)]
  end

  defp take(<<1, value, rest::binary>>), do: {:binary.copy(<<value>>, 2048), rest}
  defp take(<<2, data::binary-size(2048), rest::binary>>), do: {data, rest}

  defp image(owner, chunk), do: Region.light_image(owner, chunk)

  defp set(owner, edits) do
    {:ok, observed} = Region.observe_blocks(owner, Map.keys(edits))
    {:ok, _} = Region.set_blocks(owner, observed.fence, edits)
  end

  test "flat terrain is dark below the grass and open sky above", ctx do
    {x0, z0} = ctx.origin
    chunk = World.chunk_key(x0 + 40, z0 + 40)
    light = image(ctx.owner, chunk)
    assert level(light, :sky, {x0 + 40, 64, z0 + 40}) == 15
    assert level(light, :sky, {x0 + 40, 63, z0 + 40}) == 0
    assert level(light, :block, {x0 + 40, 64, z0 + 40}) == 0
  end

  test "edits relight their surroundings, across chunk borders, and send light updates", ctx do
    {x0, z0} = ctx.origin
    World.subscribe(MapSet.new([ctx.key]), MapSet.new())
    # A viewed chunk has been lit (lighting starts with the first light request).
    image(ctx.owner, World.chunk_key(x0 + 47, z0 + 40))
    glowstone = BlockRegistry.default_state("glowstone")
    # At the east edge of its chunk, so the light crosses into the next chunk.
    lamp = {x0 + 47, 70, z0 + 40}
    set(ctx.owner, %{lamp => glowstone})

    assert_receive {:event, {:block_batch, updates}}, 2000
    light_chunks = for {chunk, frame} <- updates, light_update?(frame), do: chunk
    assert World.chunk_key(x0 + 47, z0 + 40) in light_chunks
    assert World.chunk_key(x0 + 48, z0 + 40) in light_chunks

    here = image(ctx.owner, World.chunk_key(x0 + 47, z0 + 40))
    east = image(ctx.owner, World.chunk_key(x0 + 48, z0 + 40))
    assert level(here, :block, lamp) == 15
    assert level(here, :block, {x0 + 46, 70, z0 + 40}) == 14
    assert level(east, :block, {x0 + 48, 70, z0 + 40}) == 14
    assert level(east, :block, {x0 + 61, 70, z0 + 40}) == 1

    # A shaft through the grass and dirt opens the stone below to the sky.
    shaft = for y <- 50..63, into: %{}, do: {{x0 + 20, y, z0 + 20}, 0}
    set(ctx.owner, shaft)
    pit = image(ctx.owner, World.chunk_key(x0 + 20, z0 + 20))
    assert level(pit, :sky, {x0 + 20, 50, z0 + 20}) == 15

    # Removing the lamp takes its light away again.
    set(ctx.owner, %{lamp => 0})

    assert level(
             image(ctx.owner, World.chunk_key(x0 + 48, z0 + 40)),
             :block,
             {x0 + 48, 70, z0 + 40}
           ) == 0
  end

  test "light is recomputed equal after a restart", ctx do
    {x0, z0} = ctx.origin
    set(ctx.owner, %{{x0 + 30, 64, z0 + 30} => BlockRegistry.default_state("glowstone")})
    chunk = World.chunk_key(x0 + 30, z0 + 30)
    before = image(ctx.owner, chunk)
    {pid, _} = ctx.owner
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, owner} = World.owner(ctx.key)
    assert image(owner, chunk) == before
  end

  # Light reaches a neighbour region's ring asynchronously: poll briefly.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "light crosses region borders both ways, also when a neighbour loads later", ctx do
    {rx, rz} = ctx.key
    east = {rx + 1, rz}

    TestScope.isolate(east,
      world_path: Valimc.config(:world_path, ctx.key),
      region_ticks: :manual
    )

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, east),
          do: TestScope.kill(pid)
    end)

    {:ok, neighbour} = World.owner(east)
    {x0, z0} = ctx.origin
    edge = x0 + Valimc.config(:region_size) * 16 - 1
    glowstone = BlockRegistry.default_state("glowstone")
    lamp = {edge, 70, z0 + 40}
    across = {edge + 2, 70, z0 + 40}
    across_chunk = World.chunk_key(edge + 2, z0 + 40)
    # The neighbour's chunk was sent before the lamp, as to a player nearby.
    _ = packet_light(across_chunk)
    set(ctx.owner, %{lamp => glowstone})

    assert eventually(fn -> level(image(neighbour, across_chunk), :block, across) == 13 end)
    # A freshly joining player gets that light too, not a cached packet.
    expected = IO.iodata_to_binary(Valimc.Anvil.Light.packet(image(neighbour, across_chunk)))
    assert String.ends_with?(packet_light(across_chunk), expected)

    set(ctx.owner, %{lamp => 0})

    assert eventually(fn ->
             level(image(neighbour, World.chunk_key(edge + 2, z0 + 40)), :block, across) == 0
           end)

    # A lamp in the neighbour, then this owner restarts: its hello brings the light back.
    set(neighbour, %{{edge + 1, 70, z0 + 40} => glowstone})
    {pid, _} = ctx.owner
    :ok = DynamicSupervisor.terminate_child(Valimc.RegionSupervisor, pid)
    {:ok, owner} = World.owner(ctx.key)

    assert eventually(fn ->
             level(image(owner, World.chunk_key(edge, z0 + 40)), :block, {edge - 1, 70, z0 + 40}) ==
               13
           end)
  end

  test "a neighbour sends border light updates only for chunks a client asked for", ctx do
    {rx, rz} = ctx.key
    east = {rx + 1, rz}

    TestScope.isolate(east,
      world_path: Valimc.config(:world_path, ctx.key),
      region_ticks: :manual
    )

    on_exit(fn ->
      for reg <- [Valimc.RegionRegistry, Valimc.RegionStoreRegistry],
          {pid, _} <- Registry.lookup(reg, east),
          do: TestScope.kill(pid)
    end)

    {:ok, neighbour} = World.owner(east)
    {x0, z0} = ctx.origin
    edge = x0 + Valimc.config(:region_size) * 16 - 1
    sent = World.chunk_key(edge + 2, z0 + 40)
    unsent = World.chunk_key(edge + 2, z0 + 48)
    _ = packet_light(sent)
    World.subscribe(MapSet.new([east]), MapSet.new())
    set(ctx.owner, %{{edge, 70, z0 + 44} => BlockRegistry.default_state("glowstone")})

    assert eventually(fn ->
             level(image(neighbour, unsent), :block, {edge + 2, 70, z0 + 48}) > 0
           end)

    assert_receive {:event, {:block_batch, frames}}, 2000
    light = for {chunk, frame} <- frames, light_update?(frame), do: chunk
    assert sent in light
    refute unsent in light
    refute_received {:event, {:block_batch, _}}
  end

  # The light data a freshly joining client gets: the tail of the chunk packet.
  defp packet_light(key) do
    frame = World.chunk(key)

    {:ok, _id, payload, <<>>} =
      Wire.next_frame(
        IO.iodata_to_binary(frame),
        2_097_152,
        Valimc.config(:compression_threshold)
      )

    payload
  end

  test "fresh chunk packets carry current light after edits in and beside the chunk", ctx do
    {x0, z0} = ctx.origin
    here = World.chunk_key(x0 + 40, z0 + 40)
    east = World.chunk_key(x0 + 48, z0 + 40)
    # Both chunks were sent (and cached) before the edit, as for a player nearby.
    _ = packet_light(here)
    _ = packet_light(east)
    lamp = {x0 + 47, 70, z0 + 40}
    set(ctx.owner, %{lamp => BlockRegistry.default_state("glowstone")})

    for {role, chunk} <- [lamp_chunk: here, neighbour: east] do
      expected = IO.iodata_to_binary(Valimc.Anvil.Light.packet(image(ctx.owner, chunk)))

      assert String.ends_with?(packet_light(chunk), expected),
             "stale light in the #{role} #{inspect(chunk)}"
    end

    assert level(image(ctx.owner, east), :block, {x0 + 48, 70, z0 + 40}) == 14
  end

  test "a raw single-block set (creative torch placement) relights and refreshes packets", ctx do
    {x0, z0} = ctx.origin
    chunk = World.chunk_key(x0 + 20, z0 + 20)
    _ = packet_light(chunk)
    torch = {x0 + 20, 64, z0 + 20}
    assert :ok = World.set_block(torch, BlockRegistry.default_state("torch"))
    light = image(ctx.owner, chunk)
    assert level(light, :block, torch) == 14
    assert level(light, :block, {x0 + 21, 64, z0 + 20}) == 13
    expected = IO.iodata_to_binary(Valimc.Anvil.Light.packet(light))
    assert String.ends_with?(packet_light(chunk), expected)
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
end
