defmodule Valimc.Physics.StuckContact do
  @moduledoc "Ordered slowing contacts from fenced states; player owners apply effects on their tick."
  alias Valimc.Physics.{
    BlockCollisions.Frame,
    BlockShapes,
    BodySweep,
    Box,
    CollisionContext,
    PlayerPose,
    Shape,
    StuckBlocks,
    StuckMotion
  }

  @epsilon 9.999999747378752e-6
  defstruct pose: :standing,
            feet: {0.5, 64.0, 0.5},
            flying: false,
            spectator: false,
            weaving: false

  def sample(frame, from, to, context, facts),
    do: sample_paths(frame, [%{from: from, to: to, axis: nil}], context, facts)

  @doc "One logical tick's bounded recorded movements; hit positions are shared across the batch."
  def sample_paths(%Frame{states: states} = frame, paths, context, %__MODULE__{} = facts)
      when is_map(states) and map_size(states) <= 2048 and is_list(paths) and length(paths) <= 101 do
    if CollisionContext.valid?(context) and context.entity_present and
         Enum.all?([facts.flying, facts.spectator, facts.weaving], &is_boolean/1) do
      if facts.flying or facts.spectator or paths == [] do
        {:ok, %{multiplier: nil, reset_fall: false, last: nil}}
      else
        resolve_paths(frame, paths, context, facts)
      end
    else
      {:error, :invalid_stuck_context}
    end
  end

  def sample_paths(_, _, _, _), do: {:error, :invalid_stuck_frame}

  defp resolve_paths(frame, paths, context, facts) do
    with {:ok, _} <- PlayerPose.geometry(facts.pose, facts.feet),
         {:ok, _, feet} <- at(frame, floor_point(facts.feet)),
         {:ok, acc} <-
           Enum.reduce_while(
             paths,
             {:ok, %{context: context, last: nil, seen: MapSet.new(), attempts: 0}},
             fn path, {:ok, acc} ->
               case movement(frame, path, facts, feet, acc) do
                 {:ok, acc} -> {:cont, {:ok, acc}}
                 error -> {:halt, error}
               end
             end
           ) do
      {:ok,
       %{
         multiplier: if(acc.last, do: acc.last.multiplier),
         reset_fall: acc.last != nil,
         last: acc.last
       }}
    end
  end

  defp movement(frame, path, facts, feet, acc) do
    with {:ok, segments, destination} <- segments(path),
         {:ok, {acc, remaining}} <-
           Enum.reduce_while(segments, {:ok, {acc, 16}}, fn {from, to}, {:ok, {acc, budget}} ->
             case line(frame, from, to, facts, feet, acc, budget) do
               {:ok, acc, used} -> {:cont, {:ok, {acc, budget - used}}}
               error -> {:halt, error}
             end
           end) do
      if remaining <= 0 do
        with {:ok, acc, _} <- line(frame, destination, destination, facts, feet, acc, 1),
             do: {:ok, acc}
      else
        {:ok, acc}
      end
    end
  end

  defp segments(%{from: from, to: to} = path) do
    axis = Map.get(path, :axis)

    if point?(from) and point?(to) and (axis == nil or vector?(axis)) and
         vector?(subtract(to, from)) do
      delta = subtract(to, from)

      {dx, dy, dz} = delta

      if axis != nil and dx * dx + dy * dy + dz * dz > 0 do
        order = if abs(elem(axis, 0)) < abs(elem(axis, 2)), do: [1, 2, 0], else: [1, 0, 2]

        {_, segments} =
          Enum.reduce(order, {from, []}, fn i, {current, segments} ->
            d = elem(delta, i)

            if d == 0 do
              {current, segments}
            else
              next = put_elem(current, i, elem(current, i) + d)
              {next, [{current, next} | segments]}
            end
          end)

        {:ok, Enum.reverse(segments), to}
      else
        {:ok, [{from, to}], to}
      end
    else
      {:error, :stuck_contact_limit}
    end
  end

  defp segments(_), do: {:error, :invalid_stuck_path}

  defp line(frame, from, to, facts, feet, acc, budget) do
    with {:ok, before} <- PlayerPose.geometry(facts.pose, from),
         {:ok, after_move} <- PlayerPose.geometry(facts.pose, to),
         {:ok, sweep} <- BodySweep.plan(from, to, deflate(after_move.box)) do
      result =
        Enum.reduce_while(sweep.visits, {:ok, acc, 0}, fn {pos, step}, {:ok, acc, last_step} ->
          cond do
            step >= budget ->
              {:halt, {:budget, acc, last_step}}

            acc.attempts >= 4096 ->
              {:halt, {:error, :stuck_contact_limit}}

            true ->
              acc = %{acc | attempts: acc.attempts + 1}

              case visit(frame, pos, step, before.box, subtract(to, from), facts, feet, acc) do
                {:ok, acc} -> {:cont, {:ok, acc, step}}
                error -> {:halt, error}
              end
          end
        end)

      case result do
        {:budget, acc, step} -> {:ok, acc, step + 1}
        {:ok, acc, step} when sweep.complete -> {:ok, acc, step + 1}
        {:ok, _, _} -> {:error, :stuck_contact_limit}
        error -> error
      end
    end
  end

  defp visit(frame, pos, step, body, delta, facts, feet, acc) do
    if MapSet.member?(acc.seen, pos) do
      {:ok, acc}
    else
      with {:ok, state, kind} <- at(frame, pos),
           {:ok, hit} <- hit?(kind, state, pos, body, delta, acc.context),
           {:ok, effect} <-
             StuckMotion.player_contact(
               if(hit, do: kind, else: :none),
               facts.weaving,
               feet == :powder_snow,
               false
             ) do
        acc = if hit, do: %{acc | seen: MapSet.put(acc.seen, pos)}, else: acc

        if effect.reset_fall do
          last = %{
            position: pos,
            state: state,
            kind: kind,
            step: step,
            multiplier: effect.multiplier
          }

          {:ok, %{acc | context: %{acc.context | fall_distance: 0.0}, last: last}}
        else
          {:ok, acc}
        end
      end
    end
  end

  defp hit?(:none, _, _, _, _, _), do: {:ok, false}
  defp hit?(kind, _, _, _, _, _) when kind in [:cobweb, :berry_bush], do: {:ok, true}

  defp hit?(:powder_snow, state, pos, body, movement, context) do
    with {:ok, shape} <- BlockShapes.fetch(state, pos, context) do
      if Shape.empty?(shape) or shape.full_block,
        do: {:ok, true},
        else:
          {:ok, Box.collided_along?(body, movement, Enum.map(shape.boxes, &Box.move(&1, pos)))}
    end
  end

  defp at(%Frame{states: states}, pos) do
    with {:ok, state} <- Map.fetch(states, pos),
         {:ok, kind} <- StuckBlocks.fetch(state),
         do: {:ok, state, kind},
         else: (
           :error -> {:error, :incomplete_stuck_frame}
           error -> error
         )
  end

  defp deflate({a, b, c, d, e, f}),
    do:
      Box.new(
        {a + @epsilon, b + @epsilon, c + @epsilon, d - @epsilon, e - @epsilon, f - @epsilon}
      )

  defp point?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 60_000_000))
  defp point?(_), do: false
  defp vector?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
  defp vector?(_), do: false
  defp floor_point({x, y, z}), do: {floor(x), floor(y), floor(z)}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
end
