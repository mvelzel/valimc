defmodule Valimc.Living.Effects do
  @moduledoc """
  Status effects of a living entity (vanilla `MobEffectInstance` and the
  entity's active-effect map): instances, the bounded map and its storage form,
  the effects the live game applies, and the actions effects request (instant
  drinks, periodic health, Hunger exhaustion, consume effects of stock food,
  milk and honey). Requests are pure; the owner applies health, food and
  durability.

  An instance is a priority stack of rungs, active first, then strictly weaker
  suppressed levels. Each rung is `{remaining ticks, amplifier, ambient,
  particles, icon}`; -1 ticks is infinite.
  """
  alias Valimc.Data.Float32
  use Valimc.Data.Facts, "protocol/consume_status.json"

  import Bitwise
  alias Valimc.Living.FoodItems
  alias Valimc.Living.Health
  alias Valimc.Data.EffectTypes
  alias Valimc.Protocol.{ItemStack, ItemTypes}

  @type rung :: {integer(), 0..255, boolean(), boolean(), boolean()}
  @type instance :: [rung()]
  @maximum 2_147_483_647
  @max_bytes 1 + 40 * (3 + 256 * 6)

  @periodic Enum.sort(Enum.map(~w(regeneration hunger poison wither), &EffectTypes.id/1))
  @live Enum.map(
          ~w(fire_resistance resistance absorption water_breathing speed slowness nausea
            jump_boost slow_falling levitation night_vision blindness darkness mining_fatigue
            dolphins_grace),
          &EffectTypes.id/1
        ) ++ @periodic
  @heal EffectTypes.id("instant_health")
  @harm EffectTypes.id("instant_damage")
  @saturation EffectTypes.id("saturation")
  @regeneration EffectTypes.id("regeneration")
  @poison EffectTypes.id("poison")
  @wither EffectTypes.id("wither")
  @periods %{@regeneration => 50, @poison => 25, @wither => 40}
  @hunger_coefficient 0.004999999888241291
  @milk ItemTypes.id("milk_bucket")
  @honey ItemTypes.id("honey_bottle")

  @stock_food Map.new(@facts["items"], fn item ->
                callbacks =
                  Enum.map(item["callbacks"], fn callback ->
                    effects =
                      Enum.map(callback["effects"], fn effect ->
                        {effect["id"], [List.to_tuple(effect["rung"])]}
                      end)

                    %{probability: callback["probability"], effects: effects}
                  end)

                {item["item_id"], callbacks}
              end)

  @doc """
  The status effects the live game applies, by registry id; others are refused
  (login, commands, consumption). Besides those with server mechanics, this holds
  effects whose only role without mobs is to be stored, ticked and sent: night
  vision, blindness and darkness are drawn by the client; Mining Fatigue
  slows mining and attacks, Dolphin's Grace swimming (VMC-043e). Glowing and
  invisibility need replicated entity flags; haste, strength and the like need
  their mechanics, so they stay out.
  """
  def live, do: @live

  @doc "Effects with periodic actions, in the native action order."
  def periodic_ids, do: @periodic

  # ---- instances ----

  @doc "A fresh one-rung instance."
  def new(ticks, amplifier, ambient \\ false, particles \\ true, icon \\ true) do
    rung = {ticks, amplifier, ambient, particles, icon}
    if rung?(rung), do: {:ok, [rung]}, else: {:error, :invalid_status_effect}
  end

  def valid_instance?([_ | _] = instance), do: ordered?(instance, 256)
  def valid_instance?(_), do: false

  @doc "Refresh an instance; notification can be false even when suppressed rungs change."
  def refresh(instance, [incoming]) do
    if valid_instance?(instance) and rung?(incoming),
      do: merge(instance, incoming),
      else: {:error, :invalid_status_effect}
  end

  def refresh(_, _), do: {:error, :invalid_status_effect}

  @doc "Advance one tick: `{:ok, instance, remaining?, promoted?}`; no gameplay actions run."
  def tick_instance(instance) do
    if valid_instance?(instance) do
      [head | _] = instance

      if remaining?(head) do
        [head | tail] = Enum.map(instance, &decrement/1)
        promoted = elem(head, 0) == 0 and tail != []
        next = if promoted, do: tail, else: [head | tail]
        {:ok, next, remaining?(hd(next)), promoted}
      else
        {:ok, instance, false, false}
      end
    else
      {:error, :invalid_status_effect}
    end
  end

  defp merge([head | tail] = instance, incoming) do
    {ticks, level, ambient, particles, icon} = head
    {new_ticks, new_level, new_ambient, new_particles, new_icon} = incoming

    {ticks, level, tail, notify} =
      cond do
        new_level > level ->
          {new_ticks, new_level, if(shorter?(incoming, head), do: instance, else: tail), true}

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

  # ---- the effect map ----

  def max_bytes, do: @max_bytes

  def valid?(effects) when is_map(effects) and map_size(effects) <= 40,
    do:
      Enum.all?(effects, fn {id, instance} ->
        EffectTypes.valid_id?(id) and valid_instance?(instance)
      end)

  def valid?(_), do: false

  @doc "Refresh one effect; storage may change even when notification is false."
  def add(effects, id, [_] = incoming) do
    if valid?(effects) and EffectTypes.valid_id?(id) and valid_instance?(incoming) do
      {next, changed} =
        case Map.fetch(effects, id) do
          :error ->
            {incoming, true}

          {:ok, previous} ->
            {:ok, next, changed} = refresh(previous, incoming)
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

  @doc "Advance durations and return ordered removal/update notifications; no gameplay actions run."
  def tick(effects) do
    if valid?(effects) do
      {next, events} =
        effects
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reduce({%{}, []}, fn id, {next, events} ->
          {:ok, instance, remains, promoted} = tick_instance(effects[id])
          events = if promoted, do: [{:update, id, hd(instance), true} | events], else: events

          if remains do
            # Native periodically refreshes the controlling client's duration.
            events =
              if rem(elem(hd(instance), 0), 600) == 0,
                do: [{:update, id, hd(instance), false} | events],
                else: events

            {Map.put(next, id, instance), events}
          else
            {next, [{:remove, id} | events]}
          end
        end)

      {:ok, next, Enum.reverse(events)}
    else
      {:error, :invalid_player_effects}
    end
  end

  @doc "Canonical bounded storage payload; an internal format, not vanilla effect NBT."
  def encode(effects) do
    if valid?(effects) do
      entries =
        for {id, instance} <- Enum.sort(effects) do
          rungs =
            for {ticks, level, ambient, particles, icon} <- instance do
              flags =
                if(ambient, do: 1, else: 0) + if(particles, do: 2, else: 0) +
                  if(icon, do: 4, else: 0)

              <<ticks::signed-32, level, flags>>
            end

          [<<id, length(instance)::16>>, rungs]
        end

      {:ok, IO.iodata_to_binary([<<map_size(effects)>>, entries])}
    else
      {:error, :invalid_player_effects}
    end
  end

  @doc "Read one bounded payload, retaining the enclosing remainder."
  def take(<<count, rest::binary>>) when count <= 40, do: take_entries(count, rest, %{}, -1)
  def take(_), do: {:error, :invalid_player_effects}

  defp take_entries(0, rest, effects, _previous), do: {:ok, effects, rest}

  defp take_entries(count, <<id, rungs::16, rest::binary>>, effects, previous)
       when id > previous and id < 40 and rungs in 1..256 do
    bytes = rungs * 6

    with <<encoded::binary-size(^bytes), tail::binary>> <- rest,
         {:ok, instance} <- take_rungs(encoded, []),
         true <- valid_instance?(instance) do
      take_entries(count - 1, tail, Map.put(effects, id, instance), id)
    else
      _ -> {:error, :invalid_player_effects}
    end
  end

  defp take_entries(_, _, _, _), do: {:error, :invalid_player_effects}
  defp take_rungs(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp take_rungs(<<ticks::signed-32, level, flags, rest::binary>>, acc)
       when ticks >= -1 and flags < 8 do
    rung = {ticks, level, band(flags, 1) != 0, band(flags, 2) != 0, band(flags, 4) != 0}
    take_rungs(rest, [rung | acc])
  end

  defp take_rungs(_, _), do: {:error, :invalid_player_effects}

  # ---- actions ----

  @doc "An instant drink's request: `{:eat, nutrition, saturation}`, `{:heal, amount}` or `{:hurt, type, amount}`."
  def instant(@saturation, amplifier) when amplifier in 0..255,
    do: {:ok, {:eat, amplifier + 1, (amplifier + 1) * 2.0}}

  def instant(id, amplifier) when id in [@heal, @harm] and amplifier in 0..255 do
    amount = instant_amount(if(id == @heal, do: 4, else: 6), amplifier)
    {:ok, if(id == @heal, do: {:heal, amount}, else: {:hurt, :indirect_magic, amount})}
  end

  def instant(_, _), do: {:error, :invalid_instant_effect}

  defp instant_amount(base, amplifier) do
    unsigned = band(bsl(base, band(amplifier, 31)), 0xFFFFFFFF)
    signed = if unsigned >= 0x80000000, do: unsigned - 0x100000000, else: unsigned
    # Native instantaneous delivery rounds a signed int shift using double+0.5,
    # JVM d2i truncation, then casts the request to float (including negatives).
    integer = signed |> Kernel.+(0.5) |> trunc()
    Float32.round(integer)
  end

  @doc "A periodic effect's health request from its active head, before duration decrement."
  def periodic(id, [_ | _] = instance, age, %Health{} = health)
      when is_integer(age) and age in -2_147_483_648..2_147_483_647 do
    if EffectTypes.valid_id?(id) and valid_instance?(instance) and Health.valid?(health) do
      [{duration, amplifier, _, _, _} | _] = instance
      phase = if duration == -1, do: age, else: duration
      period = Map.get(@periods, id)

      action =
        if period != nil and duration != 0 and due?(period, amplifier, phase),
          do: periodic_action(id, health),
          else: :none

      {:ok, action}
    else
      {:error, :invalid_periodic_effect}
    end
  end

  def periodic(_, _, _, _), do: {:error, :invalid_periodic_effect}

  defp due?(base, amplifier, phase) do
    # JVM ishr masks the distance even for native amplifier 32..255.
    period = bsr(base, band(amplifier, 31))
    period <= 0 or rem(phase, period) == 0
  end

  defp periodic_action(@regeneration, %{value: value, maximum: maximum}) when value < maximum,
    do: {:heal, 1.0}

  defp periodic_action(@poison, %{value: value}) when value > 1, do: {:hurt, :magic, 1.0}
  defp periodic_action(@wither, _), do: {:hurt, :wither, 1.0}
  defp periodic_action(_, _), do: :none

  @doc "The active Hunger head's exhaustion request; ability gates and food stay with the owner."
  def hunger([head | _] = instance) do
    if valid_instance?(instance) do
      {ticks, amp, _, _, _} = head
      amount = Float32.round(@hunger_coefficient * (amp + 1))
      {:ok, if(ticks == 0, do: :none, else: {:exhaust, amount})}
    else
      {:error, :invalid_hunger_effect}
    end
  end

  def hunger(_), do: {:error, :invalid_hunger_effect}

  # ---- consume effects (stock food, milk, honey) ----

  @doc "A stock food's pinned callback groups, or `:unsupported` when its consumable was changed."
  def food_policy(%ItemStack{item_id: id}, %{consumable: consumable, other_listeners: []}) do
    if consumable != nil and consumable == FoodItems.defaults(id).consumable and
         Map.has_key?(@stock_food, id),
       do: {:ok, @stock_food[id]},
       else: :unsupported
  end

  def food_policy(_, _), do: :unsupported

  @doc "One native float draw selects an entire ordered callback group, even if no add would notify."
  def food_effects(callbacks, draws) when is_list(callbacks) and is_list(draws) do
    if length(callbacks) == length(draws) and Enum.all?(draws, &valid_draw?/1) do
      effects =
        for {callback, draw} <- Enum.zip(callbacks, draws),
            draw < callback.probability,
            effect <- callback.effects,
            do: effect

      {:ok, effects}
    else
      {:error, :invalid_food_effect_draws}
    end
  end

  def food_effects(_, _), do: {:error, :invalid_food_effect_draws}

  defp valid_draw?(draw) when is_number(draw) and draw >= 0 and draw < 1 do
    Float32.round(draw) == draw
  end

  defp valid_draw?(_), do: false

  @doc "Stock milk (`:all`) and honey (`:poison`) removal; `:unsupported` when changed."
  def removal_policy(%ItemStack{item_id: id}, %{consumable: consumable, other_listeners: []})
      when id in [@milk, @honey] and consumable != nil do
    if consumable == FoodItems.defaults(id).consumable,
      do: {:ok, if(id == @milk, do: :all, else: :poison)},
      else: :unsupported
  end

  def removal_policy(_, _), do: :unsupported

  @doc "Apply a removal policy: the remaining effects and the sorted removed ids."
  def apply_removal(effects, policy) when policy in [:all, :poison] do
    if valid?(effects) do
      removed =
        if policy == :all,
          do: Map.keys(effects),
          else: if(Map.has_key?(effects, @poison), do: [@poison], else: [])

      {:ok, Map.drop(effects, removed), Enum.sort(removed)}
    else
      {:error, :invalid_player_effects}
    end
  end
end
