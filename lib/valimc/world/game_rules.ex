defmodule Valimc.World.GameRules do
  @moduledoc """
  Game rules (VMC-053, VMC-077o), read by gameplay (portals) and command
  feedback without depending on the command layer. The rules ValiMC stores
  are owned by the environment owner (`Valimc.World.Clock`), which `/gamerule`
  changes through `stored/0`'s operations; `settings/0`'s are kept in the
  world's settings; the others keep vanilla's defaults.
  """
  @defaults %{
    send_command_feedback: true,
    log_admin_commands: true,
    players_nether_portal_default_delay: 80,
    players_nether_portal_creative_delay: 0,
    allow_entering_nether_using_portals: true,
    tnt_explodes: true,
    entity_drops: true,
    tnt_explosion_drop_decay: true,
    block_explosion_drop_decay: true,
    # VMC-043b4: a creeper's explosion drops.
    mob_explosion_drop_decay: true,
    # VMC-040a: the share of players that must sleep to skip the night.
    players_sleeping_percentage: 100,
    mob_drops: true,
    # VMC-037o: fireballs' fire and craters, a pearl's endermites.
    mob_griefing: true,
    # VMC-037p: Oozing's slimes stop at the cramming limit.
    max_entity_cramming: 24,
    spawn_mobs: true,
    spawn_monsters: true,
    # VMC-042b: spawner blocks tick.
    spawner_blocks_work: true,
    # VMC-044a4: wandering traders come.
    spawn_wandering_traders: true,
    # VMC-043b6: phantoms come to players who do not rest.
    spawn_phantoms: true,
    water_source_conversion: Valimc.Blocks.Fluids.game_rule("water_source_conversion"),
    lava_source_conversion: Valimc.Blocks.Fluids.game_rule("lava_source_conversion"),
    fire_spread_radius_around_player:
      Valimc.Blocks.Fluids.game_rule("fire_spread_radius_around_player")
  }

  # Rule name => the environment owner's configure operation.
  @stored %{
    "advance_time" => :advance_time,
    "advance_weather" => :advance_weather,
    "natural_health_regeneration" => :natural_regeneration
  }

  # The rules `/gamerule` changes beyond the clock's, kept in the world's
  # settings (`Valimc.World.Settings`'s `game_rules`).
  @settings ~w(mob_griefing)

  @doc """
  A rule's value: a test's override in `:persistent_term`, else the world's
  stored value (`Valimc.World.Settings`), else vanilla's default.
  """
  def get(rule) do
    case :persistent_term.get({__MODULE__, rule}, nil) do
      nil -> Map.get(Valimc.World.Settings.get(:game_rules), rule, Map.fetch!(@defaults, rule))
      value -> value
    end
  end

  @doc "Every rule with a default, by name."
  def names, do: Map.keys(@defaults)

  @doc "A rule's vanilla default (nil for an unknown rule)."
  def default(rule), do: Map.get(@defaults, rule)

  @doc "The rules kept in the world's settings, as `/gamerule` names them."
  def settings, do: @settings

  @doc "The rules the environment owner stores, each with its configure operation."
  def stored, do: @stored
end
