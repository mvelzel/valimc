defmodule Valimc.Commands.World do
  @moduledoc """
  World commands (VMC-053c) after vanilla's command classes: `time` on 26.3's
  world clocks, `weather`, `difficulty`, the game rules ValiMC applies,
  `setblock`, `fill`, `setworldspawn`, `seed` and `locate biome`. Clock, weather
  and difficulty changes go through the environment owner (`World.Clock`);
  blocks go through region owners with fenced batches.
  """
  alias Valimc.Command.{BlockInput, Error, Facts, Feedback, Names, Source}
  alias Valimc.Text
  alias Valimc.World.Clock

  @int_max 2_147_483_647

  # ---- time ----

  defp clock_id(%{"clock" => clock}, _source), do: clock

  # The source dimension's default clock; the Nether has none (VMC-026b).
  defp clock_id(_, source) do
    facts = Valimc.Dimension.facts(source.dimension)
    facts.default_clock || Error.fail!("commands.time.no_default_clock", [facts.type])
  end

  defp clock(id), do: Map.fetch!(Clock.snapshot().clocks, id)

  defp configure!(operation) do
    case Clock.configure(operation) do
      :ok ->
        :ok

      {:error, reason} ->
        Error.throw!(%Error{
          message: Text.literal("The clock refused the change (#{inspect(reason)})")
        })
    end
  end

  defp wrap_long(value), do: rem(value, @int_max)

  @doc "`/time [of <clock>] set|add|pause|resume|rate|query …` on 26.3's world clocks."
  def time(%{literals: literals} = arguments, source) do
    case {List.delete(literals, "of"), arguments} do
      {["set"], %{"timemarker" => _}} -> time_set_marker(arguments, source)
      {["set"], _} -> time_set(arguments, source)
      {["add"], _} -> time_add(arguments, source)
      {["pause"], _} -> pause(arguments, source, true)
      {["resume"], _} -> pause(arguments, source, false)
      {["rate"], _} -> time_rate(arguments, source)
      {["query", "time"], _} -> time_query(arguments, source)
      {["query", "gametime"], _} -> time_query_gametime(source)
      {["query", "repetition"], _} -> time_query_timeline(arguments, source, true)
      {["query"], _} -> time_query_timeline(arguments, source, false)
    end
  end

  @doc "`/time` markers (suggested ones) and timelines of the clock in use."
  def suggest(path, arguments, source) do
    clock =
      arguments["clock"] || Valimc.Dimension.facts(source.dimension).default_clock ||
        "minecraft:overworld"

    case List.last(path) do
      "timemarker" ->
        {:resources,
         for({id, %{"clock" => ^clock, "suggested" => true}} <- Facts.time_markers(), do: id)}

      "timeline" ->
        {:resources, for({id, %{"clock" => ^clock}} <- Facts.timelines(), do: id)}

      _ ->
        {:resources, []}
    end
  end

  # `/time set <time>`.
  defp time_set(%{"time" => time} = arguments, source) do
    id = clock_id(arguments, source)

    if clock(id).total_ticks == time,
      do: Error.fail!("commands.time.set.already_at_time", [id, time])

    configure!({id, :ticks, time})
    Feedback.success(source, Text.translatable("commands.time.set.absolute", [id, time]))
    time
  end

  # `/time set <timemarker>`: forward to the marker's next occurrence.
  defp time_set_marker(%{"timemarker" => marker} = arguments, source) do
    id = clock_id(arguments, source)

    case Facts.time_markers()[marker] do
      %{"clock" => ^id, "ticks" => ticks} = facts ->
        total = clock(id).total_ticks
        period = facts["period"]

        at =
          if period, do: rem(total, period) == ticks, else: total == ticks

        if at, do: Error.fail!("commands.time.set.already_at_time_marker", [id, marker])

        next =
          if period do
            delta = ticks - rem(total, period)
            total + if(delta > 0, do: delta, else: period + delta)
          else
            ticks
          end

        configure!({id, :ticks, next})
        Feedback.success(source, Text.translatable("commands.time.set.time_marker", [id, marker]))
        wrap_long(next)

      _ ->
        Error.fail!("commands.time.no_time_marker_found", [marker, id])
    end
  end

  # `/time add <time>`.
  defp time_add(%{"time" => time} = arguments, source) do
    id = clock_id(arguments, source)
    total = max(clock(id).total_ticks + time, 0)
    configure!({id, :ticks, total})

    Feedback.success(
      source,
      Text.translatable("commands.time.set.absolute", [id, {:long, total}])
    )

    wrap_long(total)
  end

  defp pause(arguments, source, paused) do
    id = clock_id(arguments, source)

    if clock(id).paused == paused,
      do:
        Error.fail!(
          if(paused,
            do: "commands.time.pause.already_paused",
            else: "commands.time.pause.already_running"
          ),
          [id]
        )

    configure!({id, :paused, paused})

    Feedback.success(
      source,
      Text.translatable(if(paused, do: "commands.time.pause", else: "commands.time.resume"), [id])
    )

    1
  end

  # `/time rate <rate>`.
  defp time_rate(%{"rate" => rate} = arguments, source) do
    id = clock_id(arguments, source)

    if clock(id).rate == rate,
      do: Error.fail!("commands.time.rate.already_same", [id, {:float, rate}])

    configure!({id, :rate, rate})
    Feedback.success(source, Text.translatable("commands.time.rate", [id, {:float, rate}]))
    1
  end

  # `/time query time`.
  defp time_query(arguments, source) do
    id = clock_id(arguments, source)
    total = clock(id).total_ticks

    Feedback.success(
      source,
      Text.translatable("commands.time.query.absolute", [id, {:long, total}]),
      false
    )

    wrap_long(total)
  end

  # `/time query <timeline> [repetition]`.
  defp time_query_timeline(%{"timeline" => timeline} = arguments, source, repetition) do
    id = clock_id(arguments, source)
    facts = Facts.timelines()[timeline]

    if facts["clock"] != id,
      do: Error.fail!("commands.time.wrong_timeline_for_clock", [timeline, id])

    total = clock(id).total_ticks
    period = facts["period"]

    {key, value} =
      if repetition,
        do:
          {"commands.time.query.timeline.repetitions",
           if(period, do: div(total, period), else: 0)},
        else: {"commands.time.query.timeline", if(period, do: rem(total, period), else: total)}

    Feedback.success(source, Text.translatable(key, [timeline, {:long, value}]), false)
    wrap_long(value)
  end

  # `/time query gametime`.
  defp time_query_gametime(source) do
    game_time = Clock.snapshot().game_time

    Feedback.success(
      source,
      Text.translatable("commands.time.query.gametime", [{:long, game_time}]),
      false
    )

    wrap_long(game_time)
  end

  # ---- weather ----

  @doc "`/weather clear|rain|thunder [<duration>]`."
  def weather(%{literals: [kind]} = arguments, source) do
    {kind, range} =
      case kind do
        "clear" -> {:clear, 12_000..180_000}
        "rain" -> {:rain, 12_000..24_000}
        "thunder" -> {:thunder, 3_600..15_600}
      end

    duration = Map.get(arguments, "duration")
    configure!({:weather, kind, duration || Enum.random(range)})

    key =
      %{
        clear: "commands.weather.set.clear",
        rain: "commands.weather.set.rain",
        thunder: "commands.weather.set.thunder"
      }[kind]

    Feedback.success(source, Text.translatable(key))
    duration || -1
  end

  # ---- difficulty ----

  @levels %{"peaceful" => 0, "easy" => 1, "normal" => 2, "hard" => 3}

  @doc "`/difficulty [peaceful|easy|normal|hard]`."
  def difficulty(%{literals: [name]}, source),
    do: set_difficulty(source, Map.fetch!(@levels, name))

  def difficulty(_arguments, source) do
    {difficulty, _packet} = Clock.difficulty()

    Feedback.success(
      source,
      Text.translatable("commands.difficulty.query", [Names.difficulty(difficulty.level)]),
      false
    )

    difficulty.level
  end

  defp set_difficulty(source, level) do
    {difficulty, _packet} = Clock.difficulty()

    if difficulty.level == level,
      do: Error.fail!("commands.difficulty.failure", [Names.difficulty(level)])

    configure!({:difficulty, level, true})

    Feedback.success(
      source,
      Text.translatable("commands.difficulty.success", [Names.difficulty(level)])
    )

    0
  end

  # ---- game rules ----

  def live_rules, do: Map.keys(Valimc.GameRules.stored())

  @doc "The `/gamerule` paths ValiMC runs: each live rule, short and namespaced, queried or set."
  def gamerule_paths do
    for rule <- live_rules(),
        name <- [rule, "minecraft:" <> rule],
        tail <- [[], ["value"]],
        do: ["gamerule", name | tail]
  end

  defp rule_value("advance_time"), do: Clock.snapshot().advance_time
  defp rule_value("advance_weather"), do: Clock.snapshot().weather.advance_weather
  defp rule_value("natural_health_regeneration"), do: Clock.snapshot().natural_regeneration

  @doc "`/gamerule <rule> [<value>]`: the rule's value, or a new one."
  def gamerule(%{literals: [name]} = arguments, source) do
    rule = String.replace_prefix(name, "minecraft:", "")

    case arguments do
      %{"value" => value} -> gamerule_set(rule, value, source)
      _ -> gamerule_query(rule, source)
    end
  end

  defp gamerule_query(rule, source) do
    value = rule_value(rule)

    Feedback.success(
      source,
      Text.translatable("commands.gamerule.query", [rule, to_string(value)]),
      false
    )

    if(value, do: 1, else: 0)
  end

  defp gamerule_set(rule, value, source) do
    if rule_value(rule) == value,
      do: Error.fail!("commands.gamerule.not_set", [rule, to_string(value)])

    operation = Map.fetch!(Valimc.GameRules.stored(), rule)
    configure!({operation, value})
    Feedback.success(source, Text.translatable("commands.gamerule.set", [rule, to_string(value)]))
    if(value, do: 1, else: 0)
  end

  # ---- blocks ----

  @doc """
  `/setblock <pos> <block> [keep|replace|strict]`: one fenced batch at the
  sections it read (VMC-077a), read again when they changed in between.
  """
  def setblock(%{"pos" => pos, "block" => %BlockInput{state: state} = block} = arguments, source) do
    {x, y, z} = position = Source.block_in_world!(source, pos)
    no_block_data!(block)
    mode = if arguments.literals == ["keep"], do: :keep, else: :replace
    set_block!(source, position, state, mode, 3)
    Feedback.success(source, Text.translatable("commands.setblock.success", [x, y, z]))
    1
  end

  defp set_block!(source, {x, _, z} = position, state, mode, attempts) do
    key = Valimc.World.region_key(Valimc.World.chunk_key(x, z))

    with {:ok, owner} <- Source.owner(source, key),
         {:ok, view} <- Valimc.World.Region.observe_blocks(owner, [position]) do
      current = view.blocks[position]
      if mode == :keep and not air?(current), do: Error.fail!("commands.setblock.failed")
      if current == state, do: Error.fail!("commands.setblock.failed")

      case Valimc.World.Region.set_blocks(owner, view.fence, %{position => state}) do
        {:ok, _revision} ->
          :ok

        {:error, :stale_revision} when attempts > 0 ->
          set_block!(source, position, state, mode, attempts - 1)

        {:error, reason} ->
          unsupported!(reason)
      end
    else
      {:error, :chunk_generating} -> Error.fail!("argument.pos.unloaded")
      {:error, reason} -> unsupported!(reason)
    end
  end

  defp unsupported!(reason),
    do:
      Error.throw!(%Error{
        message: Text.literal("That block change is not supported yet (#{inspect(reason)})")
      })

  # Block-entity data from commands needs owner support per block entity.
  defp no_block_data!(%BlockInput{nbt: nbt}) when nbt in [nil, {:compound, %{}}], do: :ok
  defp no_block_data!(_), do: Error.refuse!("Block entity data in commands is not supported yet")

  @air ~w(air cave_air void_air)
  defp air?(state),
    do: Valimc.Registry.Blocks.name(Valimc.Registry.Blocks.block_id(state)) in @air

  @doc "`/fill <from> <to> <block> [mode]`, one fenced batch per region."
  def fill(
        %{"from" => from, "to" => to, "block" => %BlockInput{state: state}} = arguments,
        source
      ) do
    {x1, y1, z1} = Source.block_in_world!(source, from)
    {x2, y2, z2} = Source.block_in_world!(source, to)
    {xa, xb} = Enum.min_max([x1, x2])
    {ya, yb} = Enum.min_max([y1, y2])
    {za, zb} = Enum.min_max([z1, z2])
    area = (xb - xa + 1) * (yb - ya + 1) * (zb - za + 1)
    limit = 32_768
    if area > limit, do: Error.fail!("commands.fill.toobig", [limit, {:long, area}])
    # `[replace [<filter>]] [strict]`, or one of `outline`, `hollow`, `keep`.
    mode =
      Enum.find_value(arguments.literals, :replace, fn
        "outline" -> :outline
        "hollow" -> :hollow
        "keep" -> :keep
        _ -> nil
      end)

    filter = arguments["filter"]
    air = Valimc.Registry.Blocks.default_state("air")

    planned =
      for z <- za..zb, y <- ya..yb, x <- xa..xb do
        shell = x in [xa, xb] or y in [ya, yb] or z in [za, zb]

        target =
          case mode do
            :outline -> if shell, do: state
            :hollow -> if shell, do: state, else: air
            _ -> state
          end

        {{x, y, z}, target}
      end
      |> Enum.reject(&is_nil(elem(&1, 1)))

    count =
      planned
      |> Enum.group_by(fn {{x, _, z}, _} ->
        Valimc.World.region_key(Valimc.World.chunk_key(x, z))
      end)
      |> Enum.reduce(0, fn {key, edits}, count ->
        count + fill_region(source, key, edits, mode, filter)
      end)

    if count == 0, do: Error.fail!("commands.fill.failed")
    Feedback.success(source, Text.translatable("commands.fill.success", [count]))
    count
  end

  defp fill_region(source, key, edits, mode, filter, attempts \\ 3) do
    {:ok, owner} = Source.owner(source, key)
    positions = Enum.map(edits, &elem(&1, 0))

    observed =
      Enum.reduce_while(Enum.chunk_every(positions, 128), {:ok, :any, %{}}, fn batch,
                                                                               {:ok, revision,
                                                                                blocks} ->
        case Valimc.World.Region.observe_blocks(owner, batch, revision) do
          {:ok, view} -> {:cont, {:ok, view.revision, Map.merge(blocks, view.blocks)}}
          error -> {:halt, error}
        end
      end)

    with {:ok, revision, blocks} <- observed do
      changes =
        for {position, target} <- edits,
            current = blocks[position],
            filter == nil or BlockInput.matches?(filter, current),
            mode != :keep or air?(current),
            current != target,
            into: %{},
            do: {position, target}

      commit(owner, revision, Enum.chunk_every(changes, 4096), map_size(changes))
    end
    |> case do
      {:ok, count} ->
        count

      {:error, :stale_revision} when attempts > 0 ->
        fill_region(source, key, edits, mode, filter, attempts - 1)

      {:error, reason} ->
        Error.throw!(%Error{message: Text.literal("Fill could not change the world (#{reason})")})
    end
  end

  defp commit(_owner, _revision, [], count), do: {:ok, count}

  defp commit(owner, revision, [batch | rest], count) do
    case Valimc.World.Region.set_blocks(owner, revision, Map.new(batch)) do
      {:ok, revision} -> commit(owner, revision, rest, count)
      error -> error
    end
  end

  # ---- spawn, seed, locate ----

  @doc "`/setworldspawn [<pos> [<rotation>]]`."
  def setworldspawn(arguments, source) do
    position =
      case arguments do
        %{"pos" => pos} ->
          pos = Source.block_pos(source, pos)

          unless Valimc.Commands.Players.spawnable?(pos),
            do: Error.fail!("argument.pos.outofbounds")

          pos

        _ ->
          {x, y, z} = source.position
          {floor(x), floor(y), floor(z)}
      end

    {yaw, pitch} =
      case arguments do
        %{"rotation" => rotation} ->
          Valimc.Command.Coordinates.rotation_of(rotation, source.rotation)

        _ ->
          {0.0, 0.0}
      end

    # Vanilla's `RespawnData.of(level.dimension(), pos, yaw, pitch)`.
    case Valimc.World.Spawn.set(source.dimension, position, yaw, pitch) do
      {:error, reason} -> Error.refuse!("The world spawn could not be saved (#{inspect(reason)})")
      _saved_or_unchanged -> :ok
    end

    {x, y, z} = position

    Feedback.success(
      source,
      Text.translatable("commands.setworldspawn.success", [
        x,
        y,
        z,
        {:float, yaw},
        {:float, pitch},
        Valimc.Dimension.name(source.dimension)
      ])
    )

    1
  end

  @doc "`/seed`: the world seed, copyable on click."
  def seed(_arguments, source) do
    seed =
      case Valimc.World.Spec.current() do
        %{settings: %{"seed" => seed}} -> seed
        _ -> nil
      end

    case seed do
      seed when is_integer(seed) ->
        text = Integer.to_string(seed)

        copy =
          Text.translatable("chat.square_brackets", [
            Text.literal(text)
            |> Text.style([
              {"color", "green"},
              {"click_event",
               {:compound,
                %{"action" => {:string, "copy_to_clipboard"}, "value" => {:string, text}}}},
              {"hover_event",
               {:compound,
                %{
                  "action" => {:string, "show_text"},
                  "value" => Text.translatable("chat.copy.click")
                }}},
              {"insertion", text}
            ])
          ])

        Feedback.success(source, Text.translatable("commands.seed.success", [copy]), false)
        <<low::signed-32>> = <<seed::32>>
        low

      _ ->
        Error.throw!(%Error{message: Text.literal("This flat preview world has no seed")})
    end
  end
end
