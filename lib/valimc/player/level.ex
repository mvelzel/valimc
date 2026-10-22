defmodule Valimc.Player.Level do
  @moduledoc """
  The one way a player enters a level (VMC-077i4). A client starts every
  level from the published world views (`views/0`: clock, difficulty,
  weather and border), at login (`Valimc.Net.LoginFlow`), at a respawn
  after death and on a dimension change; the last two are one path
  (`respawn/4`), as vanilla's `PlayerList.respawn` and
  `ServerPlayer.teleport` send the same sequence: the respawn packet,
  difficulty and permission level, the teleport, abilities, the level's info
  (`sendLevelInfo`: border, clock, spawn and rain where it rains, then the
  chunk loading screen) and the player's own state (inventory, held slot,
  experience, health and effects).
  """
  import Bitwise
  import Valimc.Net.Codec, only: [send_packets: 2]

  alias Valimc.Living.Armor
  alias Valimc.Players
  alias Valimc.Player.{Movement, Travel}
  alias Valimc.Protocol.Packets
  alias Valimc.World.{BorderReplication, Clock, TickRate, WeatherReplication}

  # `ClientboundRespawnPacket`'s data-kept flags.
  @keep_attributes 1
  @keep_entity_data 2

  @doc """
  The world views a client entering a level starts from, and their packets:
  `{views, packets}`; `packets.weather` initializes rain and thunder, and
  `packets.rain` is the same where it rains and empty elsewhere (vanilla's
  `sendLevelInfo` on a respawn).
  """
  def views do
    {clock_version, clock} = Clock.initial()
    {difficulty, difficulty_packet} = Clock.difficulty()
    border = Clock.border()
    {weather, weather_packets} = WeatherReplication.reconcile(nil, Clock.weather())

    {%{clock_version: clock_version, difficulty: difficulty, weather: weather, border: border},
     %{
       clock: clock,
       difficulty: difficulty_packet,
       border: BorderReplication.initialize(border),
       weather: weather_packets,
       rain: if(weather.wet, do: weather_packets, else: [])
     }}
  end

  @doc "The player's active effects, as a client entering a level learns them."
  def effects(player) do
    Enum.map(player.living.effects, fn {id, [rung | _]} ->
      Packets.update_effect(player.entity_id, id, rung, false)
    end)
  end

  @doc """
  Respawn the client in `player`'s level with `inventory`. `opts`: `keep`
  (the respawn's data-kept flags: 0 after a death, vanilla's 3 across a
  teleport), `unload` (the client forgets the old level chunk by chunk
  first), `motion` (`:keep` the player's velocity or `:reset` it), `portal`
  (the portal sound) and `post_effects` (the post effects to send).
  """
  def respawn(state, player, inventory, opts) do
    keep = Keyword.get(opts, :keep, 0)
    {views, packets} = views()
    state = Travel.leave(state, player)

    # The client forgets its level chunk by chunk first (its connection's view).
    Valimc.Session.Link.reset_view(
      state,
      Map.merge(views, %{unload: Keyword.get(opts, :unload, false), dimension: player.dimension})
    )

    state = %{state | player: player, inventory: inventory, active_use: nil}

    send_packets(state, [
      Packets.respawn(player, player.last_death, keep),
      packets.difficulty,
      Packets.permission_level(player.entity_id, Valimc.Permissions.level(player))
    ])

    state =
      case Keyword.get(opts, :motion, :keep) do
        :keep -> Movement.relocate(state, player, false, player.motion.velocity)
        :reset -> Movement.relocate(state, player)
      end

    player = state.player

    entity_data =
      if (keep &&& @keep_entity_data) != 0,
        do: [],
        else: [
          Packets.player_health(player),
          Packets.player_use(player),
          Packets.player_pose(player),
          Packets.player_environment(player),
          Packets.player_flags(player)
        ]

    attributes =
      if (keep &&& @keep_attributes) != 0,
        do: [],
        else: [
          Packets.interaction_attributes(player),
          Packets.armor_attributes(player.entity_id, Armor.attributes(Armor.equipment(inventory)))
        ]

    send_packets(
      state,
      [
        Packets.abilities(player.abilities),
        packets.border,
        packets.clock,
        Packets.spawn_position()
      ] ++
        packets.rain ++
        [
          Packets.level_load_start(),
          TickRate.state_packet(TickRate.published()),
          TickRate.step_packet(TickRate.join_steps()),
          Packets.inventory(inventory),
          Packets.cursor(inventory.carried),
          Packets.held_slot(inventory.selected),
          Packets.experience(player.progression.experience),
          Packets.health(player.living.health, player.food)
        ] ++
        effects(player) ++
        entity_data ++
        attributes ++
        Keyword.get(opts, :post_effects, []) ++
        if(Keyword.get(opts, :portal, false),
          do: [Packets.level_event(1032, {0, 0, 0}, 0)],
          else: []
        )
    )

    state =
      if (keep &&& @keep_attributes) != 0,
        do: state,
        else:
          state
          |> Movement.publish_movement_speed()
          |> Movement.publish_absorption()
          |> Movement.publish_jump_boost()

    for pid <- Players.around(state.player),
        pid != state.connection,
        do:
          Valimc.Connection.deliver(pid, {:player_respawned, state.connection, player.entity_id})

    state
  end
end
