defmodule Valimc.Commands.World do
  @moduledoc """
  World commands (VMC-053c) after vanilla's command classes: `time` on 26.3's
  world clocks, `weather`, `difficulty`, the game rules ValiMC applies,
  `setblock`, `fill`, `setworldspawn`, `seed` and `locate biome`. Clock, weather
  and difficulty changes go through the environment owner (`World.Clock`);
  blocks go through region owners with fenced batches.
  """
  alias Valimc.Command.{Error, Feedback, Names, Source, Text, BlockInput}
  alias Valimc.World.Clock

  @facts :json.decode(File.read!(Path.expand("../../../priv/commands/facts.json", __DIR__)))
  @external_resource Path.expand("../../../priv/commands/facts.json", __DIR__)
  unless Valimc.Version.stamped?(@facts),
    do: raise("Command facts are not from the pinned release")

  @markers @facts["time_markers"]
  @timelines @facts["timelines"]
  @int_max 2_147_483_647

  # ---- time ----

  defp clock_id(%{"clock" => clock}), do: clock
  defp clock_id(_), do: "minecraft:overworld"

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

  @doc "`/time set <time>`."
  def time_set(%{"time" => time} = arguments, source) do
    id = clock_id(arguments)

    if clock(id).total_ticks == time,
      do: Error.fail!("commands.time.set.already_at_time", [id, time])

    configure!({id, :ticks, time})
    Feedback.success(source, Text.translatable("commands.time.set.absolute", [id, time]))
    {time, source.state}
  end

  @doc "`/time set <timemarker>`: forward to the marker's next occurrence."
  def time_set_marker(%{"timemarker" => marker} = arguments, source) do
    id = clock_id(arguments)

    case @markers[marker] do
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
        {wrap_long(next), source.state}

      _ ->
        Error.fail!("commands.time.no_time_marker_found", [marker, id])
    end
  end

  @doc "`/time add <time>`."
  def time_add(%{"time" => time} = arguments, source) do
    id = clock_id(arguments)
    total = max(clock(id).total_ticks + time, 0)
    configure!({id, :ticks, total})

    Feedback.success(
      source,
      Text.translatable("commands.time.set.absolute", [id, {:long, total}])
    )

    {wrap_long(total), source.state}
  end

  def time_pause(arguments, source), do: pause(arguments, source, true)
  def time_resume(arguments, source), do: pause(arguments, source, false)

  defp pause(arguments, source, paused) do
    id = clock_id(arguments)

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

    {1, source.state}
  end

  @doc "`/time rate <rate>`."
  def time_rate(%{"rate" => rate} = arguments, source) do
    id = clock_id(arguments)

    if clock(id).rate == rate,
      do: Error.fail!("commands.time.rate.already_same", [id, {:float, rate}])

    configure!({id, :rate, rate})
    Feedback.success(source, Text.translatable("commands.time.rate", [id, {:float, rate}]))
    {1, source.state}
  end

  @doc "`/time query time`."
  def time_query(arguments, source) do
    id = clock_id(arguments)
    total = clock(id).total_ticks

    Feedback.success(
      source,
      Text.translatable("commands.time.query.absolute", [id, {:long, total}]),
      false
    )

    {wrap_long(total), source.state}
  end

  @doc "`/time query <timeline> [repetition]`."
  def time_query_timeline(%{"timeline" => timeline} = arguments, source) do
    id = clock_id(arguments)
    facts = @timelines[timeline]

    if facts["clock"] != id,
      do: Error.fail!("commands.time.wrong_timeline_for_clock", [timeline, id])

    total = clock(id).total_ticks
    period = facts["period"]

    {key, value} =
      if arguments[:repetition],
        do:
          {"commands.time.query.timeline.repetitions",
           if(period, do: div(total, period), else: 0)},
        else: {"commands.time.query.timeline", if(period, do: rem(total, period), else: total)}

    Feedback.success(source, Text.translatable(key, [timeline, {:long, value}]), false)
    {wrap_long(value), source.state}
  end

  def time_query_repetition(arguments, source),
    do: time_query_timeline(Map.put(arguments, :repetition, true), source)

  @doc "`/time query gametime`."
  def time_query_gametime(_arguments, source) do
    game_time = Clock.snapshot().game_time

    Feedback.success(
      source,
      Text.translatable("commands.time.query.gametime", [{:long, game_time}]),
      false
    )

    {wrap_long(game_time), source.state}
  end

  # ---- weather ----

  def weather_clear(arguments, source), do: weather(arguments, source, :clear, 12_000..180_000)
  def weather_rain(arguments, source), do: weather(arguments, source, :rain, 12_000..24_000)
  def weather_thunder(arguments, source), do: weather(arguments, source, :thunder, 3_600..15_600)

  defp weather(arguments, source, kind, range) do
    duration = Map.get(arguments, "duration")
    configure!({:weather, kind, duration || Enum.random(range)})

    key =
      %{
        clear: "commands.weather.set.clear",
        rain: "commands.weather.set.rain",
        thunder: "commands.weather.set.thunder"
      }[kind]

    Feedback.success(source, Text.translatable(key))
    {duration || -1, source.state}
  end

  # ---- difficulty ----

  @levels %{"peaceful" => 0, "easy" => 1, "normal" => 2, "hard" => 3}

  def difficulty_query(_arguments, source) do
    {difficulty, _packet} = Clock.difficulty()

    Feedback.success(
      source,
      Text.translatable("commands.difficulty.query", [Names.difficulty(difficulty.level)]),
      false
    )

    {difficulty.level, source.state}
  end

  for {name, level} <- @levels do
    def unquote(String.to_atom("difficulty_" <> name))(_arguments, source),
      do: set_difficulty(source, unquote(level))
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

    {0, source.state}
  end

  # ---- game rules ----

  # The rules ValiMC applies today, with their owner operations.
  @rules %{
    "advance_time" => {:advance_time, :advance_time},
    "advance_weather" => {:advance_weather, :weather},
    "natural_health_regeneration" => {:natural_regeneration, :natural_regeneration}
  }

  def live_rules, do: Map.keys(@rules)

  defp rule_value("advance_time"), do: Clock.snapshot().advance_time
  defp rule_value("advance_weather"), do: Clock.snapshot().weather.advance_weather
  defp rule_value("natural_health_regeneration"), do: Clock.snapshot().natural_regeneration

  @doc "`/gamerule <rule>`: the rule's current value."
  def gamerule_query(%{rule: rule}, source) do
    value = rule_value(rule)

    Feedback.success(
      source,
      Text.translatable("commands.gamerule.query", [rule, to_string(value)]),
      false
    )

    {if(value, do: 1, else: 0), source.state}
  end

  @doc "`/gamerule <rule> <value>`."
  def gamerule_set(%{:rule => rule, "value" => value}, source) do
    if rule_value(rule) == value,
      do: Error.fail!("commands.gamerule.not_set", [rule, to_string(value)])

    {operation, _} = Map.fetch!(@rules, rule)
    configure!({operation, value})
    Feedback.success(source, Text.translatable("commands.gamerule.set", [rule, to_string(value)]))
    {if(value, do: 1, else: 0), source.state}
  end

  for rule <- ["advance_time", "advance_weather", "natural_health_regeneration"] do
    def unquote(String.to_atom("gamerule_query_" <> rule))(arguments, source),
      do: gamerule_query(Map.put(arguments, :rule, unquote(rule)), source)

    def unquote(String.to_atom("gamerule_set_" <> rule))(arguments, source),
      do: gamerule_set(Map.put(arguments, :rule, unquote(rule)), source)
  end

  # ---- blocks ----

  defp loaded_block!(source, coordinates) do
    {x, y, z} = Source.block_pos(source, coordinates)

    unless Valimc.World.Chunk.valid_y?(y) and x >= -30_000_000 and x < 30_000_000 and
             z >= -30_000_000 and z < 30_000_000,
           do: Error.fail!("argument.pos.outofworld")

    {x, y, z}
  end

  @doc "`/setblock <pos> <block> [keep|replace|strict]`."
  def setblock(%{"pos" => pos, "block" => %BlockInput{state: state} = block} = arguments, source) do
    position = loaded_block!(source, pos)
    no_block_data!(block)
    current = Valimc.World.get_block(position)

    if arguments[:mode] == :keep and not air?(current),
      do: Error.fail!("commands.setblock.failed")

    if current == state, do: Error.fail!("commands.setblock.failed")

    case Valimc.World.set_block(position, state) do
      :ok ->
        {x, y, z} = position
        Feedback.success(source, Text.translatable("commands.setblock.success", [x, y, z]))
        {1, source.state}

      {:error, reason} ->
        Error.throw!(%Error{
          message: Text.literal("That block change is not supported yet (#{reason})")
        })
    end
  end

  def setblock_keep(arguments, source), do: setblock(Map.put(arguments, :mode, :keep), source)

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
    {x1, y1, z1} = loaded_block!(source, from)
    {x2, y2, z2} = loaded_block!(source, to)
    {xa, xb} = Enum.min_max([x1, x2])
    {ya, yb} = Enum.min_max([y1, y2])
    {za, zb} = Enum.min_max([z1, z2])
    area = (xb - xa + 1) * (yb - ya + 1) * (zb - za + 1)
    limit = 32_768
    if area > limit, do: Error.fail!("commands.fill.toobig", [limit, {:long, area}])
    mode = Map.get(arguments, :mode, :replace)
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
        count + fill_region(key, edits, mode, filter)
      end)

    if count == 0, do: Error.fail!("commands.fill.failed")
    Feedback.success(source, Text.translatable("commands.fill.success", [count]))
    {count, source.state}
  end

  for mode <- [:outline, :hollow, :keep] do
    def unquote(String.to_atom("fill_#{mode}"))(arguments, source),
      do: fill(Map.put(arguments, :mode, unquote(mode)), source)
  end

  defp fill_region(key, edits, mode, filter, attempts \\ 3) do
    {:ok, owner} = Valimc.World.owner(key)
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
        fill_region(key, edits, mode, filter, attempts - 1)

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

    Valimc.World.Spawn.set(position, yaw)
    {x, y, z} = position

    Feedback.success(
      source,
      Text.translatable("commands.setworldspawn.success", [
        x,
        y,
        z,
        {:float, yaw},
        {:float, pitch},
        "minecraft:overworld"
      ])
    )

    {1, source.state}
  end

  @doc "`/seed`: the world seed, copyable on click."
  def seed(_arguments, source) do
    case Valimc.World.Generator.current() do
      {:vanilla, seed} ->
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
        {low, source.state}

      _ ->
        Error.throw!(%Error{message: Text.literal("This flat preview world has no seed")})
    end
  end

  @doc "`/locate biome <biome>` in a flat world, whose only biome is plains."
  def locate_biome(%{"biome" => biome}, source) do
    unless Valimc.World.Generator.current() == :flat,
      do:
        Error.throw!(%Error{
          message: Text.literal("Locating biomes in generated worlds is not supported yet")
        })

    {printable, found} =
      case biome do
        {:resource, id} -> {id, id == "minecraft:plains"}
        {:tag, id, members} -> {"#" <> id, plains_id() in members}
      end

    unless found, do: Error.fail!("commands.locate.biome.not_found", [printable])
    {x, y, z} = source.position
    min_y = Valimc.World.Chunk.min_y()

    {bx, by, bz} =
      {floor(x), floor(y) |> max(min_y + 1) |> min(Valimc.World.Chunk.max_y() + 1), floor(z)}

    name = if match?({:tag, _, _}, biome), do: "#{printable} (minecraft:plains)", else: printable

    coordinates =
      Text.translatable("chat.square_brackets", [
        Text.translatable("chat.coordinates", [bx, Integer.to_string(by), bz])
      ])
      |> Text.style([
        {"color", "green"},
        {"click_event", Text.suggest_command("/tp @s #{bx} #{by} #{bz}")},
        {"hover_event",
         {:compound,
          %{
            "action" => {:string, "show_text"},
            "value" => Text.translatable("chat.coordinates.tooltip")
          }}}
      ])

    Feedback.success(
      source,
      Text.translatable("commands.locate.biome.success", [name, coordinates, 0]),
      false
    )

    {0, source.state}
  end

  defp plains_id,
    do: Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
end
