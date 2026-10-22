defmodule Valimc.Player.Packets do
  @moduledoc """
  The packets of a player's state (VMC-077r): login and respawn into its
  level, the world spawn, abilities, experience, health and food, its
  permission level, its player-list entry and the metadata peers see.
  """
  alias Valimc.Protocol.{EntityPackets, Packets, Wire}
  import Bitwise

  def login(player) do
    levels = Valimc.World.Dimension.ids()

    Packets.packet("login", [
      <<player.entity_id::signed-32, 0>>,
      Wire.varint(length(levels)),
      Enum.map(levels, &Wire.string(Valimc.World.Dimension.name(&1))),
      Wire.varint(Valimc.config(:max_players)),
      Wire.varint(Valimc.Player.ChunkView.server_distance()),
      Wire.varint(Valimc.config(:simulation_distance)),
      <<0, 1, 0>>,
      spawn_info(player, Map.get(player, :last_death)),
      <<0, 0>>
    ])
  end

  @doc """
  A respawn into the player's dimension. `keep` is vanilla's data-to-keep
  flags: 0 after death, 3 (attributes and entity data) when changing
  dimension (VMC-026b).
  """
  def respawn(player, last_death \\ nil, keep \\ 0),
    do: Packets.packet("respawn", [spawn_info(player, last_death), <<keep>>])

  # Vanilla's `CommonPlayerSpawnInfo` of the player's level.
  defp spawn_info(player, last_death) do
    dimension = Map.get(player, :dimension, :overworld)
    facts = Valimc.World.Dimension.facts(dimension)
    {hashed_seed, flat?} = Valimc.World.Spec.client_info(Valimc.World.Spec.current(), dimension)
    overworld = dimension == :overworld

    [
      Wire.varint(facts.type_id),
      Wire.string(Valimc.World.Dimension.name(dimension)),
      <<hashed_seed::signed-64>>,
      Wire.varint(
        Valimc.Player.GameMode.id(Map.get(player, :game_mode, %Valimc.Player.GameMode{}).current)
      ),
      previous_mode(Map.get(player, :game_mode, %Valimc.Player.GameMode{}).previous),
      <<0, if(flat?, do: 1, else: 0)>>,
      death_location(last_death, Map.get(player, :death_dimension, :overworld)),
      Wire.varint(Map.get(player, :portal_cooldown, 0)),
      Wire.varint(if(overworld, do: 63, else: facts.sea_level))
    ]
  end

  defp death_location(nil, _dimension), do: <<0>>

  defp death_location({x, y, z} = position, dimension)
       when is_integer(x) and abs(x) <= 29_999_984 and is_integer(z) and abs(z) <= 29_999_984 and
              is_integer(y) and abs(y) <= 1_000_000,
       do: [<<1>>, Wire.string(Valimc.World.Dimension.name(dimension)), Wire.position(position)]

  defp death_location(_, _), do: raise(ArgumentError, "invalid death location")

  def spawn_position do
    Packets.packet("set_default_spawn_position", [
      Wire.string(Valimc.World.Dimension.name(Valimc.World.Spawn.dimension())),
      Wire.position(Valimc.World.Spawn.position()),
      <<Valimc.World.Spawn.yaw()::float-32, Valimc.World.Spawn.pitch()::float-32>>
    ])
  end

  def abilities(abilities \\ Valimc.Player.Abilities.for_mode(:creative)) do
    Packets.packet(
      "player_abilities",
      <<Valimc.Player.Abilities.flags(abilities), abilities.flying_speed::float-32,
        abilities.walking_speed::float-32>>
    )
  end

  def experience(%Valimc.Player.Experience{} = xp) do
    true = Valimc.Player.Experience.valid?(xp)

    Packets.packet("set_experience", [
      <<xp.progress::float-32>>,
      Wire.varint(xp.level),
      Wire.varint(xp.total)
    ])
  end

  def health(health \\ %Valimc.Living.Health{}, food \\ %Valimc.Player.Food{}) do
    unless Valimc.Living.Health.valid?(health) and Valimc.Player.Food.valid?(food),
      do: raise(ArgumentError, "invalid health/food")

    Packets.packet("set_health", [
      <<health.value::float-32>>,
      Wire.varint(food.level),
      <<food.saturation::float-32>>
    ])
  end

  @doc "The entity event that sets the client's permission level (24..28)."
  def permission_level(entity_id, level) do
    Packets.life_entity_id!(entity_id)

    Packets.packet(
      "entity_event",
      <<entity_id::signed-32, Valimc.Admin.Permissions.entity_event(level)>>
    )
  end

  def player_info(player) do
    Packets.packet("player_info_update", [
      <<0x1D, 1>>,
      player.uuid,
      Wire.string(player.name),
      Packets.properties(Map.get(player, :properties, [])),
      Wire.varint(
        Valimc.Player.GameMode.id(Map.get(player, :game_mode, %Valimc.Player.GameMode{}).current)
      ),
      <<1, 0>>
    ])
  end

  defp previous_mode(nil), do: <<0>>

  defp previous_mode(mode), do: Wire.varint(Valimc.Player.GameMode.id(mode) + 1)

  def player_flags(player),
    do: EntityPackets.metadata(player.entity_id, shared_flags: shared_flags(player))

  def player_pose(player),
    do: EntityPackets.metadata(player.entity_id, pose: Map.get(player, :pose, :standing))

  def player_health(player),
    do: EntityPackets.metadata(player.entity_id, health: living(player).health.value)

  def player_absorption(player),
    do: EntityPackets.metadata(player.entity_id, absorption: living(player).absorption)

  def player_use(player),
    do: EntityPackets.metadata(player.entity_id, living_flags: Map.get(player, :use_flags, 0))

  def player_equipment(player, previous \\ %{}) do
    case Valimc.Player.Equipment.changes(Map.get(player, :equipment, %{}), previous) do
      [] -> []
      changes -> [EntityPackets.equipment(player.entity_id, changes)]
    end
  end

  # Players and their peer replicas carry `living`; bare test bodies default to a fresh one.
  defp living(player), do: Map.get(player, :living, %Valimc.Living{})

  def player_environment(player) do
    %{freezing: %{frozen_ticks: frozen}, air_supply: air} = living(player)

    unless Valimc.Living.Freezing.valid_ticks?(frozen),
      do: raise(ArgumentError, "invalid frozen ticks")

    unless Valimc.Living.Air.valid?(air), do: raise(ArgumentError, "invalid air supply")
    EntityPackets.metadata(player.entity_id, frozen_ticks: frozen, air_supply: air)
  end

  def player_air(player) do
    air = living(player).air_supply
    unless Valimc.Living.Air.valid?(air), do: raise(ArgumentError, "invalid air supply")
    EntityPackets.metadata(player.entity_id, air_supply: air)
  end

  def shared_flags(player) do
    flags = Map.get(player, :input, %Valimc.Player.Input{}).shared_flags &&& bnot(17)
    flags = if living(player).fire_ticks > 0, do: flags ||| 1, else: flags
    if Map.get(player, :motion, %Valimc.Player.Motion{}).swimming, do: flags ||| 16, else: flags
  end
end
