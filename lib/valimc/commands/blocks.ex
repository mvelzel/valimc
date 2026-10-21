defmodule Valimc.Commands.Blocks do
  @moduledoc """
  Area commands (VMC-053j): `clone` within the overworld (block entities are
  refused until their contents can be copied) and `forceload` over
  `Valimc.World.ForcedChunks`. Block writes are fenced per region owner, as
  `/fill` does.
  """
  alias Valimc.Command.{BlockInput, Error, Feedback, Source, Text}
  alias Valimc.Registry.Blocks
  alias Valimc.World.ForcedChunks

  # The source's dimension, as forceload messages name it.
  defp here, do: Valimc.Dimension.name(Valimc.Dimension.current())
  @limit 32_768

  # ---- clone ----

  @doc "`/clone [from <dim>] <begin> <end> [to <dim>] <destination> [strict] [replace|masked|filtered <filter>] [force|move|normal]`."
  def clone(arguments, source) do
    dimension!(arguments["sourceDimension"])
    dimension!(arguments["targetDimension"])
    from_a = loaded!(source, arguments["begin"])
    from_b = loaded!(source, arguments["end"])
    destination = loaded!(source, arguments["destination"])
    {min, max} = box(from_a, from_b)
    {dx, dy, dz} = sub(destination, min)
    {to_min, to_max} = {destination, add(max, {dx, dy, dz})}
    mode = Map.get(arguments, :mode, :normal)

    if mode == :normal and intersects?({min, max}, {to_min, to_max}),
      do: Error.fail!("commands.clone.overlap")

    area = volume(min, max)
    if area > @limit, do: Error.fail!("commands.clone.toobig", [@limit, {:long, area}])

    positions =
      for z <- elem(min, 2)..elem(max, 2),
          y <- elem(min, 1)..elem(max, 1),
          x <- elem(min, 0)..elem(max, 0),
          do: {x, y, z}

    states = observe(positions)

    filter = filter(arguments)

    entries =
      for position <- positions, filter.(states[position]), do: {position, states[position]}

    if Enum.any?(entries, fn {_, state} -> Valimc.Block.block_entity(state) != nil end),
      do: Error.refuse!("Cloning block entities is not supported yet")

    # Destinations above or below the world are skipped and not counted.
    placed =
      for {position, state} <- entries,
          destination = add(position, {dx, dy, dz}),
          Valimc.World.Chunk.valid_y?(elem(destination, 1)),
          into: %{},
          do: {destination, state}

    barrier = Blocks.default_state("barrier")
    count = Enum.count(placed, fn {_, state} -> state != barrier end)
    if count == 0, do: Error.fail!("commands.clone.failed")

    air = Blocks.default_state("air")

    cleared =
      if mode == :move, do: Map.new(entries, fn {position, _} -> {position, air} end), else: %{}

    write(Map.merge(cleared, placed))
    Feedback.success(source, Text.translatable("commands.clone.success", [count]))
    {count, source.state}
  end

  for mask <- [:replace, :masked, :filtered], mode <- [:normal, :force, :move] do
    def unquote(:"clone_#{mask}_#{mode}")(arguments, source),
      do:
        clone(arguments |> Map.put(:mask, unquote(mask)) |> Map.put(:mode, unquote(mode)), source)
  end

  defp filter(%{:mask => :masked}),
    do: &(Blocks.name(Blocks.block_id(&1)) not in ~w(air cave_air void_air))

  defp filter(%{:mask => :filtered, "filter" => filter}), do: &BlockInput.matches?(filter, &1)
  defp filter(_), do: fn _ -> true end

  # Cloning within the source's dimension (VMC-026b); across dimensions is unsupported.
  defp dimension!(nil), do: :ok

  defp dimension!(id) do
    if Valimc.Dimension.parse(id) == {:ok, Valimc.Dimension.current()},
      do: :ok,
      else: Error.fail!("argument.dimension.invalid", [id])
  end

  defp loaded!(source, coordinates) do
    {x, y, z} = Source.block_pos(source, coordinates)

    unless Valimc.World.Chunk.valid_y?(y) and x >= -30_000_000 and x < 30_000_000 and
             z >= -30_000_000 and z < 30_000_000,
           do: Error.fail!("argument.pos.outofworld")

    {x, y, z}
  end

  defp box({ax, ay, az}, {bx, by, bz}),
    do: {{min(ax, bx), min(ay, by), min(az, bz)}, {max(ax, bx), max(ay, by), max(az, bz)}}

  defp add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}
  defp sub({a, b, c}, {x, y, z}), do: {a - x, b - y, c - z}
  defp volume({ax, ay, az}, {bx, by, bz}), do: (bx - ax + 1) * (by - ay + 1) * (bz - az + 1)

  defp intersects?({{a0, b0, c0}, {a1, b1, c1}}, {{x0, y0, z0}, {x1, y1, z1}}),
    do: a0 <= x1 and x0 <= a1 and b0 <= y1 and y0 <= b1 and c0 <= z1 and z0 <= c1

  defp region(position) do
    {x, _, z} = position
    Valimc.World.region_key(Valimc.World.chunk_key(x, z))
  end

  defp observe(positions) do
    positions
    |> Enum.group_by(&region/1)
    |> Enum.reduce(%{}, fn {key, positions}, acc ->
      {:ok, owner} = Valimc.World.owner(key)

      Enum.reduce(Enum.chunk_every(positions, 128), acc, fn batch, acc ->
        {:ok, view} = Valimc.World.Region.observe_blocks(owner, batch)
        Map.merge(acc, view.blocks)
      end)
    end)
  end

  defp write(edits) do
    for {key, edits} <- Enum.group_by(edits, fn {position, _} -> region(position) end) do
      {:ok, owner} = Valimc.World.owner(key)
      {:ok, view} = Valimc.World.Region.observe_blocks(owner, [elem(hd(edits), 0)])

      Enum.reduce(Enum.chunk_every(edits, 4096), view.revision, fn batch, revision ->
        case Valimc.World.Region.set_blocks(owner, revision, Map.new(batch)) do
          {:ok, revision} -> revision
          {:error, reason} -> Error.refuse!("Clone could not change the world (#{reason})")
        end
      end)
    end

    :ok
  end

  # ---- forceload ----

  defp column(source, coordinates) do
    {x, _, z} = Source.block_pos(source, coordinates)
    {x, z}
  end

  defp chunk_text({x, z}), do: "[#{x}, #{z}]"

  @doc "`/forceload add|remove <from> [<to>]`."
  def forceload_add(arguments, source), do: change(arguments, source, :add)
  def forceload_remove(arguments, source), do: change(arguments, source, :remove)

  defp change(arguments, source, operation) do
    {ax, az} = column(source, arguments["from"])
    {bx, bz} = if arguments["to"], do: column(source, arguments["to"]), else: {ax, az}
    {min_x, max_x} = Enum.min_max([ax, bx])
    {min_z, max_z} = Enum.min_max([az, bz])

    if Enum.any?([min_x, max_x, min_z, max_z], &(&1 < -30_000_000 or &1 >= 30_000_000)),
      do: Error.fail!("argument.pos.outofworld")

    {cx0, cx1, cz0, cz1} =
      {div_floor(min_x), div_floor(max_x), div_floor(min_z), div_floor(max_z)}

    count = (cx1 - cx0 + 1) * (cz1 - cz0 + 1)
    if count > 256, do: Error.fail!("commands.forceload.toobig", [256, {:long, count}])

    changed = ForcedChunks.change(operation, for(x <- cx0..cx1, z <- cz0..cz1, do: {x, z}))

    key = if operation == :add, do: "added", else: "removed"

    case changed do
      [] ->
        Error.fail!("commands.forceload.#{key}.failure")

      [chunk] ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.#{key}.single", [chunk_text(chunk), here()])
        )

      many ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.#{key}.multiple", [
            length(many),
            here(),
            chunk_text({cx0, cz0}),
            chunk_text({cx1, cz1})
          ])
        )
    end

    {length(changed), source.state}
  end

  defp div_floor(block), do: Integer.floor_div(block, 16)

  def forceload_remove_all(_arguments, source) do
    ForcedChunks.remove_all()
    Feedback.success(source, Text.translatable("commands.forceload.removed.all", [here()]))
    {0, source.state}
  end

  def forceload_query_pos(%{"pos" => pos}, source) do
    {x, z} = column(source, pos)
    chunk = {div_floor(x), div_floor(z)}

    if chunk in ForcedChunks.all() do
      Feedback.success(
        source,
        Text.translatable("commands.forceload.query.success", [chunk_text(chunk), here()]),
        false
      )

      {1, source.state}
    else
      Error.fail!("commands.forceload.query.failure", [chunk_text(chunk), here()])
    end
  end

  def forceload_query(_arguments, source) do
    # Sorted as the packed chunk long: z, then x as an unsigned 32-bit value.
    chunks = Enum.sort_by(ForcedChunks.all(), fn {x, z} -> {z, Bitwise.band(x, 0xFFFFFFFF)} end)
    list = Enum.map_join(chunks, ", ", &chunk_text/1)

    case chunks do
      [] ->
        Feedback.failure(source, Text.translatable("commands.forceload.added.none", [here()]))

      [_] ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.list.single", [here(), list]),
          false
        )

      many ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.list.multiple", [length(many), here(), list]),
          false
        )
    end

    {length(chunks), source.state}
  end
end
