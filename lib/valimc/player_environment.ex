defmodule Valimc.PlayerEnvironment do
  @moduledoc "Player-owned freeze state; contact comes from complete fenced body samples."
  alias Valimc.Physics.{BlockShapes, Box}
  @tags Path.expand("../../priv/protocol/tags.json", __DIR__)
  @external_resource @tags
  @immune :json.decode(File.read!(@tags))["minecraft:item"]["minecraft:freeze_immune_wearables"]
          |> MapSet.new()
  @epsilon 9.999999747378752e-6
  defstruct powder_snow: false, frozen_ticks: 0, damage_phase: 0, damage_due: false

  def valid_ticks?(value), do: is_integer(value) and value in 0..140
  def frozen(player), do: Map.get(player, :environment, %__MODULE__{}).frozen_ticks
  def active?(%__MODULE__{} = env), do: env.powder_snow or env.frozen_ticks > 0

  @doc "Advance only on the player's admitted clock; delayed geometry retains at most one consequence."
  def tick(%__MODULE__{} = env, true) do
    phase = rem(env.damage_phase + 1, 40)
    %{env | damage_phase: phase, damage_due: env.damage_due or phase == 0}
  end

  def tick(%__MODULE__{} = env, false), do: %{env | damage_phase: 0, damage_due: false}

  @doc "Consume against a fresh body sample and current gear; body clock phase is deliberately unsaved."
  def consume_damage(%__MODULE__{damage_due: false} = env, _allowed), do: {false, env}

  def consume_damage(%__MODULE__{} = env, allowed) when is_boolean(allowed),
    do: {env.frozen_ticks >= 140 and allowed, %{env | damage_due: false}}

  def freeze_effect(ticks, allowed) when ticks in 0..140 and is_boolean(allowed),
    do: if(allowed, do: min(140, ticks + 1), else: ticks)

  def can_freeze?(player, inventory) do
    player.game_mode.current != :spectator and
      not Enum.any?(5..8, fn slot ->
        case inventory.slots[slot] do
          nil -> false
          stack -> MapSet.member?(@immune, stack.item_id)
        end
      end)
  end

  def observe(%__MODULE__{} = env, powder, due, immune)
      when is_boolean(powder) and is_boolean(due) and is_boolean(immune) do
    next =
      if due do
        if powder and not immune,
          do: freeze_effect(env.frozen_ticks, true),
          else: max(0, env.frozen_ticks - 2)
      else
        env.frozen_ticks
      end

    %{env | powder_snow: powder, frozen_ticks: next}
  end

  def sample(%Valimc.World.View{} = view, box) do
    if Box.valid?(box) do
      {a, b, c, d, e, f} = box
      {x0, y0, z0} = {floor(a + @epsilon), floor(b + @epsilon), floor(c + @epsilon)}
      {x1, y1, z1} = {floor(d - @epsilon), floor(e - @epsilon), floor(f - @epsilon)}
      count = (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1)

      if a + @epsilon < d - @epsilon and b + @epsilon < e - @epsilon and
           c + @epsilon < f - @epsilon and count in 1..512 do
        positions = for x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z}

        states = Enum.map(positions, &Valimc.World.View.fetch(view, &1))

        if Enum.all?(states, &match?({:ok, _}, &1)) do
          {:ok,
           Enum.any?(states, fn {:ok, state} ->
             BlockShapes.fetch(state) == {:context_required, "minecraft:powder_snow"}
           end)}
        else
          {:error, :incomplete_environment_frame}
        end
      else
        {:error, :environment_body_limit}
      end
    else
      {:error, :invalid_environment_body}
    end
  end
end
