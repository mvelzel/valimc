defmodule Valimc.Commands.Blocks do
  @moduledoc """
  Area commands (VMC-053j): `clone` within the source's dimension (block
  entities are refused until their contents can be copied), `fillbiome` and
  `forceload` over `Valimc.World.ForcedChunks`. A clone is one box edit over
  its source and destination, all or nothing (`Valimc.World.BoxEdit`).
  """
  alias Valimc.Commands.Parser.BlockInput
  alias Valimc.Text.Error
  alias Valimc.Commands.{Feedback, Source}
  alias Valimc.Text
  alias Valimc.Data.Blocks
  alias Valimc.World.ForcedChunks

  # The source's dimension, as forceload messages name it.
  defp here(source), do: Valimc.World.Dimension.name(source.dimension)
  @limit 32_768

  # ---- clone ----

  @doc "`/clone [from <dim>] <begin> <end> [to <dim>] <destination> [strict] [replace|masked|filtered <filter>] [force|move|normal]`."
  def clone(arguments, source) do
    dimension!(source, arguments["sourceDimension"])
    dimension!(source, arguments["targetDimension"])
    from_a = Source.block_in_world!(source, arguments["begin"])
    from_b = Source.block_in_world!(source, arguments["end"])
    destination = Source.block_in_world!(source, arguments["destination"])
    {min, max} = box(from_a, from_b)
    {dx, dy, dz} = sub(destination, min)
    {to_min, to_max} = {destination, add(max, {dx, dy, dz})}
    mode = Enum.find_value(arguments.literals, :normal, &mode/1)

    if mode == :normal and intersects?({min, max}, {to_min, to_max}),
      do: Error.fail!("commands.clone.overlap")

    area = volume(min, max)
    if area > @limit, do: Error.fail!("commands.clone.toobig", [@limit, {:long, area}])

    filter = filter(arguments)
    barrier = Blocks.default_state("barrier")
    air = Blocks.default_state("air")
    # Destinations above or below the world are skipped and not counted.
    to_min = put_elem(to_min, 1, max(elem(to_min, 1), Valimc.World.Chunk.min_y()))
    to_max = put_elem(to_max, 1, min(elem(to_max, 1), Valimc.World.Chunk.max_y()))

    boxes = [
      {min, max} | if(elem(to_min, 1) <= elem(to_max, 1), do: [{to_min, to_max}], else: [])
    ]

    # One box edit over the source and destination: a refused part (a chest
    # with items, an unsupported block entity) leaves both as they were.
    edit = fn current ->
      entries =
        for {{x, y, z} = position, state} <- current,
            x in elem(min, 0)..elem(max, 0) and y in elem(min, 1)..elem(max, 1) and
              z in elem(min, 2)..elem(max, 2),
            filter.(state),
            do: {position, state}

      if Enum.any?(entries, fn {_, state} -> Valimc.Blocks.block_entity(state) != nil end),
        do: Error.refuse!("Cloning block entities is not supported yet")

      placed =
        for {position, state} <- entries,
            destination = add(position, {dx, dy, dz}),
            Valimc.World.Chunk.valid_y?(elem(destination, 1)),
            into: %{},
            do: {destination, state}

      count = Enum.count(placed, fn {_, state} -> state != barrier end)
      if count == 0, do: Error.fail!("commands.clone.failed")

      cleared =
        if mode == :move, do: Map.new(entries, fn {position, _} -> {position, air} end), else: %{}

      edits =
        for {position, state} <- Map.merge(cleared, placed),
            current[position] != state,
            into: %{},
            do: {position, state}

      {edits, count}
    end

    count = Valimc.Commands.World.edit!(source, boxes, edit)
    Feedback.success(source, Text.translatable("commands.clone.success", [count]))
    count
  end

  defp mode("force"), do: :force
  defp mode("move"), do: :move
  defp mode(_), do: nil

  # `replace` (the default), `masked` or `filtered <filter>`.
  defp filter(%{literals: literals} = arguments) do
    cond do
      "masked" in literals -> &(Blocks.name(Blocks.block_id(&1)) not in ~w(air cave_air void_air))
      "filtered" in literals -> &BlockInput.matches?(arguments["filter"], &1)
      true -> fn _ -> true end
    end
  end

  # Cloning within the source's dimension (VMC-026b); across dimensions is unsupported.
  defp dimension!(_source, nil), do: :ok

  defp dimension!(source, id) do
    if Valimc.World.Dimension.parse(id) == {:ok, source.dimension},
      do: :ok,
      else: Error.fail!("argument.dimension.invalid", [id])
  end

  defp box({ax, ay, az}, {bx, by, bz}),
    do: {{min(ax, bx), min(ay, by), min(az, bz)}, {max(ax, bx), max(ay, by), max(az, bz)}}

  defp add({a, b, c}, {x, y, z}), do: {a + x, b + y, c + z}
  defp sub({a, b, c}, {x, y, z}), do: {a - x, b - y, c - z}
  defp volume({ax, ay, az}, {bx, by, bz}), do: (bx - ax + 1) * (by - ay + 1) * (bz - az + 1)

  defp intersects?({{a0, b0, c0}, {a1, b1, c1}}, {{x0, y0, z0}, {x1, y1, z1}}),
    do: a0 <= x1 and x0 <= a1 and b0 <= y1 and y0 <= b1 and c0 <= z1 and z0 <= c1

  # ---- fillbiome ----

  @doc "`/fillbiome <from> <to> <biome> [replace <filter>]` (VMC-053j4)."
  def fillbiome(%{"from" => from, "to" => to, "biome" => biome} = arguments, source) do
    {ax, ay, az} = Source.block_in_world!(source, from)
    {bx, by, bz} = Source.block_in_world!(source, to)
    # `quantize`: down to the corner of the biome cell.
    q = fn v -> Bitwise.band(v, -4) end
    min = {q.(min(ax, bx)), q.(min(ay, by)), q.(min(az, bz))}
    max = {q.(max(ax, bx)), q.(max(ay, by)), q.(max(az, bz))}
    {x0, y0, z0} = min
    {x1, y1, z1} = max
    volume = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)
    if volume > @limit, do: Error.fail!("commands.fillbiome.toobig", [@limit, {:long, volume}])

    id = fn name -> Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", name) end

    filter =
      case arguments["filter"] do
        nil -> nil
        {:resource, name} -> [id.(name)]
        {:tag, _, members} -> members
      end

    chunks =
      for cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
          cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
          do: {cx, cz}

    count =
      chunks
      |> Enum.group_by(&Valimc.World.region_key/1)
      |> Enum.reduce(0, fn {key, group}, count ->
        with {:ok, owner} <- Source.owner(source, key),
             {:ok, changed} <-
               Valimc.World.Region.fill_biomes(owner, group, {min, max}, id.(biome), filter) do
          count + changed
        else
          {:error, {:retry, :chunk_generating}} -> Error.fail!("argument.pos.unloaded")
          _ -> Error.fail!("argument.pos.unloaded")
        end
      end)

    if count == 0, do: Error.fail!("commands.fillbiome.no_changes")

    Feedback.success(
      source,
      Text.translatable("commands.fillbiome.success.count", [count, x0, y0, z0, x1, y1, z1])
    )

    count
  end

  # ---- forceload ----

  defp column(source, coordinates) do
    {x, _, z} = Source.block_pos(source, coordinates)
    {x, z}
  end

  defp chunk_text({x, z}), do: "[#{x}, #{z}]"

  @doc "`/forceload add|remove <from> [<to>]`, `remove all` and `query [<pos>]`."
  def forceload(%{literals: literals} = arguments, source) do
    case {literals, arguments} do
      {["add"], _} -> change(arguments, source, :add)
      {["remove"], _} -> change(arguments, source, :remove)
      {["remove", "all"], _} -> forceload_remove_all(source)
      {["query"], %{"pos" => pos}} -> forceload_query_pos(pos, source)
      {["query"], _} -> forceload_query(source)
    end
  end

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

    chunks = for(x <- cx0..cx1, z <- cz0..cz1, do: {x, z})
    changed = ForcedChunks.change(operation, chunks, source.dimension)

    key = if operation == :add, do: "added", else: "removed"

    case changed do
      [] ->
        Error.fail!("commands.forceload.#{key}.failure")

      [chunk] ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.#{key}.single", [chunk_text(chunk), here(source)])
        )

      many ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.#{key}.multiple", [
            length(many),
            here(source),
            chunk_text({cx0, cz0}),
            chunk_text({cx1, cz1})
          ])
        )
    end

    length(changed)
  end

  defp div_floor(block), do: Integer.floor_div(block, 16)

  defp forceload_remove_all(source) do
    ForcedChunks.remove_all(source.dimension)
    Feedback.success(source, Text.translatable("commands.forceload.removed.all", [here(source)]))
    0
  end

  defp forceload_query_pos(pos, source) do
    {x, z} = column(source, pos)
    chunk = {div_floor(x), div_floor(z)}

    if chunk in ForcedChunks.all(source.dimension) do
      Feedback.success(
        source,
        Text.translatable("commands.forceload.query.success", [chunk_text(chunk), here(source)]),
        false
      )

      1
    else
      Error.fail!("commands.forceload.query.failure", [chunk_text(chunk), here(source)])
    end
  end

  defp forceload_query(source) do
    # Sorted as the packed chunk long: z, then x as an unsigned 32-bit value.
    chunks =
      Enum.sort_by(ForcedChunks.all(source.dimension), fn {x, z} ->
        {z, Bitwise.band(x, 0xFFFFFFFF)}
      end)

    list = Enum.map_join(chunks, ", ", &chunk_text/1)

    case chunks do
      [] ->
        Feedback.failure(
          source,
          Text.translatable("commands.forceload.added.none", [here(source)])
        )

      [_] ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.list.single", [here(source), list]),
          false
        )

      many ->
        Feedback.success(
          source,
          Text.translatable("commands.forceload.list.multiple", [length(many), here(source), list]),
          false
        )
    end

    length(chunks)
  end
end
