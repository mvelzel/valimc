defmodule Valimc.Physics.StuckContact do
  @moduledoc "Ordered slowing contacts from fenced states; player owners apply effects on their tick."
  alias Valimc.World.View

  alias Valimc.Physics.{
    CollisionContext,
    Kernel,
    PlayerPose,
    StuckMotion
  }

  alias Valimc.Registry.BlockFacts

  defstruct pose: :standing,
            feet: {0.5, 64.0, 0.5},
            flying: false,
            spectator: false,
            weaving: false

  def sample(frame, from, to, context, facts),
    do: sample_paths(frame, [%{from: from, to: to, axis: nil}], context, facts)

  @doc "One logical tick's bounded recorded movements; hit positions are shared across the batch."
  def sample_paths(%View{} = frame, paths, context, %__MODULE__{} = facts)
      when is_list(paths) and length(paths) <= 101 do
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
           Valimc.Physics.BodyPaths.reduce(
             paths,
             facts.pose,
             %{context: context, last: nil, seen: MapSet.new()},
             fn acc, pos, step, body, delta ->
               visit(frame, pos, step, body, delta, facts, feet, acc)
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

  defp hit?(:powder_snow, state, pos, body, movement, context),
    do: {:ok, Kernel.inside_shape?(state, pos, context, body, movement)}

  defp at(%View{} = view, pos) do
    case View.fetch(view, pos) do
      {:ok, state} -> {:ok, state, BlockFacts.stuck(state)}
      :error -> {:error, :incomplete_stuck_frame}
    end
  end

  defp floor_point({x, y, z}), do: {floor(x), floor(y), floor(z)}
end
