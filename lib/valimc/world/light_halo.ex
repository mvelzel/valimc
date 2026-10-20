defmodule Valimc.World.LightHalo do
  @moduledoc """
  Light across region borders (VMC-022c). Each owner lights its region plus a
  one-chunk ring of neighbour chunks; light travels at most 15 blocks, so its own
  cells are exact once the ring holds the neighbours' blocks.

  Owners keep each other's rings current with plain messages (no calls, so no
  owner ever waits on another): after loading, an owner sends every loaded
  neighbour the column images of its chunks in that neighbour's ring
  (`{:halo, {:hello, ...}}`); the neighbour adopts them and answers with its own
  (`{:halo, {:images, ...}}`). Durable block changes in ring chunks are forwarded
  (`{:halo, {:edits, ...}}`). Every adoption relights and sends `light_update`
  for the owner's chunks whose light changed. A ring chunk of an unloaded
  neighbour keeps its last known blocks (flat terrain until first heard of).
  """
  alias Valimc.Native
  alias Valimc.Protocol.Packets
  alias Valimc.World
  alias Valimc.World.Blocks

  def neighbours({rx, rz}),
    do: for(dx <- -1..1, dz <- -1..1, {dx, dz} != {0, 0}, do: {rx + dx, rz + dz})

  @doc "Whether `chunk` is in the one-chunk ring around region `key`."
  def ring?({rx, rz}, {cx, cz}) do
    size = Valimc.config(:region_size)
    {mx, mz} = {rx * size, rz * size}
    inside = cx in mx..(mx + size - 1) and cz in mz..(mz + size - 1)
    not inside and cx in (mx - 1)..(mx + size) and cz in (mz - 1)..(mz + size)
  end

  # This region's chunks that lie in `other`'s ring.
  defp ring_chunks(key, other) do
    size = Valimc.config(:region_size)
    {rx, rz} = key

    for cx <- (rx * size)..(rx * size + size - 1),
        cz <- (rz * size)..(rz * size + size - 1),
        ring?(other, {cx, cz}),
        do: {cx, cz}
  end

  defp images(state, other) do
    for chunk <- ring_chunks(state.key, other) do
      {:ok, image} = Blocks.column_image(state.blocks, chunk)
      {elem(chunk, 0), elem(chunk, 1), image}
    end
  end

  defp owner(key) do
    case Registry.lookup(Valimc.RegionRegistry, key) do
      [{pid, _}] when pid != self() -> pid
      _ -> nil
    end
  end

  @doc "After loading: send loaded neighbours this region's ring chunks."
  def hello(state) do
    for key <- neighbours(state.key),
        pid = owner(key),
        pid != nil,
        do: send(pid, {:halo, {:hello, state.key, self(), images(state, key)}})

    state
  end

  @doc "Forward durable block changes in neighbours' rings."
  def forward(state, edits) do
    for key <- neighbours(state.key), pid = owner(key), pid != nil do
      list =
        for {{x, y, z}, block} <- edits, ring?(key, World.chunk_key(x, z)), do: {x, y, z, block}

      if list != [], do: send(pid, {:halo, {:edits, state.key, list}})
    end

    state
  end

  @doc "Handle a neighbour's message."
  def handle({:hello, from, pid, images}, state) do
    state = adopt(state, Native.halo_put(state.blocks.ref, images))
    send(pid, {:halo, {:images, state.key, images(state, from)}})
    state
  end

  def handle({:images, _from, images}, state),
    do: adopt(state, Native.halo_put(state.blocks.ref, images))

  def handle({:edits, _from, edits}, state),
    do: adopt(state, Native.halo_edits(state.blocks.ref, edits))

  defp adopt(state, {:ok, []}), do: state

  # Only chunks a client has asked for need a light update; neighbours loading
  # around fresh terrain relight many chunks nobody has yet (VMC-071).
  defp adopt(state, {:ok, chunks}) do
    case Enum.filter(chunks, &MapSet.member?(state.served, &1)) do
      [] -> :ok
      served -> World.publish(state.key, {:block_batch, frames(state, served)})
    end

    Valimc.World.RegionData.light_changed(state, chunks)
  end

  defp adopt(state, {:error, _}), do: state

  @doc "`light_update` frames for the region's chunks whose light changed."
  def frames(state, chunks) do
    threshold = Valimc.config(:compression_threshold)

    for chunk <- chunks,
        image = Blocks.light_image(state.blocks, chunk),
        do: {chunk, Packets.frame(Packets.light_update(chunk, image), threshold)}
  end
end
