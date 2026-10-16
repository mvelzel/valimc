defmodule Valimc.StatusEffect do
  @moduledoc "Bounded immutable priority stack for one effect kind; gameplay hooks and owner storage are separate."
  @type rung :: {integer(), 0..255, boolean(), boolean(), boolean()}
  @type t :: [rung()]
  # Active first, then strictly weaker suppressed levels. Each compact tuple is
  # {remaining ticks, amplifier, ambient, particles, icon}; -1 means infinite.
  @maximum 2_147_483_647

  def new(ticks, amplifier, ambient \\ false, particles \\ true, icon \\ true) do
    rung = {ticks, amplifier, ambient, particles, icon}
    if rung?(rung), do: {:ok, [rung]}, else: {:error, :invalid_status_effect}
  end

  def valid?([_ | _] = state), do: ordered?(state, 256)

  def valid?(_), do: false

  @doc "Refresh state; notification can be false even when suppressed state changes."
  def refresh(state, [incoming]) do
    if valid?(state) and rung?(incoming),
      do: merge(state, incoming),
      else: {:error, :invalid_status_effect}
  end

  def refresh(_, _), do: {:error, :invalid_status_effect}

  @doc "Advance one logical tick, returning remaining/promotion flags without executing gameplay actions."
  def tick(state) do
    if valid?(state) do
      [head | _] = state

      if remaining?(head) do
        [head | tail] = Enum.map(state, &decrement/1)
        promoted = elem(head, 0) == 0 and tail != []
        next = if promoted, do: tail, else: [head | tail]
        {:ok, next, remaining?(hd(next)), promoted}
      else
        {:ok, state, false, false}
      end
    else
      {:error, :invalid_status_effect}
    end
  end

  defp merge([head | tail] = state, incoming) do
    {ticks, level, ambient, particles, icon} = head
    {new_ticks, new_level, new_ambient, new_particles, new_icon} = incoming

    {ticks, level, tail, notify} =
      cond do
        new_level > level ->
          {new_ticks, new_level, if(shorter?(incoming, head), do: state, else: tail), true}

        shorter?(head, incoming) and new_level == level ->
          {new_ticks, level, tail, true}

        shorter?(head, incoming) ->
          updated =
            case tail do
              [] ->
                [incoming]

              _ ->
                {:ok, updated, _notify} = merge(tail, incoming)
                updated
            end

          {ticks, level, updated, false}

        true ->
          {ticks, level, tail, false}
      end

    ambient_changed = notify or (ambient and not new_ambient)
    next_ambient = if ambient_changed, do: new_ambient, else: ambient
    notify = ambient_changed or particles != new_particles or icon != new_icon
    {:ok, [{ticks, level, next_ambient, new_particles, new_icon} | tail], notify}
  end

  defp remaining?({ticks, _, _, _, _}), do: ticks == -1 or ticks > 0
  defp shorter?({a, _, _, _, _}, {b, _, _, _, _}), do: a != -1 and (b == -1 or a < b)

  defp decrement({ticks, level, ambient, particles, icon}),
    do: {if(ticks in [-1, 0], do: ticks, else: ticks - 1), level, ambient, particles, icon}

  defp ordered?([], _), do: true

  defp ordered?([{_, level, _, _, _} = rung | tail], higher),
    do: rung?(rung) and level < higher and ordered?(tail, level)

  defp ordered?(_, _), do: false

  defp rung?({ticks, level, ambient, particles, icon}),
    do:
      is_integer(ticks) and ticks in -1..@maximum and is_integer(level) and level in 0..255 and
        is_boolean(ambient) and is_boolean(particles) and is_boolean(icon)

  defp rung?(_), do: false
end
