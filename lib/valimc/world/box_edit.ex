defmodule Valimc.World.BoxEdit do
  @moduledoc """
  Block edits of commands, all or nothing across region owners (VMC-077o):
  `/setblock`, `/fill`, `/clone` and `/place`.

  `read/3` reads a box from its owners (`Region.read_box/3`, one call per
  region, never generating an absent chunk). `commit/2` takes a plan by region:
  the edits, the states the plan was made from (`expected`) and the block
  entity records to write with them. Every owner first prepares its part: it
  checks the expected states still hold, that it can commit the edits and
  records, and locks the cells against other writes. Only when all prepared
  do they commit; otherwise every prepared part is released and nothing
  changes. A position in a region that is not running or in a chunk not
  generated yet is unloaded (`argument.pos.unloaded`), as vanilla's
  `getLoadedBlockPos` refuses it.

  The commits of several owners are separate durable frames: a crash between
  them can keep some (one frame per owner per tick and a shared log are
  VMC-077f's).
  """
  alias Valimc.World
  alias Valimc.World.Region

  @retries 50

  @doc """
  The states of the box `{min, max}` in `dimension` as a `position => state`
  map, or `{:error, :unloaded}`.
  """
  def read(dimension, {x0, y0, z0}, {x1, y1, z1}) do
    parts =
      for {key, {{ax, _, az}, {bx, _, bz}}} <- split({x0, y0, z0}, {x1, y1, z1}),
          do: {key, {ax, y0, az}, {bx, y1, bz}}

    Enum.reduce_while(parts, {:ok, %{}}, fn {key, min, max}, {:ok, acc} ->
      with {:ok, owner} <-
             World.existing_owner(Valimc.Data.Grid.section(dimension, key, :section)),
           {:ok, states} <- Region.read_box(owner, min, max) do
        {:cont, {:ok, Map.merge(acc, Map.new(Enum.zip(positions(min, max), decode(states))))}}
      else
        _ -> {:halt, {:error, :unloaded}}
      end
    end)
  end

  @doc """
  Commit `parts` (`region key => %{edits, expected, entries}`, entries and
  expected optional) in `dimension`: `:ok`, `{:error, :unloaded}` or
  `{:error, reason}` with nothing changed.
  """
  def commit(dimension, parts) do
    token = :crypto.strong_rand_bytes(16)

    owners =
      Enum.reduce_while(Enum.sort(parts), {:ok, []}, fn {key, part}, {:ok, acc} ->
        case World.existing_owner(Valimc.Data.Grid.section(dimension, key, :section)) do
          {:ok, owner} -> {:cont, {:ok, [{owner, part} | acc]}}
          _ -> {:halt, {:error, :unloaded}}
        end
      end)

    with {:ok, owners} <- owners,
         owners = Enum.reverse(owners),
         :ok <- prepare(owners, token, []) do
      Enum.reduce(owners, :ok, fn {owner, part}, result ->
        case commit_part(owner, token, Map.get(part, :entries, %{}), @retries) do
          {:ok, _} -> result
          error when result == :ok -> error
          _ -> result
        end
      end)
    end
  end

  defp prepare([], _token, _prepared), do: :ok

  defp prepare([{owner, part} | rest], token, prepared) do
    edits = part.edits
    expected = Map.get(part, :expected, %{})
    entries = Map.get(part, :entries, %{})

    case Region.prepare_box(owner, token, edits, expected, entries) do
      :ok ->
        prepare(rest, token, [owner | prepared])

      error ->
        for owner <- prepared, do: Region.abort_box(owner, token)
        unloaded(error)
    end
  end

  defp commit_part(owner, token, entries, retries) do
    case Region.commit_box(owner, token, entries) do
      {:error, {:retry, :box_edit_busy}} when retries > 0 ->
        Process.sleep(5)
        commit_part(owner, token, entries, retries - 1)

      result ->
        result
    end
  end

  defp unloaded({:error, {:retry, :chunk_generating}}), do: {:error, :unloaded}
  defp unloaded(error), do: error

  @doc "Group `edits` (`position => state`) by region key."
  def by_region(edits) do
    Enum.group_by(edits, fn {{x, _, z}, _} ->
      Valimc.Data.Grid.region_key(Valimc.Data.Grid.chunk_key(x, z))
    end)
    |> Map.new(fn {key, cells} -> {key, Map.new(cells)} end)
  end

  # The box split by region: `{key, {min, max}}` (y as given).
  defp split({x0, y0, z0}, {x1, y1, z1}) do
    size = Valimc.Data.Grid.region_size() * 16

    for rx <- Integer.floor_div(x0, size)..Integer.floor_div(x1, size),
        rz <- Integer.floor_div(z0, size)..Integer.floor_div(z1, size) do
      {{rx, rz},
       {{max(x0, rx * size), y0, max(z0, rz * size)},
        {min(x1, rx * size + size - 1), y1, min(z1, rz * size + size - 1)}}}
    end
  end

  # Positions in `read_box` order: x fastest, then y, then z.
  defp positions({x0, y0, z0}, {x1, y1, z1}),
    do: for(z <- z0..z1, y <- y0..y1, x <- x0..x1, do: {x, y, z})

  defp decode(states), do: for(<<state::16 <- states>>, do: state)
end
