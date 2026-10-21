"""Vanilla oracle stages for `check_vanilla.py`.

Each stage runs in its own scratch directory; stages are independent and run in
parallel. Steps run in order inside a stage. `@name` is a file in the stage's
scratch directory. Step kinds:

- ("java", Class, *args): run a compiled `scripts/*.java` oracle on the pinned jar
- ("check", "check_x.exs", *args): `mix run --no-start scripts/check_x.exs`
- ("app", "check_x.exs", *args): `mix run` with a started app on port 0 and a fresh world
- ("same", "@generated.json", "priv/..."): generated JSON must equal the committed facts

Register every new oracle/checker here (or in HELPERS); `check_vanilla.py --audit`
fails on unregistered scripts.
"""

# Sources that are compiled with the oracles but are not stages of their own.
HELPERS = {
    "ProtocolMetadata": "registry/tag generator used by generate_protocol.py",
    "EntityMetadata": "entity metadata generator used by generate_protocol.py",
    "VanillaOracle": "official-codec TCP client used by the final transport stage",
}

STAGES = [
    ('version', [
        ('java', 'VersionMetadata', '@version.json'),
        ('same', '@version.json', 'priv/version.json'),
    ]),
    ('world_nbt', [
        ('java', 'WorldNbtOracle', 'generate', '@vanilla', '@world-nbt.json'),
        ('check', 'check_world_nbt.exs', '@world-nbt.json', '@reencoded'),
        ('java', 'WorldNbtOracle', 'verify', '@world-nbt.json', '@reencoded'),
    ]),
    ('region_files', [
        ('java', 'RegionOracle', '@worlds', '@regions.json'),
        ('check', 'check_region.exs', '@regions.json'),
    ]),
    ('chunk_sections', [
        ('java', 'ChunkOracle', 'generate', '@world', '@chunks.json'),
        ('check', 'check_chunk_sections.exs', '@chunks.json', '@encoded'),
        ('java', 'ChunkOracle', 'verify', '@chunks.json', '@encoded'),
    ]),
    ('chunk_view', [
        ('java', 'ChunkViewOracle', '@chunk-view.json'),
        ('check', 'check_chunk_view.exs', '@chunk-view.json'),
    ]),
    ('anvil_content', [
        ('java', 'AnvilContentOracle', 'generate', '@vanilla', '@content.json'),
        ('check', 'check_anvil_content.exs', '@content.json', '@imported'),
        ('java', 'AnvilContentOracle', 'verify', '@content.json', '@imported'),
        ('java', 'AnvilContentOracle', 'export', '@content.json', '@imported/exported-world', '@server'),
    ]),
    ('light_facts', [
        ('java', 'LightFactsOracle', '@light-blocks.json'),
        ('same', '@light-blocks.json', 'priv/physics/light_blocks.json'),
    ]),
    ('light', [
        ('java', 'ChunkOracle', 'generate', '@world', '@chunks.json'),
        ('java', 'LightOracle', '@chunks.json', '@light.json', '@light.bin'),
        ('check', 'check_light.exs', '@chunks.json', '@light.json', '@light.bin'),
    ]),
    ('worldgen_random', [
        ('java', 'RandomOracle', '@random.json'),
        ('check', 'check_random.exs', '@random.json'),
    ]),
    ('worldgen_facts', [
        ('java', 'WorldgenFactsOracle', '@noises.json', '@density_functions.json', '@noise_settings.json',
         '@biome_parameters.json', '@material_rules.json', '@material_conditions.json', '@biomes.json',
         '@carvers.json', '@features.json', '@placed_features.json', '@block_state_providers.json',
         '@feature_order.json'),
        ('same', '@noises.json', 'priv/worldgen/noises.json'),
        ('same', '@density_functions.json', 'priv/worldgen/density_functions.json'),
        ('same', '@noise_settings.json', 'priv/worldgen/noise_settings.json'),
        ('same', '@biome_parameters.json', 'priv/worldgen/biome_parameters.json'),
        ('same', '@material_rules.json', 'priv/worldgen/material_rules.json'),
        ('same', '@material_conditions.json', 'priv/worldgen/material_conditions.json'),
        ('same', '@biomes.json', 'priv/worldgen/biomes.json'),
        ('same', '@carvers.json', 'priv/worldgen/carvers.json'),
        ('same', '@features.json', 'priv/worldgen/features.json'),
        ('same', '@placed_features.json', 'priv/worldgen/placed_features.json'),
        ('same', '@block_state_providers.json', 'priv/worldgen/block_state_providers.json'),
        ('same', '@feature_order.json', 'priv/worldgen/feature_order.json'),
        ('java', 'WorldgenBlocksOracle', '@blocks.json'),
        ('same', '@blocks.json', 'priv/worldgen/blocks.json'),
        ('java', 'StructureTemplateOracle', '@templates.json', '@processor_lists.json'),
        ('same', '@templates.json', 'priv/worldgen/templates.json'),
        ('same', '@processor_lists.json', 'priv/worldgen/processor_lists.json'),
        ('java', 'StructureOracle', 'facts', '@structures.json', '@structure_sets.json'),
        ('same', '@structures.json', 'priv/worldgen/structures.json'),
        ('same', '@structure_sets.json', 'priv/worldgen/structure_sets.json'),
    ]),
    ('worldgen_noise', [
        ('java', 'NoiseOracle', '@noise.json'),
        ('check', 'check_noise.exs', '@noise.json'),
    ]),
    ('worldgen_density', [
        ('java', 'DensityOracle', '@density.json'),
        ('check', 'check_density.exs', '@density.json'),
    ]),
    ('worldgen_biomes', [
        ('java', 'BiomeOracle', 'generate', '@world', '@biomes.json'),
        ('check', 'check_biomes.exs', '@biomes.json'),
    ]),
    ('worldgen_terrain', [
        ('java', 'TerrainOracle', 'fill', '@terrain.json'),
        ('check', 'check_terrain.exs', 'fill', '@terrain.json'),
    ]),
    ('worldgen_surface', [
        ('java', 'TerrainOracle', 'surface', '@surface.json'),
        ('check', 'check_terrain.exs', 'surface', '@surface.json'),
    ]),
    ('worldgen_carvers', [
        ('java', 'TerrainOracle', 'carve', '@carve.json'),
        ('check', 'check_terrain.exs', 'carve', '@carve.json'),
    ]),
    ('worldgen_survival', [
        ('java', 'SupportOracle', 'worldgen', '@survival.json'),
        ('same', '@survival.json', 'priv/worldgen/survival.json'),
    ]),
    ('worldgen_shapes', [
        ('java', 'ShapeOracle', '@shapes.json'),
        ('same', '@shapes.json', 'priv/worldgen/shapes.json'),
    ]),
    ('worldgen_decoration', [
        ('java', 'DecorationOracle', '@decoration.json',
         'minecraft:ore,minecraft:disk,minecraft:spring_feature,minecraft:simple_block,minecraft:random_selector,'
         'minecraft:simple_random_selector,minecraft:weighted_random_selector,minecraft:random_boolean_selector,'
         'minecraft:sequence,minecraft:block_column,minecraft:lake,minecraft:freeze_top_layer,minecraft:blue_ice,'
         'minecraft:block_blob,minecraft:tree,minecraft:fallen_tree,minecraft:huge_red_mushroom,'
         'minecraft:huge_brown_mushroom,minecraft:bamboo,minecraft:vegetation_patch,'
         'minecraft:waterlogged_vegetation_patch,minecraft:root_system,minecraft:iceberg,minecraft:geode,'
         'minecraft:large_dripstone,minecraft:speleothem_cluster,minecraft:speleothem,minecraft:fossil,'
         'minecraft:monster_room,minecraft:spike,minecraft:overlay,minecraft:template,minecraft:no_op,'
         'minecraft:coral_tree,minecraft:coral_claw,minecraft:underwater_magma,minecraft:multiface_growth,'
         'minecraft:sculk_patch,minecraft:vines'),
        ('check', 'check_decoration.exs', '@decoration.json'),
    ]),
    ('worldgen_structures', [
        ('java', 'StructureOracle', 'starts', '@starts.json'),
        ('check', 'check_structures.exs', '@starts.json'),
    ]),
    ('commands', [
        ('java', 'CommandTreeOracle', 'tree', '@tree.json'),
        ('same', '@tree.json', 'priv/commands/tree.json'),
        ('java', 'CommandTreeOracle', 'facts', '@facts.json'),
        ('same', '@facts.json', 'priv/commands/facts.json'),
        ('java', 'CommandTreeOracle', 'cases', '@cases.json'),
        ('check', 'check_commands.exs', '@cases.json', '@graphs', '@results.json'),
        ('java', 'CommandTreeOracle', 'verify', '@graphs', '@results.json'),
    ]),
    ('block_registry', [
        ('java', 'BlockRegistryMetadata', '@block-registry.json'),
        ('same', '@block-registry.json', 'priv/registry/blocks.json'),
    ]),
    ('client_tick', [
        ('java', 'ClientTickOracle', '@client-ticks.json'),
        ('check', 'check_client_tick.exs', '@client-ticks.json'),
    ]),
    ('player_fall', [
        ('java', 'PlayerFallOracle', '@player-fall.json'),
        ('check', 'check_player_fall.exs', '@player-fall.json'),
    ]),
    ('fall_damage', [
        ('java', 'FallDamageOracle', '@fall-damage.json'),
        ('check', 'check_fall_damage.exs', '@fall-damage.json'),
    ]),
    ('landing', [
        ('java', 'LandingOracle', '@landing-blocks.json', '@landing-cases.json'),
        ('same', '@landing-blocks.json', 'priv/physics/landing_blocks.json'),
        ('check', 'check_landing.exs', '@landing-cases.json'),
    ]),
    ('mining', [
        ('java', 'MiningOracle', '@mining-blocks.json', '@mining-cases.json', '@mining-ticks.json'),
        ('check', 'check_mining.exs', '@mining-blocks.json', '@mining-cases.json', '@mining-ticks.json'),
    ]),
    ('mining_tool', [
        ('java', 'MiningToolOracle', '@mining-tools.json', '@mining-tool-cases.json'),
        ('check', 'check_mining_tools.exs', '@mining-tools.json', '@mining-tool-cases.json'),
    ]),
    ('player_mining', [
        ('java', 'PlayerMiningOracle', '@player-mining.json'),
        ('check', 'check_player_mining.exs', '@player-mining.json'),
    ]),
    ('tool_durability', [
        ('java', 'ToolDurabilityOracle', '@tool-durability.json'),
        ('check', 'check_tool_durability.exs', '@tool-durability.json'),
    ]),
    ('mining_loot', [
        ('java', 'MiningLootOracle', '@mining-loot.json', '@mining-loot-cases.json'),
        ('check', 'check_mining_loot.exs', '@mining-loot.json', '@mining-loot-cases.json'),
    ]),
    ('random_mining_loot', [
        ('java', 'RandomMiningLootOracle', '@random-mining-loot.json', '@random-mining-loot-cases.json'),
        ('check', 'check_random_mining_loot.exs', '@random-mining-loot.json', '@random-mining-loot-cases.json'),
    ]),
    ('mining_attempt', [
        ('java', 'MiningAttemptOracle', '@mining-attempt.json'),
        ('check', 'check_mining_attempt.exs', '@mining-attempt.json'),
    ]),
    ('placement', [
        ('java', 'PlacementOracle', '@placement.json', '@placement-cases.json'),
        ('check', 'check_placement.exs', '@placement.json', '@placement-cases.json'),
        ('java', 'PlacementConsumptionOracle', '@placement.json', '@placement-consumption.json'),
        ('check', 'check_placement_consumption.exs', '@placement-consumption.json'),
    ]),
    ('damage_protection_1', [
        ('java', 'DamageProtectionOracle', '@damage-protection.json'),
        ('check', 'check_damage_protection.exs', '@damage-protection.json'),
    ]),
    ('damage_protection_2', [
        ('java', 'DamageProtectionOracle', '@fire-damage.json', 'fire'),
        ('check', 'check_damage_protection.exs', '@fire-damage.json'),
    ]),
    ('damage_protection_3', [
        ('java', 'DamageProtectionOracle', '@hazard-damage.json', 'hazards'),
        ('check', 'check_damage_protection.exs', '@hazard-damage.json'),
    ]),
    ('damage_protection_4', [
        ('java', 'DamageProtectionOracle', '@periodic-damage.json', 'effects'),
        ('check', 'check_damage_protection.exs', '@periodic-damage.json'),
    ]),
    ('damage_protection_5', [
        ('java', 'DamageProtectionOracle', '@instant-damage.json', 'instant'),
        ('check', 'check_damage_protection.exs', '@instant-damage.json'),
    ]),
    ('damage_immunity', [
        ('java', 'DamageImmunityOracle', '@damage-immunity.json'),
        ('check', 'check_damage_immunity.exs', '@damage-immunity.json'),
    ]),
    ('status_effect', [
        ('java', 'StatusEffectOracle', '@status-effect.json'),
        ('check', 'check_status_effect.exs', '@status-effect.json'),
    ]),
    ('player_effect_map', [
        ('java', 'PlayerEffectMapOracle', '@player-effects.json'),
        ('check', 'check_player_effects.exs', '@player-effects.json'),
    ]),
    ('status_effect_packet', [
        ('java', 'StatusEffectPacketOracle', '@effect-types.json', '@effect-packets.json'),
        ('check', 'check_status_effect_packets.exs', '@effect-types.json', '@effect-packets.json', '@effect-encoded.json'),
        ('java', 'StatusEffectPacketOracle', 'verify', '@effect-encoded.json'),
    ]),
    ('status_damage', [
        ('java', 'StatusDamageOracle', '@status-damage.json', '@status-damage-cases.json'),
        ('check', 'check_status_damage.exs', '@status-damage.json', '@status-damage-cases.json'),
    ]),
    ('armor_wear', [
        ('java', 'ArmorWearOracle', '@armor-wear-facts.json', '@armor-wear-cases.json'),
        ('check', 'check_armor_wear.exs', '@armor-wear-facts.json', '@armor-wear-cases.json'),
    ]),
    ('armor_damage', [
        ('java', 'ArmorDamageOracle', '@armor-damage.json'),
        ('check', 'check_armor_damage.exs', '@armor-damage.json'),
    ]),
    ('player_armor', [
        ('java', 'PlayerArmorOracle', '@player-armor-facts.json', '@player-armor-cases.json'),
        ('check', 'check_player_armor.exs', '@player-armor-facts.json', '@player-armor-cases.json'),
    ]),
    ('burning', [
        ('java', 'BurningOracle', '@burning.json'),
        ('check', 'check_burning.exs', '@burning.json'),
    ]),
    ('fire_contact', [
        ('java', 'FireContactOracle', '@fire-contacts.json'),
        ('check', 'check_fire_contacts.exs', '@fire-contacts.json'),
    ]),
    ('inside_block_metadata', [
        ('java', 'InsideBlockMetadata', '@inside-block-facts.json'),
        ('java', 'FireGeometryOracle', '@fire-geometry.json'),
        ('check', 'check_fire_contacts.exs', '@fire-geometry.json', '@inside-block-facts.json'),
    ]),
    ('heightmap', [
        ('java', 'HeightmapOracle', '@heightmap-facts.json', '@heightmap-cases.json'),
        ('check', 'check_heightmaps.exs', '@heightmap-facts.json', '@heightmap-cases.json'),
        ('check', 'check_chunk_heightmaps.exs', '@heightmap-cases.json', '@chunk-heightmaps.json'),
        ('java', 'HeightmapPacketOracle', '@chunk-heightmaps.json'),
    ]),
    ('sky_column', [
        ('java', 'SkyColumnOracle', '@sky-facts.json', '@sky-cases.json'),
        ('check', 'check_sky_columns.exs', '@sky-facts.json', '@sky-cases.json'),
    ]),
    ('flat_climate', [
        ('java', 'FlatClimateOracle', '@flat-climate-facts.json', '@flat-climate-cases.json'),
        ('check', 'check_flat_climate.exs', '@flat-climate-facts.json', '@flat-climate-cases.json'),
    ]),
    ('rain_contact', [
        ('java', 'RainContactOracle', '@rain-cases.json'),
        ('check', 'check_rain_contact.exs', '@rain-cases.json'),
    ]),
    ('block_hazard', [
        ('java', 'BlockHazardOracle', '@block-hazard-facts.json', '@block-hazard-cases.json'),
        ('check', 'check_block_hazards.exs', '@block-hazard-facts.json', '@block-hazard-cases.json'),
    ]),
    ('hazard_geometry', [
        ('java', 'HazardGeometryOracle', '@hazard-geometry.json'),
        ('check', 'check_hazard_geometry.exs', '@hazard-geometry.json'),
    ]),
    ('player_health', [
        ('java', 'PlayerHealthOracle', '@player-health.json'),
        ('check', 'check_player_health.exs', '@player-health.json'),
    ]),
    ('player_void', [
        ('java', 'PlayerVoidOracle', '@player-void.json'),
        ('check', 'check_player_void.exs', '@player-void.json'),
    ]),
    ('player_food', [
        ('java', 'PlayerFoodOracle', '@player-food.json'),
        ('check', 'check_player_food.exs', '@player-food.json'),
    ]),
    ('movement_food', [
        ('java', 'MovementFoodOracle', '@movement-food.json'),
        ('check', 'check_movement_food.exs', '@movement-food.json'),
    ]),
    ('player_life', [
        ('java', 'PlayerLifeOracle', '@player-life.json'),
        ('check', 'check_player_life.exs', '@player-life.json', '@player-life-encoded.json'),
        ('java', 'PlayerLifeOracle', 'verify', '@player-life-encoded.json'),
    ]),
    ('damage_message', [
        ('java', 'DamageMessageOracle', '@message-facts.json', '@message-cases.json'),
        ('check', 'check_damage_messages.exs', '@message-facts.json', '@message-cases.json', '@message-encoded.json'),
        ('java', 'DamageMessageOracle', 'verify', '@message-encoded.json'),
    ]),
    ('death_inventory', [
        ('java', 'DeathInventoryOracle', '@death-inventory.json'),
        ('check', 'check_death_inventory.exs', '@death-inventory.json'),
    ]),
    ('air_motion', [
        ('java', 'AirMotionOracle', '@air-motion.json'),
        ('check', 'check_air_motion.exs', '@air-motion.json'),
    ]),
    ('collision_response', [
        ('java', 'CollisionResponseOracle', '@collision-response.json'),
        ('check', 'check_collision_response.exs', '@collision-response.json'),
    ]),
    ('block_motion_metadata', [
        ('java', 'BlockMotionMetadata', '@motion-blocks.json', '@motion-block-cases.json'),
        ('same', '@motion-blocks.json', 'priv/physics/motion_blocks.json'),
        ('check', 'check_motion_blocks.exs', '@motion-block-cases.json'),
    ]),
    ('fluid_metadata', [
        ('java', 'FluidMetadata', '@fluid-blocks.json', '@fluid-block-cases.json'),
        ('same', '@fluid-blocks.json', 'priv/physics/fluid_blocks.json'),
        ('check', 'check_fluid_blocks.exs', '@fluid-block-cases.json'),
    ]),
    ('fluid_boundary_metadata', [
        ('java', 'FluidBoundaryMetadata', '@fluid-boundaries.json', '@fluid-boundary-cases.json'),
        ('same', '@fluid-boundaries.json', 'priv/physics/fluid_boundaries.json'),
        ('check', 'check_fluid_boundaries.exs', '@fluid-boundary-cases.json'),
    ]),
    ('fluid_support', [
        ('java', 'FluidSupportOracle', '@fluid-support.json'),
        ('check', 'check_fluid_support.exs', '@fluid-support.json'),
    ]),
    ('fluid_flow', [
        ('java', 'FluidFlowOracle', '@fluid-flows.json'),
        ('check', 'check_fluid_flow.exs', '@fluid-flows.json'),
    ]),
    ('fluid_current', [
        ('java', 'FluidCurrentOracle', '@fluid-currents.json'),
        ('check', 'check_fluid_currents.exs', '@fluid-currents.json'),
    ]),
    ('item_current', [
        ('java', 'ItemCurrentOracle', '@item-currents.json'),
        ('check', 'check_item_currents.exs', '@item-currents.json'),
    ]),
    ('fluid_contact', [
        ('java', 'FluidContactOracle', '@fluid-contacts.json'),
        ('check', 'check_fluid_contact.exs', '@fluid-contacts.json'),
    ]),
    ('fluid_eye', [
        ('java', 'FluidEyeOracle', '@fluid-eyes.json'),
        ('check', 'check_fluid_eye.exs', '@fluid-eyes.json'),
    ]),
    ('swimming', [
        ('java', 'SwimmingOracle', '@swimming.json'),
        ('check', 'check_swimming.exs', '@swimming.json'),
    ]),
    ('swim_steering', [
        ('java', 'SwimSteeringOracle', '@swim-steering.json'),
        ('check', 'check_swim_steering.exs', '@swim-steering.json'),
    ]),
    ('climb_motion', [
        ('java', 'ClimbMotionOracle', '@climb-motion.json'),
        ('check', 'check_climb_motion.exs', '@climb-motion.json'),
    ]),
    ('climb_metadata', [
        ('java', 'ClimbMetadata', '@climb-blocks.json', '@climb-block-cases.json'),
        ('same', '@climb-blocks.json', 'priv/physics/climb_blocks.json'),
        ('check', 'check_climb_blocks.exs', '@climb-block-cases.json'),
    ]),
    ('climb_contact', [
        ('java', 'ClimbContactOracle', '@climb-contacts.json'),
        ('check', 'check_climb_contact.exs', '@climb-contacts.json'),
    ]),
    ('fluid_travel', [
        ('java', 'FluidTravelOracle', '@fluid-travel.json'),
        ('check', 'check_fluid_travel.exs', '@fluid-travel.json'),
    ]),
    ('fluid_input', [
        ('java', 'FluidInputOracle', '@fluid-input.json'),
        ('check', 'check_fluid_input.exs', '@fluid-input.json'),
    ]),
    ('relative_motion', [
        ('java', 'RelativeMotionOracle', '@relative-motion.json'),
        ('check', 'check_relative_motion.exs', '@relative-motion.json'),
    ]),
    ('body_sweep', [
        ('java', 'BodySweepOracle', '@body-sweep.json'),
        ('check', 'check_body_sweep.exs', '@body-sweep.json'),
    ]),
    ('swept_contact', [
        ('java', 'SweptContactOracle', '@swept-contact.json'),
        ('check', 'check_swept_contact.exs', '@swept-contact.json'),
    ]),
    ('stuck_contact', [
        ('java', 'StuckContactOracle', '@stuck-contact.json'),
        ('check', 'check_stuck_contact.exs', '@stuck-contact.json'),
    ]),
    ('stuck_paths', [
        ('java', 'StuckPathsOracle', '@stuck-paths.json'),
        ('check', 'check_stuck_contact.exs', '@stuck-paths.json'),
    ]),
    ('movement_paths', [
        ('java', 'MovementPathsOracle', '@movement-paths.json'),
        ('check', 'check_movement_paths.exs', '@movement-paths.json'),
    ]),
    ('sneak_edges', [
        ('java', 'SneakEdgesOracle', '@sneak-edges.json'),
        ('check', 'check_sneak_edges.exs', '@sneak-edges.json'),
    ]),
    ('stuck_motion', [
        ('java', 'StuckMotionOracle', '@stuck-motion.json', '@stuck-blocks.json', '@stuck-lookups.json'),
        ('same', '@stuck-blocks.json', 'priv/physics/stuck_blocks.json'),
        ('check', 'check_stuck_motion.exs', '@stuck-motion.json', '@stuck-lookups.json'),
    ]),
    ('player_kinetics', [
        ('java', 'PlayerKineticsOracle', '@player-kinetics.json'),
        ('check', 'check_player_kinetics.exs', '@player-kinetics.json'),
    ]),
    ('player_motion_persistence', [
        ('java', 'PlayerMotionPersistenceOracle', '@player-motion-save.json'),
        ('check', 'check_player_motion_persistence.exs', '@player-motion-save.json'),
    ]),
    ('player_freeze', [
        ('java', 'PlayerFreezeOracle', '@player-freeze.json'),
        ('check', 'check_player_freeze.exs', '@player-freeze.json'),
    ]),
    ('freezing_eligibility', [
        ('java', 'FreezingEligibilityOracle', '@freezing-eligibility.json'),
        ('check', 'check_freezing_eligibility.exs', '@freezing-eligibility.json'),
    ]),
    ('player_air', [
        ('java', 'PlayerAirOracle', '@air-supply.json'),
        ('check', 'check_player_air.exs', '@air-supply.json'),
    ]),
    ('status_air', [
        ('java', 'StatusAirOracle', '@status-air.json'),
        ('check', 'check_status_air.exs', '@status-air.json'),
    ]),
    ('periodic_effect', [
        ('java', 'PeriodicEffectOracle', '@periodic-effects.json'),
        ('check', 'check_periodic_effects.exs', '@periodic-effects.json'),
    ]),
    ('consumable_removal', [
        ('java', 'ConsumableRemovalOracle', '@consumable-removal.json'),
        ('check', 'check_consumable_removal.exs', '@consumable-removal.json'),
    ]),
    ('consume_status', [
        ('java', 'ConsumeStatusOracle', '@consume-status-facts.json', '@consume-status.json'),
        ('check', 'check_consume_status.exs', '@consume-status-facts.json', '@consume-status.json'),
    ]),
    ('nausea', [
        ('java', 'NauseaOracle', '@nausea.json'),
        ('check', 'check_nausea.exs', '@nausea.json'),
    ]),
    ('jump_boost', [
        ('java', 'JumpBoostOracle', '@jump-boost.json'),
        ('check', 'check_jump_boost.exs', '@jump-boost.json'),
    ]),
    ('gravity_effect', [
        ('java', 'GravityEffectOracle', '@gravity-effects.json'),
        ('check', 'check_gravity_effects.exs', '@gravity-effects.json'),
    ]),
    ('chest_menu', [
        ('java', 'ChestMenuOracle', '@chest-menu.json'),
        ('check', 'check_chest_menu.exs', '@chest-menu.json'),
    ]),
    ('chest_click', [
        ('java', 'ChestClickOracle', '@chest-click.json'),
        ('check', 'check_chest_click.exs', '@chest-click.json'),
    ]),
    ('chest_access', [
        ('java', 'ChestAccessOracle', '@chest-access.json'),
        ('check', 'check_chest_access.exs', '@chest-access.json'),
    ]),
    ('chest_block_entity', [
        ('java', 'ChestBlockEntityOracle', '@chest-entities.json'),
        ('check', 'check_chest_block_entity.exs', '@chest-entities.json', '@chest-chunks.json'),
        ('java', 'ChestBlockEntityOracle', '@chest-entities.json', '@chest-chunks.json'),
    ]),
    ('block_entities', [
        ('java', 'BlockEntityOracle', '@block-entities.json'),
        ('same', '@block-entities.json', 'priv/physics/block_entities.json'),
    ]),
    ('random_ticking', [
        ('java', 'RandomTickOracle', '@random-ticking.json'),
        ('same', '@random-ticking.json', 'priv/physics/random_ticking.json'),
    ]),
    ('support', [
        ('java', 'SupportOracle', '@support.json', '@support-cases.json'),
        ('same', '@support.json', 'priv/physics/support.json'),
        ('check', 'check_support.exs', '@support-cases.json'),
    ]),
    ('chest_opening', [
        ('java', 'ChestOpeningOracle', '@chest-opening.json'),
        ('check', 'check_chest_opening.exs', '@chest-opening.json'),
    ]),
    ('chest_view', [
        ('java', 'ChestViewOracle', '@chest-view.json'),
        ('check', 'check_chest_view.exs', '@chest-view.json'),
    ]),
    ('chest_sound', [
        ('java', 'ChestSoundOracle', '@chest-sound.json'),
        ('check', 'check_chest_sounds.exs', '@chest-sound.json'),
    ]),
    ('chest_placement', [
        ('java', 'ChestPlacementOracle', '@chest-placement.json'),
        ('check', 'check_chest_placement.exs', '@chest-placement.json'),
    ]),
    ('container_drop', [
        ('java', 'ContainerDropOracle', '@container-drop.json'),
        ('check', 'check_container_drop.exs', '@container-drop.json'),
    ]),
    ('chest_loot', [
        ('java', 'ChestLootOracle', '@chest-loot.json'),
        ('check', 'check_chest_loot.exs', '@chest-loot.json'),
    ]),
    ('cooking_fuel', [
        ('java', 'CookingFuelOracle', '@cooking-fuel.json'),
        ('check', 'check_cooking_fuel.exs', '@cooking-fuel.json'),
    ]),
    ('cooking_items', [
        ('java', 'CookingItemsOracle', '@cooking-items.json'),
        ('check', 'check_cooking_items.exs', '@cooking-items.json'),
    ]),
    ('cooking_recipes', [
        ('java', 'CookingRecipesOracle', '@cooking-recipes.json'),
        ('check', 'check_cooking_recipes.exs', '@cooking-recipes.json'),
    ]),
    ('cooking_tick', [
        ('java', 'CookingTickOracle', '@cooking-tick.json'),
        ('check', 'check_cooking_tick.exs', '@cooking-tick.json'),
        ('check', 'check_cooking_batch.exs', '@cooking-tick.json'),
    ]),
    ('cooking_placement', [
        ('java', 'CookingPlacementOracle', '@cooking-placement.json'),
        ('check', 'check_cooking_blocks.exs', '@cooking-placement.json'),
    ]),
    ('cooking_loot', [
        ('java', 'CookingLootOracle', '@cooking-loot.json'),
        ('check', 'check_cooking_loot.exs', '@cooking-loot.json'),
    ]),
    ('cooking_menu', [
        ('java', 'CookingMenuOracle', '@cooking-menu.json'),
        ('check', 'check_cooking_menu.exs', '@cooking-menu.json'),
    ]),
    ('cooking_click', [
        ('java', 'CookingClickOracle', '@cooking-click.json'),
        ('check', 'check_cooking_click.exs', '@cooking-click.json'),
    ]),
    ('cooking_slot_edit', [
        ('java', 'CookingSlotEditOracle', '@cooking-slot-edit.json'),
        ('check', 'check_cooking_slot_edit.exs', '@cooking-slot-edit.json'),
    ]),
    ('cooking_opening', [
        ('java', 'CookingOpeningOracle', '@cooking-opening.json'),
        ('check', 'check_cooking_opening.exs', '@cooking-opening.json'),
    ]),
    ('resistance', [
        ('java', 'ResistanceOracle', '@resistance.json'),
        ('check', 'check_resistance.exs', '@resistance.json'),
    ]),
    ('movement_effect', [
        ('java', 'MovementEffectOracle', '@movement-effects.json'),
        ('check', 'check_movement_effects.exs', '@movement-effects.json'),
    ]),
    ('hunger_effect', [
        ('java', 'HungerEffectOracle', '@hunger-effect.json', '@hunger-timing.json'),
        ('check', 'check_hunger_effect.exs', '@hunger-effect.json', '@hunger-timing.json'),
    ]),
    ('hunger_food', [
        ('java', 'HungerFoodOracle', '@hunger-food.json'),
        ('check', 'check_hunger_food.exs', '@hunger-food.json'),
    ]),
    ('instant_drink', [
        ('java', 'InstantDrinkOracle', '@instant-drinks.json'),
        ('check', 'check_instant_drinks.exs', '@instant-drinks.json'),
    ]),
    ('saturation_drink', [
        ('java', 'SaturationDrinkOracle', '@saturation-drinks.json'),
        ('check', 'check_saturation_drinks.exs', '@saturation-drinks.json'),
    ]),
    ('absorption', [
        ('java', 'AbsorptionOracle', '@absorption.json'),
        ('check', 'check_absorption.exs', '@absorption.json'),
    ]),
    ('absorption_damage', [
        ('java', 'AbsorptionDamageOracle', '@absorption-damage.json'),
        ('check', 'check_absorption_damage.exs', '@absorption-damage.json'),
    ]),
    ('healing', [
        ('java', 'HealingOracle', '@healing.json'),
        ('check', 'check_healing.exs', '@healing.json'),
    ]),
    ('instant_healing_state', [
        ('java', 'InstantHealingStateOracle', '@instant-healing-state.json'),
        ('check', 'check_instant_healing_state.exs', '@instant-healing-state.json'),
    ]),
    ('self_magic', [
        ('java', 'SelfMagicOracle', '@self-magic.json'),
        ('check', 'check_self_magic.exs', '@self-magic.json', '@self-magic-elixir.json'),
        ('java', 'SelfMagicOracle', 'verify', '@self-magic-elixir.json'),
    ]),
    ('item_hover', [
        ('java', 'ItemHoverOracle', '@item-hover.json'),
        ('check', 'check_item_hover.exs', '@item-hover.json', '@item-hover-elixir.json'),
        ('java', 'ItemHoverOracle', 'verify', '@item-hover-elixir.json'),
    ]),
    ('damage_protection_6', [
        ('java', 'DamageProtectionOracle', '@resisted-environment.json', 'environment', '1'),
        ('check', 'check_damage_protection.exs', '@resisted-environment.json'),
    ]),
    ('damage_protection_7', [
        ('java', 'DamageProtectionOracle', '@resisted-hazards.json', 'hazards', '1'),
        ('check', 'check_damage_protection.exs', '@resisted-hazards.json'),
    ]),
    ('damage_protection_8', [
        ('java', 'DamageProtectionOracle', '@resisted-effects.json', 'effects', '1'),
        ('check', 'check_damage_protection.exs', '@resisted-effects.json'),
    ]),
    ('damage_protection_9', [
        ('java', 'DamageProtectionOracle', '@resisted-instant.json', 'instant', '1'),
        ('check', 'check_damage_protection.exs', '@resisted-instant.json'),
    ]),
    ('block_batch', [
        ('check', 'check_block_batch.exs', '@block-batches.json'),
        ('java', 'BlockBatchOracle', '@block-batches.json'),
    ]),
    ('player_input', [
        ('java', 'PlayerInputOracle', '@player-input.json'),
        ('check', 'check_player_input.exs', '@player-input.json'),
    ]),
    ('player_pose', [
        ('java', 'PlayerPoseOracle', '@player-poses.json'),
        ('check', 'check_player_pose.exs', '@player-poses.json'),
    ]),
    ('entity_collision', [
        ('java', 'EntityCollisionOracle', '@entity-collisions.json'),
        ('check', 'check_entity_collisions.exs', '@entity-collisions.json'),
    ]),
    ('border_collision', [
        ('java', 'BorderCollisionOracle', '@border-collisions.json'),
        ('check', 'check_border_collisions.exs', '@border-collisions.json'),
    ]),
    ('player_fit', [
        ('java', 'PlayerFitOracle', '@pose-fit.json'),
        ('check', 'check_pose_fit.exs', '@pose-fit.json'),
    ]),
    ('collision_metadata', [
        ('java', 'CollisionMetadata', '@collision-shapes.json'),
        ('same', '@collision-shapes.json', 'priv/physics/collision_shapes.json'),
        ('java', 'CollisionOracle', '@collision-shapes.json', '@collisions.json'),
        ('check', 'check_collisions.exs', '@collisions.json'),
        ('java', 'PositionCollisionOracle', '@collision-shapes.json', '@position-collisions.json'),
        ('check', 'check_position_collisions.exs', '@position-collisions.json'),
        ('java', 'ScaffoldingCollisionOracle', '@collision-shapes.json', '@scaffolding-collisions.json'),
        ('check', 'check_scaffolding_collisions.exs', '@scaffolding-collisions.json'),
        ('java', 'ShulkerCollisionOracle', '@collision-shapes.json', '@shulker-collisions.json'),
        ('check', 'check_shulker_collisions.exs', '@shulker-collisions.json'),
        ('java', 'PistonCollisionOracle', '@collision-shapes.json', '@piston-collisions.json'),
        ('check', 'check_piston_collisions.exs', '@piston-collisions.json'),
    ]),
    ('powder_snow_collision', [
        ('java', 'PowderSnowCollisionOracle', '@powder-snow-collisions.json'),
        ('check', 'check_powder_snow_collisions.exs', '@powder-snow-collisions.json'),
    ]),
    ('voxel_union', [
        ('java', 'VoxelUnionOracle', '@voxel-unions.json'),
        ('check', 'check_voxel_unions.exs', '@voxel-unions.json'),
    ]),
    ('movement_collision', [
        ('java', 'MovementCollisionOracle', '@movement-collisions.json'),
        ('check', 'check_movement_collisions.exs', '@movement-collisions.json'),
    ]),
    ('server_movement', [
        ('java', 'ServerMovementOracle', '@server-movement-cases.json'),
        ('check', 'check_server_movement.exs', '@server-movement-cases.json'),
    ]),
    ('step_movement', [
        ('java', 'StepMovementOracle', '@step-movements.json'),
        ('check', 'check_step_movement.exs', '@step-movements.json'),
    ]),
    ('block_scan', [
        ('java', 'BlockScanOracle', '@block-scans.json'),
        ('check', 'check_block_scans.exs', '@block-scans.json'),
    ]),
    ('voxel_intersection', [
        ('java', 'VoxelIntersectionOracle', '@voxel-intersections.json'),
        ('check', 'check_voxel_intersections.exs', '@voxel-intersections.json'),
    ]),
    ('block_collision', [
        ('java', 'BlockCollisionOracle', '@block-collisions.json'),
        ('check', 'check_block_collisions.exs', '@block-collisions.json'),
    ]),
    ('chunk_height', [
        ('java', 'ChunkHeightOracle', '@chunk-heights.json'),
        ('check', 'check_chunk_heights.exs', '@chunk-heights.json'),
    ]),
    ('attribute_metadata', [
        ('java', 'AttributeMetadata', '@attributes.json'),
        ('same', '@attributes.json', 'priv/protocol/attributes.json'),
    ]),
    ('interaction_range', [
        ('java', 'InteractionRangeOracle', '@ranges.json'),
        ('check', 'check_interaction_ranges.exs', '@ranges.json', '@ranges-elixir.json'),
        ('java', 'InteractionRangeOracle', 'verify', '@ranges-elixir.json'),
    ]),
    ('game_mode', [
        ('java', 'GameModeOracle', '@modes.json'),
        ('check', 'check_game_modes.exs', '@modes.json', '@modes-elixir.json'),
        ('java', 'GameModeOracle', 'verify', '@modes-elixir.json'),
    ]),
    ('abilities', [
        ('java', 'AbilitiesOracle', '@abilities.json'),
        ('check', 'check_abilities.exs', '@abilities.json'),
    ]),
    ('discovery', [
        ('java', 'DiscoveryOracle', '@discovery.jsonl'),
        ('check', 'check_discovery.exs', '@discovery.jsonl'),
    ]),
    ('auth_profile', [
        ('java', 'AuthProfileOracle', '@auth-profiles.jsonl'),
        ('check', 'check_auth.exs', '@auth-profiles.jsonl', '@auth-elixir.jsonl'),
        ('java', 'AuthProfileOracle', 'verify', '@auth-elixir.jsonl'),
    ]),
    ('item_food', [
        ('java', 'ItemFoodOracle', 'generate', '@food-items.json', '@food-components.json'),
        ('check', 'check_item_food.exs', '@food-items.json', '@food-components.json', '@food-encoded.json'),
        ('java', 'ItemFoodOracle', 'verify', '@food-encoded.json'),
    ]),
    ('potion', [
        ('java', 'PotionOracle', '@potions.json', '@potion-cases.json'),
        ('check', 'check_potions.exs', '@potions.json', '@potion-cases.json', '@potion-encoded.json'),
        ('java', 'PotionOracle', 'verify', '@potion-encoded.json'),
    ]),
    ('item_use', [
        ('java', 'ItemUseOracle', 'generate', '@item-use-cases.json'),
        ('check', 'check_item_use.exs', '@item-use-cases.json', '@item-use-encoded.json'),
        ('java', 'ItemUseOracle', 'verify', '@item-use-encoded.json'),
    ]),
    ('equipment', [
        ('java', 'EquipmentOracle', 'generate', '@equipment-cases.json'),
        ('check', 'check_equipment.exs', '@equipment-cases.json', '@equipment-encoded.json'),
        ('java', 'EquipmentOracle', 'verify', '@equipment-encoded.json'),
    ]),
    ('item_metadata', [
        ('java', 'ItemMetadata', '@items.json', '@defaults.json'),
        ('same', '@items.json', 'priv/protocol/items.json'),
        ('same', '@defaults.json', 'priv/protocol/item_defaults.json'),
    ]),
    ('stack_identity', [
        ('java', 'StackIdentityOracle', '@identity.json'),
        ('check', 'check_stack_identity.exs', '@identity.json'),
    ]),
    ('text', [
        ('java', 'TextOracle', '@text.json'),
        ('check', 'check_text.exs', '@text.json', '@elixir-text.json'),
        ('java', 'TextOracle', 'verify', '@elixir-text.json'),
    ]),
    ('enchantment', [
        ('java', 'EnchantmentOracle', '@enchantments.json'),
        ('check', 'check_enchantments.exs', '@enchantments.json', '@elixir-enchantments.json'),
        ('java', 'EnchantmentOracle', 'verify', '@elixir-enchantments.json'),
    ]),
    ('tooltip', [
        ('java', 'TooltipOracle', '@tooltips.json'),
        ('check', 'check_tooltips.exs', '@tooltips.json', '@elixir-tooltips.json'),
        ('java', 'TooltipOracle', 'verify', '@elixir-tooltips.json'),
    ]),
    ('clock', [
        ('java', 'ClockOracle', '@clocks.json'),
        ('check', 'check_clocks.exs', '@clocks.json', '@elixir-clocks.json'),
        ('java', 'ClockOracle', 'verify', '@elixir-clocks.json'),
    ]),
    ('weather', [
        ('java', 'WeatherOracle', '@weather.json'),
        ('check', 'check_weather.exs', '@weather.json'),
    ]),
    ('difficulty', [
        ('java', 'DifficultyOracle', '@difficulty.json'),
        ('check', 'check_difficulty.exs', '@difficulty.json'),
    ]),
    ('encryption', [
        ('check', 'check_encryption.exs', 'generate', '@encryption.json'),
        ('java', 'EncryptionOracle', '@encryption.json'),
        ('check', 'check_encryption.exs', 'verify', '@encryption.json'),
    ]),
    ('inventory_behavior', [
        ('java', 'InventoryBehaviorOracle'),
    ]),
    ('crafting_table_access', [
        ('java', 'CraftingTableAccessOracle', '@table-access.json'),
        ('check', 'check_table_access.exs', '@table-access.json'),
    ]),
    ('table_menu', [
        ('java', 'TableMenuOracle', '@table-menu.json'),
        ('check', 'check_table_menu.exs', '@table-menu.json'),
    ]),
    ('player_crafting_1', [
        ('java', 'PlayerCraftingOracle', '@player-recipes.json', '@player-crafting-cases.json'),
        ('check', 'check_crafting.exs', 'player', '@player-recipes.json', '@player-crafting-cases.json'),
    ]),
    ('table_crafting', [
        ('java', 'TableCraftingOracle', '@table-recipes.json', '@table-crafting-cases.json'),
        ('check', 'check_crafting.exs', 'table', '@table-recipes.json', '@table-crafting-cases.json'),
    ]),
    ('table_menu_click', [
        ('java', 'TableMenuClickOracle', '@table-clicks.json'),
        ('check', 'check_table_clicks.exs', '@table-clicks.json', '@table-packets.json'),
        ('java', 'TableMenuClickOracle', 'verify', '@table-packets.json'),
    ]),
    ('crafting_bulk', [
        ('java', 'CraftingBulkOracle', '@crafting-bulk.json'),
        ('check', 'check_crafting_bulk.exs', '@crafting-bulk.json'),
    ]),
    ('remainder_crafting', [
        ('java', 'RemainderCraftingOracle', '@crafting-remainders.json', '@remainder-catalog.json'),
        ('check', 'check_crafting_remainders.exs', '@crafting-remainders.json', '@remainder-catalog.json'),
    ]),
    ('player_crafting_2', [
        ('java', 'PlayerCraftingOracle', 'menu', '@player-crafting-menu.json'),
        ('check', 'check_player_crafting_menu.exs', '@player-crafting-menu.json'),
    ]),
    ('player_crafting_3', [
        ('java', 'PlayerCraftingOracle', 'drops', '@player-crafting-drops.json'),
        ('check', 'check_player_crafting_gestures.exs', '@player-crafting-drops.json'),
    ]),
    ('item', [
        ('java', 'ItemOracle', 'generate', '@item-fixtures.json'),
        ('check', 'check_items.exs', '@item-fixtures.json', '@elixir-items.json'),
        ('java', 'ItemOracle', 'verify', '@elixir-items.json'),
    ]),
    ('entity', [
        ('java', 'EntityOracle', 'generate', '@entity-fixtures.json'),
        ('check', 'check_entities.exs', '@entity-fixtures.json', '@elixir-entities.json'),
        ('java', 'EntityOracle', 'verify', '@elixir-entities.json'),
    ]),
    ('entity_position', [
        ('java', 'EntityPositionOracle', 'generate', '@entity-position.json'),
        ('check', 'check_entity_position.exs', '@entity-position.json', '@entity-position-elixir.json'),
        ('java', 'EntityPositionOracle', 'verify', '@entity-position-elixir.json'),
    ]),
    ('item_drop', [
        ('java', 'ItemDropOracle', '@item-launch.json'),
        ('check', 'check_item_drop.exs', '@item-launch.json'),
    ]),
    ('item_travel', [
        ('java', 'ItemTravelOracle', '@item-travel.json'),
        ('check', 'check_item_travel.exs', '@item-travel.json'),
    ]),
    ('item_motion', [
        ('java', 'ItemMotionOracle', '@item-motion.json'),
        ('check', 'check_item_motion.exs', '@item-motion.json'),
    ]),
    ('item_merge', [
        ('java', 'ItemMergeOracle', '@item-merge.json'),
        ('check', 'check_item_merge.exs', '@item-merge.json'),
    ]),
    ('item_void', [
        ('java', 'ItemVoidOracle', '@item-void.json'),
        ('check', 'check_item_void.exs', '@item-void.json'),
    ]),
    ('item_pickup', [
        ('java', 'ItemPickupOracle', '@item-pickup.json'),
        ('check', 'check_item_pickup.exs', '@item-pickup.json'),
    ]),
    ('item_pickup_contact', [
        ('java', 'ItemPickupContactOracle', '@pickup-contact.json'),
        ('check', 'check_item_pickup_contact.exs', '@pickup-contact.json'),
    ]),
    ('cooking_experience', [
        ('java', 'CookingExperienceOracle', '@cooking-experience.json'),
        ('check', 'check_cooking_experience.exs', '@cooking-experience.json'),
    ]),
    ('cooking_recipe_book', [
        ('java', 'CookingRecipeBookOracle', '@cooking-book.json'),
        ('check', 'check_cooking_book.exs', '@cooking-book.json'),
    ]),
    ('experience_orb', [
        ('java', 'ExperienceOrbOracle', 'generate', '@experience-orbs.json'),
        ('check', 'check_experience_orbs.exs', '@experience-orbs.json', '@experience-orbs-encoded.json'),
        ('java', 'ExperienceOrbOracle', 'verify', '@experience-orbs-encoded.json'),
    ]),
    ('orb_motion', [
        ('java', 'OrbMotionOracle', '@orb-motion.json'),
        ('check', 'check_orb_motion.exs', '@orb-motion.json'),
    ]),
    ('player_experience', [
        ('java', 'PlayerExperienceOracle', '@player-experience.json'),
        ('check', 'check_player_experience.exs', '@player-experience.json'),
    ]),
    ('directory_recovery', [
        ('app', 'check_directory_recovery.exs'),
    ]),
]
