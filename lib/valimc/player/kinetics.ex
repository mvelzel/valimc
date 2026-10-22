defmodule Valimc.Player.Kinetics do
  @moduledoc """
  The player's server velocity around the physics kernel (VMC-077l2): its
  saved bounds, what invalidates a sampled tick, and whether a server impulse
  fits the kernel's query bounds. The travel rules themselves run in Rust
  (`valimc_core::physics::player`).
  """
  import Bitwise
  alias Valimc.Player.Motion
  alias Valimc.Living.Attributes
  alias Valimc.Physics.Kernel

  def velocity(player), do: Map.get(player, :motion, %Motion{}).velocity

  def valid_velocity?({x, y, z}),
    do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))

  def valid_velocity?(_), do: false

  @doc "Native saved Motion load bound, independent for each component."
  def restore_velocity(velocity) do
    if valid_velocity?(velocity) do
      {:ok,
       velocity
       |> Tuple.to_list()
       |> Enum.map(&if(abs(&1) > 10.0, do: 0.0, else: &1 * 1.0))
       |> List.to_tuple()}
    else
      {:error, :invalid_velocity}
    end
  end

  def signature(player) do
    motion = Map.get(player, :motion, %Motion{})
    sprint = (player.input.shared_flags &&& 8) != 0

    {motion.velocity, motion.physical_ground, motion.on_ground, motion.swimming, motion.paths,
     motion.known_movement, motion.stuck_multiplier, sprint, player.input.buttons,
     Valimc.Player.Input.loaded?(player.input), Map.get(player, :yaw, 0.0),
     if(motion.swimming or sprint, do: Map.get(player, :pitch, 0.0)),
     Attributes.jump_boost_level(effects(player)), Attributes.travel_signature(effects(player))}
  end

  @doc "Whether a server impulse `velocity` keeps the player's tick within the query bounds."
  def admissible?(player, velocity) do
    motion = %{player.motion | velocity: velocity}

    case Kernel.player_query(%{player | motion: motion}, nil) do
      {:ok, query} -> Kernel.bounded?(query)
      {:error, _} -> false
    end
  end

  # Bodies without living state (bare physics fixtures) have no effects.
  defp effects(player), do: Map.get(player, :living, %Valimc.Living{}).effects
end
