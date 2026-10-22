defmodule Valimc.Player.GameMode do
  @moduledoc "Persistent mode identity. Live transition effects belong to their gameplay owners."
  alias Valimc.Player.Abilities
  @modes [:survival, :creative, :adventure, :spectator]
  defstruct current: :creative, previous: nil

  def valid?(mode), do: mode in @modes
  def new(mode) when mode in @modes, do: %__MODULE__{current: mode}
  def id(mode) when mode in @modes, do: Enum.find_index(@modes, &(&1 == mode))
  def from_id(id) when id in 0..3, do: Enum.at(@modes, id)
  # Native network enum lookup maps unknown IDs to survival, unlike save validation.
  def from_id(_), do: :survival
  def parse("survival"), do: {:ok, :survival}
  def parse("creative"), do: {:ok, :creative}
  def parse("adventure"), do: {:ok, :adventure}
  def parse("spectator"), do: {:ok, :spectator}
  def parse(_), do: {:error, :invalid_game_mode}

  def change(%__MODULE__{current: mode} = state, mode), do: {:ok, state}

  def change(%__MODULE__{} = state, mode) when mode in @modes,
    do: {:ok, %__MODULE__{current: mode, previous: state.current}}

  def change(_, _), do: {:error, :invalid_game_mode}

  def abilities(%__MODULE__{current: mode}, flying) when is_boolean(flying),
    do: Abilities.for_mode(mode, %Abilities{flying: flying})

  def encode(%__MODULE__{current: current, previous: previous})
      when current in @modes and (previous == nil or previous in @modes),
      do: {:ok, <<id(current), if(previous == nil, do: 255, else: id(previous))>>}

  def encode(_), do: {:error, :invalid_game_mode}

  def decode(<<current, previous>>)
      when current in 0..3 and (previous in 0..3 or previous == 255),
      do:
        {:ok,
         %__MODULE__{
           current: from_id(current),
           previous: if(previous == 255, do: nil, else: from_id(previous))
         }}

  def decode(_), do: {:error, :invalid_game_mode}
end
