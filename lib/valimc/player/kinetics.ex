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

  @dolphins_grace Valimc.Data.EffectTypes.id("dolphins_grace")

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

    case player_query(%{player | motion: motion}, nil) do
      {:ok, query} -> Kernel.bounded?(query)
      {:error, _} -> false
    end
  end

  # Bodies without living state (bare physics fixtures) have no effects.
  defp effects(player), do: Map.get(player, :living, %Valimc.Living{}).effects

  @doc """
  The box a player's move to `target` (or its rest, `target` nil) reads:
  `{:ok, box}`, or `{:error, reason}` past the query bounds.
  """
  def player_query(player, target, flags \\ 0) do
    Valimc.Data.BlockFacts.install!()

    Valimc.Native.physics_player_query(
      player(player),
      target && {target.x * 1.0, target.y * 1.0, target.z * 1.0},
      flags
    )
  end

  @doc """
  Validate `player`'s move packet to `target` (`handleMovePlayer`) over
  `view` (its query box `query`), in one call: the acceptance, pose, swimming, fluid, powder snow
  and eye contact, the packet's and the tick's kinetics, the landing, the
  exhaustion, and the motion after the packet and after the tick.
  """
  def player_move(view, query, player, target, flags) do
    target = {target.x * 1.0, target.y * 1.0, target.z * 1.0}

    with {:ok, entities} <- colliders(view, query, player) do
      Valimc.Native.physics_player_move(
        Kernel.native(view, query),
        player(player),
        target,
        flags,
        border(),
        entities
      )
      |> Kernel.error()
    end
  end

  @doc "Sample a resting `player`'s tick over `view` (its query box `query`), in one call."
  def player_rest(view, query, player) do
    with {:ok, entities} <- colliders(view, query, player) do
      Valimc.Native.physics_player_rest(
        Kernel.native(view, query),
        player(player),
        border(),
        entities
      )
      |> Kernel.error()
    end
  end

  defp colliders(_view, _query, %{game_mode: %{current: :spectator}}), do: {:ok, []}

  defp colliders(view, query, player),
    do: Valimc.World.EntityColliders.collect(view, query, Map.get(player, :entity_id))

  defp border do
    case Valimc.Physics.BorderSnapshot.bounds(Valimc.World.Clock.border_snapshot()) do
      {:ok, bounds} -> bounds
      _ -> nil
    end
  end

  @doc "A player as the kernel takes it (installing the facts its poses come from)."
  def player(player) do
    Valimc.Data.BlockFacts.install!()
    motion = Map.get(player, :motion, %Valimc.Player.Motion{})
    input = Map.get(player, :input, %Valimc.Player.Input{})
    effects = Map.get(player, :living, %Valimc.Living{}).effects
    {slow, levitation} = Valimc.Living.Attributes.travel_signature(effects)
    loaded = Valimc.Player.Input.loaded?(input)
    abilities = Map.get(player, :abilities, %Valimc.Player.Abilities{})

    %{
      position:
        {Map.get(player, :x, 0.0) * 1.0, Map.get(player, :y, 0.0) * 1.0,
         Map.get(player, :z, 0.0) * 1.0},
      yaw: Map.get(player, :yaw, 0.0) * 1.0,
      pitch: Map.get(player, :pitch, 0.0) * 1.0,
      pose: Valimc.Data.PlayerPose.id(Map.get(player, :pose, :standing)),
      motion: %{
        fall_distance: motion.fall_distance * 1.0,
        velocity: floats(motion.velocity),
        physical_ground: motion.physical_ground,
        settled: motion.settled,
        swimming: motion.swimming,
        paths: motion.paths,
        stuck_multiplier: floats(motion.stuck_multiplier),
        known_movement: floats(motion.known_movement),
        on_ground: motion.on_ground,
        horizontal_collision: motion.horizontal_collision,
        received: motion.received
      },
      shift: (input.shared_flags &&& 2) != 0,
      sprint: (input.shared_flags &&& 8) != 0,
      loaded: loaded,
      jump: loaded and Valimc.Player.Input.pressed?(input, :jump),
      sneak: loaded and Valimc.Player.Input.pressed?(input, :shift),
      flying: abilities.flying,
      mode: Map.get(player, :game_mode, Valimc.Player.GameMode.new(:survival)).current,
      invulnerable: abilities.invulnerable,
      jump_boost: Valimc.Living.Attributes.jump_boost_level(effects),
      slow_falling: slow,
      levitation: levitation,
      dolphins_grace: Map.has_key?(effects, @dolphins_grace),
      water_efficiency: water_efficiency(Map.get(player, :equipment, %{}))
    }
  end

  defp floats({x, y, z}), do: {x * 1.0, y * 1.0, z * 1.0}

  # Depth Strider's `water_movement_efficiency` from the boots
  # (`Equipment.capture/1`'s slot 2), VMC-037q.
  defp water_efficiency(%{2 => boots}) do
    Valimc.Living.Armor.enchanted_value(
      Valimc.Living.Armor.attributes(%{feet: boots}),
      "minecraft:water_movement_efficiency"
    ) * 1.0
  end

  defp water_efficiency(_equipment), do: 0.0
end
