defmodule Valimc.Commands.Players do
  @moduledoc """
  Player commands (VMC-053b): `gamemode`, `defaultgamemode`, `teleport`/`tp`,
  `give`, `clear`, `effect`, `experience`/`xp` and `kill`, after vanilla's command
  classes. Each target applies its change in its own connection, all at once
  (`Valimc.Commands.Remote`); messages follow `CommandResponseTracker`.
  """
  alias Valimc.Command.{Coordinates, Error, Feedback, Names, Source, Targets}
  alias Valimc.Text
  alias Valimc.Commands.Remote
  alias Valimc.Player.CommandOps
  alias Valimc.Protocol.{EffectTypes, ItemStack}

  # ---- tracker ----

  # Vanilla's `CommandResponseTracker.sendFeedback` over `{target, value}` pairs:
  # "single" when exactly one target had a non-zero value; the result is the sum.
  defp respond(source, tracked, broadcast, messages) do
    nonzero = Enum.reject(tracked, fn {_target, value} -> value == 0 end)
    total = tracked |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    if messages[:zero] && nonzero == [], do: Error.throw!(messages[:zero])

    message =
      case nonzero do
        [{target, _}] -> call(messages[:single], target, total)
        _ -> call(messages[:multiple], length(nonzero), total)
      end

    Feedback.success(source, message, broadcast)
    total
  end

  defp call(fun, subject, _total) when is_function(fun, 1), do: fun.(subject)
  defp call(fun, subject, total), do: fun.(subject, total)

  # Targets that did not answer are not counted (`:unavailable`).
  defp on_targets(targets, op_fun) do
    targets
    |> Remote.run_all!(op_fun)
    |> Enum.reject(&(elem(&1, 1) == :unavailable))
  end

  defp name(target), do: Source.display_name(target)

  # ---- gamemode ----

  @doc "`/gamemode <gamemode> [<target>]` (`GameModeCommand`)."
  def gamemode(%{"gamemode" => mode} = arguments, source) do
    targets =
      case arguments do
        %{"target" => selector} -> Targets.required_players(source, selector)
        _ -> [Source.player!(source)]
      end

    mode_name = Names.game_mode(mode)

    changed =
      for {target, :changed} <-
            on_targets(targets, fn target ->
              notice =
                if not Source.self?(source, target) and
                     Valimc.GameRules.get(:send_command_feedback),
                   do: Text.encode(Text.translatable("gameMode.changed", [mode_name]))

              {:game_mode, mode, notice}
            end) do
        message =
          if Source.self?(source, target),
            do: Text.translatable("commands.gamemode.success.self", [mode_name]),
            else: Text.translatable("commands.gamemode.success.other", [name(target), mode_name])

        Feedback.success(source, message)
      end

    length(changed)
  end

  @doc "`/defaultgamemode <gamemode>`: new players' mode (no `force-gamemode`)."
  def default_gamemode(%{"gamemode" => mode}, source) do
    with {:error, reason} <- Valimc.World.Settings.put(default_game_mode: mode),
         do: Error.refuse!("The default game mode could not be saved (#{inspect(reason)})")

    Feedback.success(
      source,
      Text.translatable("commands.defaultgamemode.success", [Names.game_mode(mode)])
    )

    0
  end

  # ---- teleport ----

  @doc "`/teleport` and `/tp` (`TeleportCommand`)."
  def teleport(arguments, source) do
    targets =
      case arguments do
        %{"targets" => selector} -> Targets.required_entities(source, selector)
        _ -> [Source.player!(source)]
      end

    case arguments do
      %{"destination" => selector} ->
        destination = Targets.single_entity(source, selector)

        # Into the destination's dimension, as vanilla's `teleportTo` level (VMC-026b).
        pose = %{
          x: destination.x,
          y: destination.y,
          z: destination.z,
          yaw: wrap(destination.yaw),
          pitch: wrap(destination.pitch),
          dimension: Map.get(destination, :dimension, :overworld)
        }

        tracked = on_targets(targets, fn _ -> {:teleport, pose} end)

        total =
          respond(source, Enum.map(tracked, &{elem(&1, 0), 1}), true,
            single:
              &Text.translatable("commands.teleport.success.entity.single", [
                name(&1),
                name(destination)
              ]),
            multiple: fn count, _ ->
              Text.translatable("commands.teleport.success.entity.multiple", [
                count,
                name(destination)
              ])
            end
          )

        total

      %{"location" => location} ->
        {x, y, z} = Source.position(source, location)

        rotation =
          arguments["rotation"] && Coordinates.rotation_of(arguments["rotation"], source.rotation)

        unless spawnable?({x, y, z}), do: Error.fail!("commands.teleport.invalidPosition")
        facing = facing(arguments, source)

        tracked =
          on_targets(targets, fn target ->
            {yaw, pitch} =
              case rotation do
                nil ->
                  {target.yaw, target.pitch}

                {yaw, pitch} ->
                  {rotate(arguments["rotation"], 1, target.yaw, yaw),
                   rotate(arguments["rotation"], 0, target.pitch, pitch)}
              end

            pose = %{x: x, y: y, z: z, yaw: yaw, pitch: clamp_pitch(pitch)}
            pose = if(facing, do: look_at(pose, facing), else: pose)
            # A location is in the source's dimension.
            {:teleport, Map.put(pose, :dimension, source.dimension)}
          end)

        coordinates = Enum.map([x, y, z], &Valimc.Text.Number.fixed(&1 * 1.0, 6))

        total =
          respond(source, Enum.map(tracked, &{elem(&1, 0), 1}), true,
            single:
              &Text.translatable("commands.teleport.success.location.single", [
                name(&1) | coordinates
              ]),
            multiple: fn count, _ ->
              Text.translatable("commands.teleport.success.location.multiple", [
                count | coordinates
              ])
            end
          )

        total
    end
  end

  defp facing(%{"facingLocation" => location}, source), do: Source.position(source, location)

  defp facing(%{"facingEntity" => selector} = arguments, source) do
    entity = Targets.single_entity(source, selector)
    eyes = Map.get(arguments, "facingAnchor", :feet) == :eyes
    {entity.x, entity.y + if(eyes, do: eye_height(entity), else: 0.0), entity.z}
  end

  defp facing(_arguments, _source), do: nil

  defp eye_height(%{pose: :crouching}), do: 1.27
  defp eye_height(_), do: 1.62

  # `Entity.lookAt` from the new feet position (the source's anchor).
  defp look_at(pose, {tx, ty, tz}) do
    dx = tx - pose.x
    dy = ty - pose.y
    dz = tz - pose.z
    horizontal = :math.sqrt(dx * dx + dz * dz)
    pitch = wrap(f32(-(:math.atan2(dy, horizontal) * 180.0 / :math.pi())))
    yaw = wrap(f32(:math.atan2(dz, dx) * 180.0 / :math.pi()) - 90.0)
    %{pose | yaw: yaw, pitch: clamp_pitch(pitch)}
  end

  # A relative rotation component turns the target by the wrapped delta.
  defp rotate({:world, components}, index, current, value) do
    if elem(Enum.at(components, index), 0),
      do: current + wrap(value - current),
      else: wrap(value)
  end

  defp clamp_pitch(pitch), do: pitch |> max(-90.0) |> min(90.0)

  def spawnable?({x, y, z}) do
    {bx, by, bz} = {floor(x), floor(y), floor(z)}

    by >= -20_000_000 and by < 20_000_000 and bx >= -30_000_000 and bx < 30_000_000 and
      bz >= -30_000_000 and bz < 30_000_000
  end

  # ---- give ----

  @doc "`/give <targets> <item> [<count>]` (`GiveCommand`)."
  def give(%{"targets" => selector, "item" => item} = arguments, source) do
    count = Map.get(arguments, "count", 1)
    stack = %{ItemStack.new(item.item, 1) | components: item.components, removed: item.removed}
    limit = ItemStack.max_stack_size(stack) * 100
    display = Valimc.Protocol.ItemData.display_name(stack)

    if count > limit,
      do: Error.fail!("commands.give.failed.toomanyitems", [limit, display])

    targets = Targets.required_players(source, selector)
    tracked = on_targets(targets, fn _ -> {:give, stack, count} end)

    respond(source, Enum.map(tracked, &{elem(&1, 0), 1}), true,
      single: &Text.translatable("commands.give.success.single", [count, display, name(&1)]),
      multiple: fn players, _ ->
        Text.translatable("commands.give.success.multiple", [count, display, players])
      end
    )

    length(targets)
  end

  # ---- clear ----

  @doc "`/clear [<targets> [<item> [<maxCount>]]]` (`ClearInventoryCommands`)."
  def clear(arguments, source) do
    targets =
      case arguments do
        %{"targets" => selector} -> Targets.required_players(source, selector)
        _ -> [Source.player!(source)]
      end

    predicate = Map.get(arguments, "item", {:all, []})
    max_count = Map.get(arguments, "maxCount", -1)
    tracked = on_targets(targets, fn _ -> {:clear, predicate, max_count} end)
    tracked = Enum.map(tracked, fn {target, n} -> {target, if(is_integer(n), do: n, else: 0)} end)

    if Enum.all?(tracked, &(elem(&1, 1) == 0)) do
      case targets do
        [target] -> Error.fail!("clear.failed.single", [name(target)])
        _ -> Error.fail!("clear.failed.multiple", [length(targets)])
      end
    end

    kind = if max_count == 0, do: "test", else: "success"

    total =
      respond(source, tracked, true,
        single: fn target, total ->
          Text.translatable("commands.clear.#{kind}.single", [total, name(target)])
        end,
        multiple: fn players, total ->
          Text.translatable("commands.clear.#{kind}.multiple", [total, players])
        end
      )

    total
  end

  # ---- effect ----

  @doc "`/effect give <targets> <effect> [<seconds>|infinite …]` and `/effect clear` (`EffectCommands`)."
  def effect(%{literals: ["clear"]} = arguments, source), do: effect_clear(arguments, source)
  def effect(%{literals: ["give" | _]} = arguments, source), do: effect_give(arguments, source)

  defp effect_give(%{"targets" => selector, "effect" => effect} = arguments, source) do
    id = live_effect!(effect)

    ticks =
      cond do
        Map.has_key?(arguments, "seconds") -> arguments["seconds"] * 20
        "infinite" in arguments.literals -> -1
        true -> 600
      end

    amplifier = Map.get(arguments, "amplifier", 0)
    hide = Map.get(arguments, "hideParticles", false)
    {:ok, incoming} = CommandOps.rung(ticks, amplifier, hide)
    targets = Targets.required_entities(source, selector)
    tracked = on_targets(targets, fn _ -> {:effect, id, incoming} end)
    effect_name = Names.effect(effect)
    seconds = if ticks < 0, do: 0, else: div(ticks, 20)

    total =
      respond(
        source,
        Enum.map(tracked, &{elem(&1, 0), value(elem(&1, 1))}),
        true,
        zero: Error.new("commands.effect.give.failed"),
        single:
          &Text.translatable("commands.effect.give.success.single", [
            effect_name,
            name(&1),
            seconds
          ]),
        multiple: fn count, _ ->
          Text.translatable("commands.effect.give.success.multiple", [effect_name, count, seconds])
        end
      )

    total
  end

  # `/effect clear [<targets> [<effect>]]`.
  defp effect_clear(arguments, source) do
    targets =
      case arguments do
        %{"targets" => selector} -> Targets.required_entities(source, selector)
        _ -> [Source.player!(source)]
      end

    case arguments do
      %{"effect" => effect} ->
        id = live_effect!(effect)
        tracked = on_targets(targets, fn _ -> {:effect, id, :remove} end)
        effect_name = Names.effect(effect)

        total =
          respond(
            source,
            Enum.map(tracked, &{elem(&1, 0), value(elem(&1, 1))}),
            true,
            zero: Error.new("commands.effect.clear.specific.failed"),
            single:
              &Text.translatable("commands.effect.clear.specific.success.single", [
                effect_name,
                name(&1)
              ]),
            multiple: fn count, _ ->
              Text.translatable("commands.effect.clear.specific.success.multiple", [
                effect_name,
                count
              ])
            end
          )

        total

      _ ->
        tracked = on_targets(targets, fn _ -> :clear_effects end)

        total =
          respond(
            source,
            Enum.map(tracked, &{elem(&1, 0), value(elem(&1, 1))}),
            true,
            zero: Error.new("commands.effect.clear.everything.failed"),
            single:
              &Text.translatable("commands.effect.clear.everything.success.single", [name(&1)]),
            multiple: fn count, _ ->
              Text.translatable("commands.effect.clear.everything.success.multiple", [count])
            end
          )

        total
    end
  end

  defp value(true), do: 1
  defp value(_), do: 0

  defp live_effect!(effect) do
    id = EffectTypes.id(effect)

    if id in Valimc.Connection.live_effects(),
      do: id,
      else:
        Error.throw!(%Error{message: Text.literal("The effect #{effect} is not supported yet")})
  end

  # ---- experience ----

  @doc "`/experience add|set <targets> <amount> [points|levels]` and `query`."
  def experience(%{literals: [operation | kind]} = arguments, source) do
    kind = if kind == ["levels"], do: :levels, else: :points
    operation = String.to_existing_atom(operation)

    case arguments do
      %{"target" => selector} when operation == :query ->
        target = Targets.single_player(source, selector)
        value = Remote.run!(target, {:experience, {:query, kind}})
        value = if is_integer(value), do: value, else: 0

        Feedback.success(
          source,
          Text.translatable("commands.experience.query.#{kind}", [name(target), value]),
          false
        )

        value

      %{"target" => selector, "amount" => amount} ->
        targets = Targets.required_players(source, selector)

        tracked = on_targets(targets, fn _ -> {:experience, {operation, amount, kind}} end)

        tracked =
          Enum.map(tracked, fn {target, reply} ->
            {target, if(reply in [:ok, true], do: 1, else: 0)}
          end)

        zero =
          if operation == :set and kind == :points,
            do: Error.new("commands.experience.set.points.invalid")

        total =
          respond(source, tracked, true,
            zero: zero,
            single:
              &Text.translatable("commands.experience.#{operation}.#{kind}.success.single", [
                amount,
                name(&1)
              ]),
            multiple: fn count, _ ->
              Text.translatable("commands.experience.#{operation}.#{kind}.success.multiple", [
                amount,
                count
              ])
            end
          )

        total
    end
  end

  # ---- kill ----

  @doc "`/kill [<targets>]` (`KillCommand`): players die by `genericKill`."
  def kill(arguments, source) do
    targets =
      case arguments do
        %{"targets" => selector} -> Targets.required_entities(source, selector)
        _ -> [Source.player!(source)]
      end

    tracked = on_targets(targets, fn _ -> :kill end)

    total =
      respond(source, Enum.map(tracked, &{elem(&1, 0), 1}), true,
        single: &Text.translatable("commands.kill.success.single", [name(&1)]),
        multiple: fn count, _ -> Text.translatable("commands.kill.success.multiple", [count]) end
      )

    total
  end

  defp f32(value), do: Valimc.Command.Reader.to_float32(value)

  # `Mth.wrapDegrees` for floats.
  defp wrap(degrees) do
    degrees = :math.fmod(degrees * 1.0, 360.0)
    degrees = if degrees >= 180.0, do: degrees - 360.0, else: degrees
    if degrees < -180.0, do: degrees + 360.0, else: degrees
  end
end
