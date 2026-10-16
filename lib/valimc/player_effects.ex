defmodule Valimc.PlayerEffects do
  @moduledoc "Bounded per-player duration map; actions, attributes, eligibility and live ownership are separate."
  alias Valimc.StatusEffect
  alias Valimc.Protocol.EffectTypes

  def valid?(effects) when is_map(effects) and map_size(effects) <= 40,
    do:
      Enum.all?(effects, fn {id, state} ->
        EffectTypes.valid_id?(id) and StatusEffect.valid?(state)
      end)

  def valid?(_), do: false

  @doc "Refresh one effect; storage may change even when notification is false."
  def add(effects, id, [_] = incoming) do
    if valid?(effects) and EffectTypes.valid_id?(id) and StatusEffect.valid?(incoming) do
      {next, changed} =
        case Map.fetch(effects, id) do
          :error ->
            {incoming, true}

          {:ok, previous} ->
            {:ok, next, changed} = StatusEffect.refresh(previous, incoming)
            {next, changed}
        end

      {:ok, Map.put(effects, id, next), changed}
    else
      {:error, :invalid_player_effects}
    end
  end

  def add(_, _, _), do: {:error, :invalid_player_effects}

  def remove(effects, id) do
    if valid?(effects) and EffectTypes.valid_id?(id),
      do: {:ok, Map.delete(effects, id), Map.has_key?(effects, id)},
      else: {:error, :invalid_player_effects}
  end

  @doc "Advance duration state and return ordered removal/update notifications; no gameplay actions run."
  def tick(effects) do
    if valid?(effects) do
      {next, events} =
        effects
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reduce({%{}, []}, fn id, {next, events} ->
          {:ok, state, remains, promoted} = StatusEffect.tick(effects[id])
          events = if promoted, do: [{:update, id, true} | events], else: events

          if remains do
            # Native periodically refreshes the controlling client's duration.
            events =
              if rem(elem(hd(state), 0), 600) == 0,
                do: [{:update, id, false} | events],
                else: events

            {Map.put(next, id, state), events}
          else
            {next, [{:remove, id, false} | events]}
          end
        end)

      {:ok, next, Enum.reverse(events)}
    else
      {:error, :invalid_player_effects}
    end
  end
end
