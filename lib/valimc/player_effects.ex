defmodule Valimc.PlayerEffects do
  @moduledoc "Bounded per-player duration map; actions, attributes, eligibility and live ownership are separate."
  alias Valimc.StatusEffect
  alias Valimc.Protocol.EffectTypes
  @max_bytes 1 + 40 * (3 + 256 * 6)

  def max_bytes, do: @max_bytes

  def valid?(effects) when is_map(effects) and map_size(effects) <= 40,
    do:
      Enum.all?(effects, fn {id, state} ->
        EffectTypes.valid_id?(id) and StatusEffect.valid?(state)
      end)

  def valid?(_), do: false

  @doc "Canonical bounded journal payload; this is an internal format, not vanilla effect NBT."
  def encode(effects) do
    if valid?(effects) do
      entries =
        for {id, state} <- Enum.sort(effects) do
          rungs =
            for {ticks, level, ambient, particles, icon} <- state do
              flags =
                if(ambient, do: 1, else: 0) + if(particles, do: 2, else: 0) +
                  if(icon, do: 4, else: 0)

              <<ticks::signed-32, level, flags>>
            end

          [<<id, length(state)::16>>, rungs]
        end

      {:ok, IO.iodata_to_binary([<<map_size(effects)>>, entries])}
    else
      {:error, :invalid_player_effects}
    end
  end

  @doc "Read one bounded payload, retaining the enclosing journal remainder."
  def take(<<count, rest::binary>>) when count <= 40,
    do: take_entries(count, rest, %{}, -1)

  def take(_), do: {:error, :invalid_player_effects}

  defp take_entries(0, rest, effects, _previous), do: {:ok, effects, rest}

  defp take_entries(count, <<id, rungs::16, rest::binary>>, effects, previous)
       when id > previous and id < 40 and rungs in 1..256 do
    bytes = rungs * 6

    with <<encoded::binary-size(^bytes), tail::binary>> <- rest,
         {:ok, state} <- take_rungs(encoded, []),
         true <- StatusEffect.valid?(state) do
      take_entries(count - 1, tail, Map.put(effects, id, state), id)
    else
      _ -> {:error, :invalid_player_effects}
    end
  end

  defp take_entries(_, _, _, _), do: {:error, :invalid_player_effects}
  defp take_rungs(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp take_rungs(<<ticks::signed-32, level, flags, rest::binary>>, acc)
       when ticks >= -1 and flags < 8 do
    rung =
      {ticks, level, Bitwise.band(flags, 1) != 0, Bitwise.band(flags, 2) != 0,
       Bitwise.band(flags, 4) != 0}

    take_rungs(rest, [rung | acc])
  end

  defp take_rungs(_, _), do: {:error, :invalid_player_effects}

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
