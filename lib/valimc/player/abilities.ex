defmodule Valimc.Player.Abilities do
  @moduledoc "Owner-controlled abilities; client input may request flight, never permissions."
  import Bitwise

  defstruct invulnerable: false,
            flying: false,
            may_fly: false,
            infinite_materials: false,
            may_build: true,
            flying_speed: 0.05,
            walking_speed: 0.1

  def for_mode(mode, abilities \\ %__MODULE__{})

  def for_mode(:creative, abilities),
    do: %{
      abilities
      | invulnerable: true,
        may_fly: true,
        infinite_materials: true,
        may_build: true
    }

  def for_mode(:spectator, abilities),
    do: %{
      abilities
      | invulnerable: true,
        may_fly: true,
        infinite_materials: false,
        flying: true,
        may_build: false
    }

  def for_mode(mode, abilities) when mode in [:survival, :adventure],
    do: %{
      abilities
      | invulnerable: false,
        may_fly: false,
        infinite_materials: false,
        flying: false,
        may_build: mode == :survival
    }

  def request_flight(%__MODULE__{} = abilities, <<flags>>),
    do: {:ok, %{abilities | flying: (flags &&& 2) != 0 and abilities.may_fly}}

  def request_flight(%__MODULE__{}, _), do: {:error, :invalid_abilities_packet}

  def flags(%__MODULE__{} = abilities) do
    if(abilities.invulnerable, do: 1, else: 0) |||
      if(abilities.flying, do: 2, else: 0) |||
      if(abilities.may_fly, do: 4, else: 0) |||
      if(abilities.infinite_materials, do: 8, else: 0)
  end
end
