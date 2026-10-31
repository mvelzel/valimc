defmodule Valimc.Living do
  @moduledoc """
  The state every living entity has (vanilla `LivingEntity`): health and its
  hurt timers, golden-heart absorption, status effects, burning, air and
  freezing. Players hold it as one field; mobs will too. The rules are in
  `Valimc.Living.*` (health, damage and its sources, effects, attributes, armor,
  air, burning, freezing); owners commit and replicate their outcomes.
  """
  alias Valimc.Living.{Air, Burning, Effects, Freezing, Health}

  defstruct health: %Health{},
            # Transient admission time for dragon wing contacts (lastHurtByMobTimestamp).
            last_mob_hurt: nil,
            absorption: 0.0,
            effects: %{},
            fire_ticks: 0,
            air_supply: 300,
            freezing: %Freezing{}

  @type t :: %__MODULE__{}

  def valid?(%__MODULE__{} = living),
    do:
      Health.valid?(living.health) and Health.valid_absorption?(living.absorption) and
        Effects.valid?(living.effects) and Burning.valid?(living.fire_ticks) and
        Air.valid?(living.air_supply) and Freezing.valid_ticks?(living.freezing.frozen_ticks)

  def valid?(_), do: false

  @doc """
  The living state saved in a player file: health, absorption, effects, fire,
  air and frozen ticks, each optional in older files; absorption is clamped to
  the restored effects' maximum, and health to Health Boost's.
  """
  def restore(saved) do
    effects = Map.get(saved, :effects, %{})

    maximum =
      if Effects.valid?(effects), do: Valimc.Living.Attributes.max_health(effects), else: 20.0

    with {:ok, health} <- Health.restore(Map.get(saved, :health), maximum) do
      {:ok,
       %__MODULE__{
         health: health,
         effects: effects,
         absorption: Health.reconcile_absorption(Map.get(saved, :absorption, 0.0), effects),
         fire_ticks: Map.get(saved, :fire_ticks, 0),
         air_supply: Map.get(saved, :air_supply, Air.maximum()),
         freezing: %Freezing{frozen_ticks: Map.get(saved, :frozen_ticks, 0)}
       }}
    end
  end

  @doc "The fields `restore/1` reads, as a player file stores them."
  def saved(%__MODULE__{} = living) do
    {:ok, health} = Health.saved(living.health)

    %{
      health: health,
      absorption: living.absorption,
      effects: living.effects,
      fire_ticks: living.fire_ticks,
      air_supply: living.air_supply,
      frozen_ticks: living.freezing.frozen_ticks
    }
  end

  @doc "Advance hurt timers and the freezing clock on the owner's admitted tick."
  def tick(%__MODULE__{} = living, alive),
    do: %{
      living
      | health: Health.tick(living.health),
        freezing: Freezing.tick(living.freezing, alive)
    }

  @doc "At death: burning stops (a cooldown is kept) and the freezing clock resets."
  def die(%__MODULE__{} = living),
    do: %{
      living
      | fire_ticks: min(0, living.fire_ticks),
        freezing: Freezing.tick(living.freezing, false)
    }

  @doc "A respawned body: full health without effects (no Health Boost), nothing else carried over."
  def respawn(%__MODULE__{}), do: %__MODULE__{}

  @doc "Whether something about the body needs the per-tick environment sample."
  def environment_active?(%__MODULE__{} = living),
    do:
      Freezing.active?(living.freezing) or living.fire_ticks > 0 or
        living.air_supply < Air.maximum()
end
