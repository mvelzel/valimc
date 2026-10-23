"""Vanilla oracle stages for `check_vanilla.py`.

Each stage runs in its own scratch directory; stages are independent and run in
parallel. Steps run in order inside a stage. `@name` is a file in the stage's
scratch directory. Step kinds:

- ("java", Class, *args): run a compiled `scripts/*.java` oracle on the pinned jar
  (restored from the oracle cache when its key is known, unless it reads ValiMC output)
- ("regen", Class, *args): fact extraction whose outputs only feed `same` steps; runs
  with `--regen`, otherwise only from the cache (else reported as not verified)
- ("check", "check_x.exs", *args): `mix run --no-start scripts/check_x.exs`
- ("app", "check_x.exs", *args): `mix run` with a started app on port 0 and a fresh world
- ("same", "@generated.json", "priv/..."): generated JSON must equal the committed facts

Register every new oracle/checker here (or in HELPERS); `check_vanilla.py --audit`
fails on unregistered scripts.
"""

# Sources that are compiled with the oracles but are not stages of their own.
HELPERS = {
    "ProtocolMetadata": "registry/tag generator used by generate_protocol.py",
    "VanillaOracle": "official-codec TCP client used by the `tcp` stage",
}

# Repo files (globs relative to the checkout) each oracle reads; a class's closure's
# inputs are part of its cache key. An oracle runs in a directory holding only these,
# so an undeclared read fails, and `--audit` fails on a repo path a source names that
# no declaration covers.
INPUTS = {
    'ArmorWearOracle': ['priv/protocol/tags.json', 'priv/protocol/registries.json'],
    'CookingExperienceOracle': ['priv/crafting/cooking.json'],
    'CookingRecipeBookOracle': ['priv/crafting/cooking.json'],
    'CraftingBulkOracle': ['priv/crafting/recipes.json'],
    'DamageProtectionOracle': ['priv/protocol/tags.json', 'priv/protocol/registries.json'],
    'FreezingEligibilityOracle': ['priv/protocol/tags.json'],
    'LandingOracle': ['priv/protocol/tags.json'],
    'PlayerCraftingOracle': ['priv/crafting/player_recipes.json'],
    'PlayerVoidOracle': ['priv/protocol/tags.json', 'priv/protocol/registries.json'],
    'ShapeOracle': ['priv/worldgen/features.json', 'priv/worldgen/placed_features.json',
                    'priv/worldgen/block_state_providers.json', 'priv/worldgen/material_rules.json',
                    'priv/worldgen/noise_settings.json', 'priv/worldgen/processor_lists.json',
                    'priv/worldgen/structure_templates.json', 'scripts/shape_blocks.txt'],
    'TableMenuClickOracle': ['priv/crafting/recipes.json'],
    'VersionMetadata': ['research/server-*.jar'],
}

# Former stage names (merged in VMC-076d) that `--only` still accepts.
ALIASES = {
    **{f'damage_protection_{n}': 'damage_protection' for n in range(1, 10)},
    **{f'player_crafting_{n}': 'player_crafting' for n in range(1, 4)},
    'worldgen_surface': 'worldgen_terrain', 'worldgen_carvers': 'worldgen_terrain',
    # VMC-077d: the per-state fact stages merged into `block_facts`.
    **{name: 'block_facts' for name in ('light_facts', 'block_motion_metadata', 'fluid_metadata',
                                        'fluid_boundary_metadata', 'climb_metadata')},
    'collision_metadata': 'collision_shapes', 'inside_block_metadata': 'fire_geometry',
}

# Oracles that fill every core with their own thread pool. One runs at a time, with
# `-XX:ActiveProcessorCount` set to the cores the run's other jobs leave free.
THREADED = {'SupportOracle', 'ShapeOracle', 'PlacementOracle'}

# Wall seconds of the heaviest stages (October 2026, five jobs on ten cores), used to
# order a run until `.local/oracle-cache/timings.json` has measured ones; others 15 s.
ESTIMATES = {
    'worldgen_survival': 986, 'placement': 3800, 'place': 703, 'worldgen_shapes': 695, 'worldgen_decoration': 671,
    'worldgen_structures': 620, 'support': 534, 'locate': 386, 'worldgen_structure_placement_jigsaw': 327,
    'worldgen_structure_placement': 310, 'worldgen_live_structures': 290, 'spawn': 283, 'world_settings': 185,
    'collision_shapes': 120, 'anvil_content': 143, 'worldgen_structure_placement_pieces': 92,
    'chunk_sections': 90, 'worldgen_live': 88, 'light': 87, 'worldgen_datapack': 82, 'worldgen_biomes': 79,
    'region_files': 72, 'worldgen_decoration_nether': 67, 'player_motion_persistence': 66, 'interaction_range': 64,
    'block_collision': 60, 'table_crafting': 60, 'worldgen_terrain': 90, 'worldgen_live_structures_nether': 57,
    'worldgen_structure_placement_mansion': 57, 'damage_protection': 40, 'table_menu_click': 56,
    'worldgen_facts': 54, 'world_upgrade': 53, 'item_food': 48, 'potion': 48, 'voxel_intersection': 46,
}

STAGES = [
    ('version', [
        ('regen', 'VersionMetadata', '@version.json'),
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
        ('regen', 'WorldgenFactsOracle', '@noises.json', '@density_functions.json', '@noise_settings.json',
         '@biome_parameters.json', '@material_rules.json', '@material_conditions.json', '@biomes.json',
         '@carvers.json', '@features.json', '@placed_features.json', '@block_state_providers.json',
         '@feature_order.json', '@dimensions.json'),
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
        ('same', '@dimensions.json', 'priv/worldgen/dimensions.json'),
        ('regen', 'StructureTemplateOracle', '@block_transforms.json', '@processor_lists.json'),
        ('same', '@block_transforms.json', 'priv/worldgen/block_transforms.json'),
        ('same', '@processor_lists.json', 'priv/worldgen/processor_lists.json'),
        ('regen', 'StructureOracle', 'facts', '@structures.json', '@structure_sets.json', '@template_pools.json',
         '@structure_templates.json'),
        ('same', '@structures.json', 'priv/worldgen/structures.json'),
        ('same', '@structure_sets.json', 'priv/worldgen/structure_sets.json'),
        ('same', '@template_pools.json', 'priv/worldgen/template_pools.json'),
        ('same', '@structure_templates.json', 'priv/worldgen/structure_templates.json'),
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
    # VMC-076d: each chunk filled once and recorded after fill, surface and carvers.
    ('worldgen_terrain', [
        ('java', 'TerrainOracle', 'all', '@terrain.json', '@surface.json', '@carve.json'),
        ('check', 'check_terrain.exs', 'fill', '@terrain.json', 'surface', '@surface.json', 'carve', '@carve.json'),
    ]),
    ('worldgen_survival', [
        ('regen', 'SupportOracle', 'worldgen', '@survival.json'),
        ('same', '@survival.json', 'priv/worldgen/survival.json'),
    ]),
    ('worldgen_shapes', [
        ('regen', 'ShapeOracle', '@shapes.json'),
        ('same', '@shapes.json', 'priv/worldgen/shapes.json'),
        ('java', 'ShapeOracle', 'code', '@shape-code.json'),
        ('check', 'check_shape_code.exs', '@shape-code.json'),
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
    # VMC-026a: every placed feature of the Nether's and the End's biome sources.
    ('worldgen_decoration_nether', [
        ('java', 'DecorationOracle', '@decoration.json', '*', 'nether'),
        ('check', 'check_decoration.exs', '@decoration.json'),
    ]),
    ('worldgen_decoration_end', [
        ('java', 'DecorationOracle', '@decoration.json', '*', 'end'),
        ('check', 'check_decoration.exs', '@decoration.json'),
    ]),
    ('worldgen_structures', [
        ('java', 'StructureOracle', 'starts', '@starts.json'),
        ('check', 'check_structures.exs', '@starts.json'),
    ]),
    ('world_settings', [
        ('regen', 'WorldSettingsOracle', 'facts', '@world_presets.json'),
        ('same', '@world_presets.json', 'priv/worldgen/world_presets.json'),
        ('java', 'WorldSettingsOracle', 'cases', '@world_settings.json'),
        ('check', 'check_world_settings.exs', '@world_settings.json'),
        ('check', 'export_world_settings.exs', '@exported'),
        ('java', 'WorldSettingsOracle', 'verify', '@exported', '@server'),
    ]),
    # VMC-053: `/place` features, templates, structures and jigsaws with seeded randoms.
    ('place', [
        ('java', 'PlaceOracle', 'cases', '@place.json'),
        ('check', 'check_place.exs', '@place.json'),
    ]),
    # VMC-053o: `/locate structure` over every structure and tag for seeds and positions.
    ('locate', [
        ('java', 'LocateOracle', 'cases', '@locate.json'),
        ('check', 'check_locate.exs', '@locate.json'),
    ]),
    # VMC-025f: decoration with structures placed in their steps, block entities saved as vanilla's.
    ('worldgen_structure_placement', [
        ('java', 'StructurePlacementOracle', '@placement.json',
         'minecraft:desert_pyramid,minecraft:jungle_pyramid,minecraft:swamp_hut,minecraft:buried_treasure,'
         'minecraft:igloo,minecraft:shipwreck,minecraft:shipwreck_beached,minecraft:ocean_ruin_cold,'
         'minecraft:ocean_ruin_warm,minecraft:ruined_portal,minecraft:ruined_portal_desert,'
         'minecraft:ruined_portal_jungle,minecraft:ruined_portal_mountain,minecraft:ruined_portal_ocean,'
         'minecraft:ruined_portal_swamp'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    ('worldgen_structure_placement_jigsaw', [
        ('java', 'StructurePlacementOracle', '@placement.json',
         'minecraft:village_plains,minecraft:village_desert,minecraft:village_savanna,minecraft:village_snowy,'
         'minecraft:village_taiga,minecraft:pillager_outpost,minecraft:abandoned_camp_forest,'
         'minecraft:abandoned_camp_savanna,minecraft:abandoned_camp_snowy_taiga,minecraft:ancient_city,'
         'minecraft:trail_ruins,minecraft:trial_chambers'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    ('worldgen_structure_placement_pieces', [
        ('java', 'StructurePlacementOracle', '@placement.json',
         'minecraft:mineshaft,minecraft:mineshaft_mesa,minecraft:stronghold,minecraft:monument'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    ('worldgen_structure_placement_nether_pieces', [
        ('java', 'StructurePlacementOracle', '@placement.json', 'minecraft:bastion_remnant,minecraft:fortress',
         'nether'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    ('worldgen_structure_placement_mansion', [
        ('java', 'StructurePlacementOracle', '@placement.json', 'minecraft:mansion'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    ('worldgen_structure_placement_nether', [
        ('java', 'StructurePlacementOracle', '@placement.json', 'minecraft:ruined_portal_nether,minecraft:nether_fossil',
         'nether'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    ('worldgen_structure_placement_end', [
        ('java', 'StructurePlacementOracle', '@placement.json', 'minecraft:end_city', 'end'),
        ('check', 'check_decoration.exs', '@placement.json', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify', '@placement.json', '@ours.json'),
    ]),
    # VMC-028d: a 26.2 world (made from AnvilContentOracle's) and a case for each
    # fix, upgraded by ValiMC as vanilla's fixer upgrades them; the world imports.
    ('world_upgrade', [
        ('java', 'AnvilContentOracle', 'generate', '@vanilla', '@content.json'),
        ('check', 'older_world.exs', '@content.json', '@older', '@older-cases.json'),
        ('java', 'DataFixOracle', '@older-cases.json', '@upgrade.json'),
        ('check', 'check_data_fix.exs', '@upgrade.json', '@content.json', '@older', '@imported'),
    ]),
    ('worldgen_datapack', [
        ('java', 'DatapackOracle', 'make', '@world/datapacks/sample'),
        ('java', 'DecorationOracle', '@live.json', '*', 'live', 'pack', '--packs', '@world/datapacks/sample'),
        ('check', 'datapack_facts.exs', '@world'),
        ('app', 'check_live_decoration.exs', '@live.json', '@world'),
    ]),
    ('worldgen_live', [
        ('java', 'DecorationOracle', '@live.json', '*', 'live'),
        ('app', 'check_live_decoration.exs', '@live.json'),
    ]),
    # VMC-010f: the English strings the console prints feedback with.
    ('language', [
        ('regen', 'LanguageOracle', '@en_us.json'),
        ('same', '@en_us.json', 'priv/lang/en_us.json'),
    ]),
    # VMC-026b: the Nether's and the End's live generation, region by region.
    ('worldgen_live_nether', [
        ('java', 'DecorationOracle', '@live.json', '*', 'nether', 'live'),
        ('app', 'check_live_decoration.exs', '@live.json'),
    ]),
    ('worldgen_live_end', [
        ('java', 'DecorationOracle', '@live.json', '*', 'end', 'live'),
        ('app', 'check_live_decoration.exs', '@live.json'),
    ]),
    # VMC-025f5: live generation with structures, region by region, over regions that each
    # family's structures cross.
    ('worldgen_live_structures', [
        ('java', 'StructurePlacementOracle', '@live.json', 'live'),
        ('app', 'check_live_decoration.exs', '@live.json', '--ours', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify-live', '@live.json', '@ours.json'),
    ]),
    ('worldgen_live_structures_nether', [
        ('java', 'StructurePlacementOracle', '@live.json', 'live', 'nether'),
        ('app', 'check_live_decoration.exs', '@live.json', '--ours', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify-live', '@live.json', '@ours.json'),
    ]),
    ('worldgen_live_structures_end', [
        ('java', 'StructurePlacementOracle', '@live.json', 'live', 'end'),
        ('app', 'check_live_decoration.exs', '@live.json', '--ours', '@ours.json'),
        ('java', 'StructurePlacementOracle', 'verify-live', '@live.json', '@ours.json'),
    ]),
    # VMC-026b2: nether portal shapes, fire placement, rectangles, search and creation.
    ('portals', [
        ('java', 'PortalOracle', '@portals.json'),
        ('check', 'check_portals.exs', '@portals.json'),
    ]),
    ('commands', [
        ('regen', 'CommandTreeOracle', 'tree', '@tree.json'),
        ('same', '@tree.json', 'priv/commands/tree.json'),
        ('regen', 'CommandTreeOracle', 'facts', '@facts.json'),
        ('same', '@facts.json', 'priv/commands/facts.json'),
        ('java', 'CommandTreeOracle', 'cases', '@cases.json'),
        ('check', 'check_commands.exs', '@cases.json', '@graphs', '@results.json'),
        ('java', 'CommandTreeOracle', 'verify', '@graphs', '@results.json'),
    ]),
    ('block_registry', [
        ('regen', 'BlockRegistryMetadata', '@block-registry.json'),
        ('same', '@block-registry.json', 'priv/registry/blocks.json'),
    ]),
    # VMC-077d: every per-state fact (flags, shapes, motion, fluids, light, ...) in one table.
    ('block_facts', [
        ('regen', 'BlockFactsOracle', '@block-facts.json'),
        ('same', '@block-facts.json', 'priv/registry/block_facts.json'),
    ]),
    # VMC-043a: every entity type's facts (category, size, attributes, loot, spawning, tracking).
    ('entity_facts', [
        ('regen', 'EntityOracle', 'facts', '@entity-facts.json'),
        ('same', '@entity-facts.json', 'priv/registry/entity_facts.json'),
    ]),
    # VMC-037n: weapon and shield components, the player's base attributes, mob experience.
    ('combat_facts', [
        ('regen', 'CombatOracle', 'facts', '@combat-facts.json'),
        ('same', '@combat-facts.json', 'priv/registry/combat_facts.json'),
    ]),
    ('combat_packets', [
        ('java', 'CombatOracle', 'packets', '@combat-packets.json'),
        ('check', 'check_combat_packets.exs', '@combat-packets.json'),
    ]),
    # VMC-037n: Player.attack on zombies and Zombie.doHurtTarget on players.
    ('combat', [
        ('java', 'CombatOracle', 'cases', '@combat-cases.json'),
        ('check', 'check_combat.exs', '@combat-cases.json'),
    ]),
    ('enchantments', [
        ('regen', 'EnchantmentMetadata', '@enchantments.json'),
        ('same', '@enchantments.json', 'priv/registry/enchantments.json'),
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
        ('java', 'LandingOracle', '@landing-cases.json'),
        ('check', 'check_landing.exs', '@landing-cases.json'),
    ]),
    ('mining', [
        ('java', 'MiningOracle', '@mining-cases.json', '@mining-ticks.json'),
        ('check', 'check_mining.exs', '@mining-cases.json', '@mining-ticks.json'),
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
    # VMC-076d: every source matrix, without and with Resistance 1, in one oracle run.
    ('damage_protection', [
        ('java', 'DamageProtectionOracle', 'all', '@damage-protection.json'),
        ('check', 'check_damage_protection.exs', '@damage-protection.json'),
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
    ('fire_geometry', [
        ('java', 'FireGeometryOracle', '@fire-geometry.json'),
        ('check', 'check_fire_contacts.exs', '@fire-geometry.json'),
    ]),
    ('heightmap', [
        ('java', 'HeightmapOracle', '@heightmap-cases.json'),
        ('check', 'check_heightmaps.exs', '@heightmap-cases.json'),
        ('check', 'check_chunk_heightmaps.exs', '@heightmap-cases.json', '@chunk-heightmaps.json'),
        ('java', 'HeightmapPacketOracle', '@chunk-heightmaps.json'),
    ]),
    ('sky_column', [
        ('java', 'SkyColumnOracle', '@sky-cases.json'),
        ('check', 'check_sky_columns.exs', '@sky-cases.json'),
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
        ('java', 'BlockHazardOracle', '@block-hazard-cases.json'),
        ('check', 'check_block_hazards.exs', '@block-hazard-cases.json'),
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
        ('java', 'StuckMotionOracle', '@stuck-motion.json'),
        ('check', 'check_stuck_motion.exs', '@stuck-motion.json'),
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
        ('regen', 'BlockEntityOracle', '@block-entities.json'),
        ('same', '@block-entities.json', 'priv/physics/block_entities.json'),
    ]),
    ('random_ticking', [
        ('regen', 'RandomTickOracle', '@random-ticking.json'),
        ('same', '@random-ticking.json', 'priv/physics/random_ticking.json'),
    ]),
    ('support', [
        ('java', 'SupportOracle', '@support.json', '@support-cases.json'),
        ('same', '@support.json', 'priv/physics/support.json'),
        ('check', 'check_support.exs', '@support-cases.json'),
    ]),
    # VMC-077m: vanilla's updater, wire evaluator and source hooks on random scenes.
    ('redstone_wire', [
        ('java', 'RedstoneWireOracle', '@redstone-wire.json'),
        ('check', 'check_wire.exs', '@redstone-wire.json'),
    ]),
    # VMC-047a: redstone's components, power and the day cycle daylight detectors read.
    ('redstone', [
        ('regen', 'RedstoneOracle', 'facts', '@redstone.json'),
        ('same', '@redstone.json', 'priv/physics/redstone.json'),
        ('java', 'RedstoneOracle', 'day', '@day.json'),
        ('java', 'RedstoneOracle', 'scenes', '@redstone-scenes.json'),
        ('check', 'check_redstone.exs', '@redstone-scenes.json', '@day.json'),
    ]),
    # VMC-039a: crops, stems, sugar cane, cactus, farmland and saplings' stages by random ticks
    # and bone meal on the block-update engine; the tree growers and saplings' trees.
    ('growth', [
        ('regen', 'GrowthOracle', 'facts', '@growth.json'),
        ('same', '@growth.json', 'priv/physics/growth.json'),
        ('java', 'GrowthOracle', 'scenes', '@growth-scenes.json'),
        ('check', 'check_growth.exs', '@growth-scenes.json'),
        ('java', 'GrowthOracle', 'trees', '@growth-trees.json'),
        ('check', 'check_growth_trees.exs', '@growth-trees.json'),
    ]),
    # VMC-031a: water and lava on the block-update engine; buckets' facts and clip.
    ('fluids', [
        ('regen', 'FluidOracle', 'facts', '@fluids.json'),
        ('same', '@fluids.json', 'priv/physics/fluids.json'),
        ('regen', 'FluidOracle', 'outlines', '@outlines.json'),
        ('same', '@outlines.json', 'priv/physics/outlines.json'),
        ('java', 'FluidOracle', 'scenes', '@fluid-scenes.json'),
        ('check', 'check_fluids.exs', '@fluid-scenes.json'),
        ('java', 'FluidOracle', 'clips', '@clips.json'),
        ('check', 'check_clips.exs', '@clips.json'),
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
    # VMC-050a: explosion craters, exposure and damage over supplied scenes.
    ('explosion', [
        ('regen', 'ExplosionOracle', 'packet', '@explosion-packet.json'),
        ('same', '@explosion-packet.json', 'priv/protocol/explosion_packet.json'),
        ('java', 'ExplosionOracle', '@explosion.json'),
        ('check', 'check_explosion.exs', '@explosion.json'),
    ]),
    # VMC-040a: bed rules and stand-up facts; stand-ups, respawn points, sleep
    # checks and counts, and the sleep packets over probe scenes.
    ('sleep', [
        ('regen', 'SleepOracle', 'facts', '@sleep-facts.json'),
        ('same', '@sleep-facts.json', 'priv/physics/sleep.json'),
        ('java', 'SleepOracle', 'fixtures', '@sleep-fixtures.json'),
        ('check', 'check_sleep.exs', '@sleep-fixtures.json'),
    ]),
    # VMC-050a: a primed TNT's motion through the physics kernel.
    ('tnt_travel', [
        ('java', 'TntTravelOracle', '@tnt-travel.json'),
        ('check', 'check_tnt_travel.exs', '@tnt-travel.json'),
    ]),
    # VMC-050a2: falling blocks' motion, landing and drops, and which cells they fall into.
    ('falling_block', [
        ('java', 'FallingBlockOracle', '@falling-block.json'),
        ('check', 'check_falling_block.exs', '@falling-block.json'),
    ]),
    ('container_drop', [
        ('java', 'ContainerDropOracle', '@container-drop.json'),
        ('check', 'check_container_drop.exs', '@container-drop.json'),
    ]),
    ('loot', [
        ('regen', 'LootOracle', 'facts', '@loot-tables.json', '@loot-registries.json', '@loot-blocks.json'),
        ('same', '@loot-tables.json', 'priv/loot/tables.json'),
        ('same', '@loot-registries.json', 'priv/loot/registries.json'),
        ('same', '@loot-blocks.json', 'priv/loot/blocks.json'),
        ('java', 'LootOracle', 'cases', '@loot-cases.json'),
        ('check', 'check_loot.exs', '@loot-cases.json'),
    ]),
    # VMC-029e: every block state's drops over tools, breakers, explosions and neighbours.
    ('block_loot', [
        ('java', 'LootOracle', 'blocks', '@block-loot-cases.json'),
        ('check', 'check_block_loot.exs', '@block-loot-cases.json'),
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
    # Worlds over terrain: vanilla decorates in whatever order its chunk threads
    # reach, so a decorated spawn column can differ between vanilla runs.
    ('spawn', [
        ('java', 'SpawnOracle', 'origins', '@origins.json'),
        ('check', 'check_spawn.exs', 'origins', '@origins.json'),
        ('java', 'SpawnOracle', 'worlds', '@worlds.json', 'terrain'),
        ('check', 'check_spawn.exs', 'worlds', '@worlds.json', 'terrain'),
    ]),
    ('world_border', [
        ('java', 'WorldBorderOracle', 'kernel', '@border-kernel.json'),
        ('check', 'check_world_border.exs', 'kernel', '@border-kernel.json'),
        ('java', 'WorldBorderOracle', 'commands', '@border-commands.json'),
        ('check', 'check_world_border.exs', 'commands', '@border-commands.json'),
    ]),
    ('player_fit', [
        ('java', 'PlayerFitOracle', '@pose-fit.json'),
        ('check', 'check_pose_fit.exs', '@pose-fit.json'),
    ]),
    ('collision_shapes', [
        ('java', 'CollisionOracle', '@collisions.json'),
        ('check', 'check_collisions.exs', '@collisions.json'),
        ('java', 'PositionCollisionOracle', '@position-collisions.json'),
        ('check', 'check_position_collisions.exs', '@position-collisions.json'),
        ('java', 'ScaffoldingCollisionOracle', '@scaffolding-collisions.json'),
        ('check', 'check_scaffolding_collisions.exs', '@scaffolding-collisions.json'),
        ('java', 'ShulkerCollisionOracle', '@shulker-collisions.json'),
        ('check', 'check_shulker_collisions.exs', '@shulker-collisions.json'),
        ('java', 'PistonCollisionOracle', '@piston-collisions.json'),
        ('check', 'check_piston_collisions.exs', '@piston-collisions.json'),
    ]),
    ('powder_snow_collision', [
        ('java', 'PowderSnowCollisionOracle', '@powder-snow-collisions.json'),
        ('check', 'check_powder_snow_collisions.exs', '@powder-snow-collisions.json'),
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
        ('regen', 'AttributeMetadata', '@attributes.json'),
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
        ('regen', 'ItemMetadata', '@items.json', '@defaults.json', '@component-types.json'),
        ('same', '@items.json', 'priv/protocol/items.json'),
        ('same', '@defaults.json', 'priv/protocol/item_defaults.json'),
        ('same', '@component-types.json', 'priv/protocol/component_types.json'),
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
        ('regen', 'InventoryBehaviorOracle'),
    ]),
    ('crafting_table_access', [
        ('java', 'CraftingTableAccessOracle', '@table-access.json'),
        ('check', 'check_table_access.exs', '@table-access.json'),
    ]),
    ('table_menu', [
        ('java', 'TableMenuOracle', '@table-menu.json'),
        ('check', 'check_table_menu.exs', '@table-menu.json'),
    ]),
    # VMC-076d: facts, cases, menus and drops from one oracle run.
    ('player_crafting', [
        ('java', 'PlayerCraftingOracle', 'all', '@player-recipes.json', '@player-crafting-cases.json',
         '@player-crafting-menu.json', '@player-crafting-drops.json'),
        ('check', 'check_crafting.exs', 'player', '@player-recipes.json', '@player-crafting-cases.json'),
        ('check', 'check_player_crafting_menu.exs', '@player-crafting-menu.json'),
        ('check', 'check_player_crafting_gestures.exs', '@player-crafting-drops.json'),
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
    # VMC-015i: whole vanilla zombie ticks over block scenes against the kernel's mob tick.
    ('spawn_facts', [
        ('regen', 'NaturalSpawnOracle', 'facts', '@spawn-facts.json'),
        ('same', '@spawn-facts.json', 'priv/registry/spawn_facts.json'),
    ]),
    ('natural_spawning', [
        ('java', 'NaturalSpawnOracle', 'fixtures', '@natural-spawning.json'),
        ('check', 'check_natural_spawning.exs', '@natural-spawning.json'),
    ]),
    ('mob_travel', [
        ('java', 'MobTravelOracle', '@mob-travel.json'),
        ('check', 'check_mob_travel.exs', '@mob-travel.json'),
    ]),
    # VMC-037o: arrows, thrown items, fireballs and eyes of ender through the projectile kernel.
    ('projectiles', [
        ('java', 'ProjectileOracle', '@projectiles.json'),
        ('check', 'check_projectiles.exs', '@projectiles.json'),
    ]),
    # VMC-041a: what the AI reads of vanilla, and whole mobs with their goals.
    ('ai_facts', [
        ('regen', 'MobAiOracle', 'facts', '@ai-facts.json'),
        ('same', '@ai-facts.json', 'priv/registry/ai_facts.json'),
    ]),
    ('mob_ai', [
        ('java', 'MobAiOracle', 'cases', '@mob-ai.json'),
        ('check', 'check_mob_ai.exs', '@mob-ai.json'),
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
    ('orb_travel', [
        ('java', 'OrbTravelOracle', '@orb-travel.json'),
        ('check', 'check_orb_travel.exs', '@orb-travel.json'),
    ]),
    ('player_experience', [
        ('java', 'PlayerExperienceOracle', '@player-experience.json'),
        ('check', 'check_player_experience.exs', '@player-experience.json'),
    ]),
]
