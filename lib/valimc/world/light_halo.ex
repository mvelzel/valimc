defmodule Valimc.World.LightHalo do
  @moduledoc """
  Light across region borders (VMC-022c). Each owner lights its region plus a
  one-chunk ring of neighbour chunks; light travels at most 15 blocks, so its own
  cells are exact once the ring holds the neighbours' blocks.

  Owners keep each other's rings current with plain messages (no calls, so no
  owner ever waits on another), addressed to the neighbour section (a group
  process holds several, VMC-077j; a sibling in the same group gets its
  message from its own process): after loading, an owner sends every loaded
  neighbour the column images of its chunks in that neighbour's ring
  (`{:halo, key, {:hello, ...}}`); the neighbour adopts them and answers with
  its own (`{:halo, key, {:images, ...}}`). Generated columns follow as
  images, durable block changes in ring chunks as edits (`{:edits, ...}`). A
  ring chunk is unknown to light until its owner sends it (VMC-077c), and so
  is a chunk its owner has not generated: light neither enters nor leaves it.
  A ring chunk of a neighbour that unloads keeps its last known blocks.

  Light changes go to clients as `light_update` packets carrying only the
  changed sections (`frames/3`). Those that follow block changes reach only the
  clients for whom the chunk is on the edge of what they have, as vanilla sends
  them (`ChunkMap.isChunkOnTrackedBorder`): inside it the client relights from
  the block updates itself. Those from adopted images reach every client that
  has the chunk, since no block update tells a client about them.
  """
  alias Valimc.Native
  alias Valimc.Protocol.Packets
  alias Valimc.World
  alias Valimc.World.{Blocks, RegionGeneration}

  def neighbours({rx, rz}),
    do: for(dx <- -1..1, dz <- -1..1, {dx, dz} != {0, 0}, do: {rx + dx, rz + dz})

  @doc "Whether `chunk` is in the one-chunk ring around region `key`."
  def ring?({rx, rz}, {cx, cz}) do
    size = Valimc.Data.Grid.region_size()
    {mx, mz} = {rx * size, rz * size}
    inside = cx in mx..(mx + size - 1) and cz in mz..(mz + size - 1)
    not inside and cx in (mx - 1)..(mx + size) and cz in (mz - 1)..(mz + size)
  end

  # This region's generated chunks that lie in `other`'s ring.
  defp ring_chunks(state, other) do
    size = Valimc.Data.Grid.region_size()
    {rx, rz} = state.key

    for cx <- (rx * size)..(rx * size + size - 1),
        cz <- (rz * size)..(rz * size + size - 1),
        ring?(other, {cx, cz}),
        not RegionGeneration.absent?(state.generation, {cx, cz}),
        do: {cx, cz}
  end

  defp images(state, other) do
    for chunk <- ring_chunks(state, other) do
      {:ok, image} = Blocks.column_image(state.blocks, chunk)
      {elem(chunk, 0), elem(chunk, 1), image}
    end
  end

  defp owner(state, {sx, sz}) do
    case Registry.lookup(Valimc.RegionRegistry, {state.dimension, sx, sz}) do
      [{pid, _}] -> pid
      _ -> nil
    end
  end

  @doc "After loading: send loaded neighbours this region's ring chunks."
  def hello(state) do
    for key <- neighbours(state.key),
        pid = owner(state, key),
        pid != nil,
        do: send(pid, {:halo, key, {:hello, state.key, self(), images(state, key)}})

    state
  end

  @doc "Send loaded neighbours the generated columns (VMC-075) of chunks in their rings."
  def columns_changed(state, columns) do
    for key <- neighbours(state.key), pid = owner(state, key), pid != nil do
      list = for {{cx, cz} = chunk, image} <- columns, ring?(key, chunk), do: {cx, cz, image}
      if list != [], do: send(pid, {:halo, key, {:images, state.key, list}})
    end

    state
  end

  @doc "Forward durable block changes in neighbours' rings."
  def forward(state, edits) do
    for key <- neighbours(state.key), pid = owner(state, key), pid != nil do
      list =
        for {{x, y, z}, block} <- edits,
            ring?(key, Valimc.Data.Grid.chunk_key(x, z)),
            do: {x, y, z, block}

      if list != [], do: send(pid, {:halo, key, {:edits, state.key, list}})
    end

    state
  end

  @doc "Handle a neighbour's message."
  def handle({:hello, from, pid, images}, state) do
    state = adopt(state, Native.halo_put(state.blocks.ref, images), :all)
    send(pid, {:halo, from, {:images, state.key, images(state, from)}})
    state
  end

  def handle({:images, _from, images}, state),
    do: adopt(state, Native.halo_put(state.blocks.ref, images), :all)

  def handle({:edits, _from, edits}, state) do
    case Native.halo_set(state.blocks.ref, edits) do
      {:ok, positions} ->
        adopt(state, {:ok, Blocks.light_update(state.blocks, positions)}, :border)

      {:error, _} ->
        state
    end
  end

  defp adopt(state, {:ok, []}, _scope), do: state

  # Only chunks a client has asked for need a light update; neighbours loading
  # around fresh terrain relight many chunks nobody has yet (VMC-071).
  defp adopt(state, {:ok, changes}, scope) do
    case Enum.filter(changes, &MapSet.member?(state.served, elem(&1, 0))) do
      [] ->
        :ok

      served ->
        World.publish(
          Valimc.World.RegionData.route_key(state),
          {:block_batch, frames(state, served, scope)}
        )
    end

    Valimc.World.RegionData.light_changed(state, Blocks.changed_chunks(changes))
  end

  defp adopt(state, {:error, _}, _scope), do: state

  @doc """
  `light_update` frames for the region's light `changes` (`Blocks.light_update/2`),
  each with only its changed sections. `:border` frames (after block changes)
  go only to clients for whom the chunk is on the edge of what they have,
  `:all` frames to every client that has it.
  """
  def frames(state, changes, scope) do
    threshold = Valimc.config(:compression_threshold)

    for {chunk, sky, block} <- changes,
        image = Blocks.light_image(state.blocks, chunk, {sky, block}),
        do: {target(scope, chunk), Packets.frame(light_update(chunk, image), threshold)}
  end

  defp target(:border, chunk), do: {:light, chunk}
  defp target(:all, chunk), do: chunk

  # Light of one chunk (VMC-022c): its light image as `level_chunk_with_light` carries it.
  defp light_update({cx, cz}, image) do
    Packets.packet("light_update", [
      Valimc.Protocol.Wire.varint(cx),
      Valimc.Protocol.Wire.varint(cz),
      Valimc.Storage.Anvil.Light.packet(image)
    ])
  end
end
