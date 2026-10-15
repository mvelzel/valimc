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

  def sample(%Frame{states: states} = frame, from, to, context, %__MODULE__{} = facts)
      when is_map(states) and map_size(states) <= 2048 do
    if CollisionContext.valid?(context) and context.entity_present and
         Enum.all?([facts.flying, facts.spectator, facts.weaving], &is_boolean/1) do
      if facts.flying or facts.spectator do
        {:ok, %{multiplier: nil, reset_fall: false, last: nil}}
      else
        resolve(frame, from, to, context, facts)
      end
    else
      {:error, :invalid_stuck_context}
    end
  end

  def sample(_, _, _, _, _), do: {:error, :invalid_stuck_frame}

  defp resolve(frame, from, to, context, facts) do
    with {:ok, before} <- PlayerPose.geometry(facts.pose, from),
         {:ok, after_move} <- PlayerPose.geometry(facts.pose, to),
         {:ok, _} <- PlayerPose.geometry(facts.pose, facts.feet),
         {:ok, %{complete: true, visits: visits}} <-
           BodySweep.plan(from, to, deflate(after_move.box)),
         {:ok, _, feet} <- at(frame, floor_point(facts.feet)),
         {:ok, {_context, last}} <-
           Enum.reduce_while(visits, {:ok, {context, nil}}, fn {pos, step},
                                                               {:ok, {context, last}} ->
             with {:ok, state, kind} <- at(frame, pos),
                  {:ok, hit} <- hit?(kind, state, pos, before.box, subtract(to, from), context),
                  {:ok, effect} <-
                    StuckMotion.player_contact(
                      if(hit, do: kind, else: :none),
                      facts.weaving,
                      feet == :powder_snow,
                      false
                    ) do
               if effect.reset_fall do
                 last = %{
                   position: pos,
                   state: state,
                   kind: kind,
                   step: step,
                   multiplier: effect.multiplier
                 }

                 {:cont, {:ok, {%{context | fall_distance: 0.0}, last}}}
               else
                 {:cont, {:ok, {context, last}}}
               end
             else
               error -> {:halt, error}
             end
           end) do
      {:ok, %{multiplier: if(last, do: last.multiplier), reset_fall: last != nil, last: last}}
    else
      {:ok, %{complete: false}} -> {:error, :stuck_contact_limit}
      error -> error
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

  defp floor_point({x, y, z}), do: {floor(x), floor(y), floor(z)}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}
end
