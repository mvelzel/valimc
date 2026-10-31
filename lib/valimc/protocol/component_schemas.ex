defmodule Valimc.Protocol.ComponentSchemas do
  @moduledoc """
  The schema of each item component type that `ComponentSchema` reads and
  writes (VMC-004b4), transcribed from pinned 26.3's `DataComponents` codecs.
  Components with hand-written codecs (`ItemStack`'s older entries) are not
  listed here.
  """

  # Float defaults are the 32-bit floats vanilla holds.
  alias Valimc.Data.Float32
  @dye {:enum, "dye_color"}
  @non_negative_int {:range, :varint, 0, nil}
  @positive_int {:range, :varint, 1, nil}
  @non_negative_float {:range, :float, 0.0, nil}
  @resolvable_int {:either, :int, {:resource_key, "minecraft:context_int_provider"}}
  @resolvable_float {:either, :float, {:resource_key, "minecraft:context_float_provider"}}

  @sound {:holder, "minecraft:sound_event"}

  @consume_effect {:dispatch, {:registry, "minecraft:consume_effect_type"},
                   %{
                     "minecraft:apply_effects" => [
                       {"effects", {:list, :mob_effect, :infinity}},
                       {"probability", {:range, :float, 0.0, 1.0}, 1.0}
                     ],
                     "minecraft:remove_effects" => [
                       {"effects", {:holder_set, "minecraft:mob_effect"}}
                     ],
                     "minecraft:clear_all_effects" => [],
                     "minecraft:teleport_randomly" => [
                       {"diameter", {:range, :float, {:gt, 0.0}, nil}, 16.0},
                       {"directional_particles", :bool, true}
                     ],
                     "minecraft:play_sound" => [{"sound", @sound}]
                   }}

  @kinetic_condition {:record,
                      [
                        {"max_duration_ticks", @non_negative_int},
                        {"min_speed", :float, 0.0},
                        {"min_relative_speed", :float, 0.0}
                      ]}

  # `BlockPredicate`. Its NBT test and partial component predicates, which only
  # map-making uses, are refused; blocks, states and exact components work.
  @block_predicate {:record,
                    [
                      {"blocks", {:optional, {:holder_set, "minecraft:block"}}},
                      {"state",
                       {:optional,
                        {:map, {:string, 32767},
                         {:either, {:string, 32767},
                          {:record,
                           [
                             {"min", {:optional, {:string, 32767}}},
                             {"max", {:optional, {:string, 32767}}}
                           ]}}, :infinity}}},
                      {"nbt", {:optional, :unsupported}},
                      {"components", :components, []},
                      {"predicates", :no_predicates, []}
                    ]}

  @swing_animation {:record,
                    [
                      {"type", {:enum, "swing_animation"}, "whack"},
                      {"duration", @non_negative_int, 6}
                    ]}

  @firework_explosion {:record,
                       [
                         {"shape", {:enum, "firework_shape"}},
                         {"colors", {:list, :int, :infinity}, []},
                         {"fade_colors", {:list, :int, :infinity}, []},
                         {"has_trail", :bool, false},
                         {"has_twinkle", :bool, false}
                       ]}

  @registry_variants ~w(villager/variant:villager_type wolf/variant:wolf_variant
    wolf/sound_variant:wolf_sound_variant pig/variant:pig_variant
    pig/sound_variant:pig_sound_variant cow/variant:cow_variant
    cow/sound_variant:cow_sound_variant chicken/variant:chicken_variant
    chicken/sound_variant:chicken_sound_variant zombie_nautilus/variant:zombie_nautilus_variant
    frog/variant:frog_variant cat/variant:cat_variant cat/sound_variant:cat_sound_variant
    provides_pottery_pattern:decorated_pot_pattern block_transformer:block_transformer
    damage_type:damage_type)
  @enum_variants ~w(fox/variant:fox_variant parrot/variant:parrot_variant
    mooshroom/variant:mooshroom_variant rabbit/variant:rabbit_variant
    horse/variant:horse_variant llama/variant:llama_variant)
  @dyes ~w(dye base_color wolf/collar cat/collar sheep/color shulker/color cushion/color)

  @schemas Map.merge(
             Map.new(@registry_variants, fn pair ->
               [name, registry] = String.split(pair, ":")
               {"minecraft:" <> name, {:registry, "minecraft:" <> registry}}
             end),
             Map.merge(
               Map.new(@enum_variants, fn pair ->
                 [name, enum] = String.split(pair, ":")
                 {"minecraft:" <> name, {:enum, enum}}
               end),
               Map.new(@dyes, &{"minecraft:" <> &1, @dye})
             )
           )
           |> Map.merge(%{
             "minecraft:use_effects" =>
               {:record,
                [
                  {"can_sprint", :bool, false},
                  {"interact_vibrations", :bool, true},
                  {"speed_multiplier", {:range, :float, 0.0, 1.0}, Float32.round(0.2)}
                ]},
             "minecraft:custom_model_data" =>
               {:record,
                [
                  {"floats", {:list, :float, :infinity}, []},
                  {"flags", {:list, :bool, :infinity}, []},
                  {"strings", {:list, {:string, 32767}, :infinity}, []},
                  {"colors", {:list, :rgb, :infinity}, []}
                ]},
             "minecraft:use_cooldown" =>
               {:record,
                [
                  {"seconds", {:range, :float, {:gt, 0.0}, nil}},
                  {"cooldown_group", {:optional, :identifier}}
                ]},
             "minecraft:damage_resistant" =>
               {:record, [{"types", {:holder_set, "minecraft:damage_type"}}]},
             "minecraft:weapon" =>
               {:record,
                [
                  {"item_damage_per_attack", @non_negative_int, 1},
                  {"disable_blocking_for_seconds", @non_negative_float, 0.0}
                ]},
             "minecraft:attack_range" =>
               {:record,
                [
                  {"min_reach", {:range, :float, 0.0, 64.0}, 0.0},
                  {"max_reach", {:range, :float, 0.0, 64.0}, 3.0},
                  {"min_creative_reach", {:range, :float, 0.0, 64.0}, 0.0},
                  {"max_creative_reach", {:range, :float, 0.0, 64.0}, 5.0},
                  {"hitbox_margin", {:range, :float, 0.0, 1.0}, Float32.round(0.3)},
                  {"mob_factor", {:range, :float, 0.0, 2.0}, 1.0}
                ]},
             "minecraft:enchantable" => {:record, [{"value", @positive_int}]},
             "minecraft:repairable" => {:record, [{"items", {:holder_set, "minecraft:item"}}]},
             "minecraft:glider" => :unit,
             "minecraft:waxed" => :unit,
             "minecraft:attack_animation" => @swing_animation,
             "minecraft:interact_animation" => @swing_animation,
             "minecraft:additional_trade_cost" => :varint,
             "minecraft:villager_food" => {:record, [{"nutrition", @positive_int}]},
             "minecraft:dyed_color" => :rgb,
             "minecraft:map_post_processing" => {:enum, "map_post_processing"},
             "minecraft:potion_duration_scale" => @non_negative_float,
             "minecraft:provides_trim_material" => {:holder, "minecraft:trim_material"},
             "minecraft:jukebox_playable" => {:holder, "minecraft:jukebox_song"},
             "minecraft:provides_banner_patterns" => {:holder_set, "minecraft:banner_pattern"},
             "minecraft:painting/variant" => {:holder, "minecraft:painting_variant"},
             "minecraft:lodestone_tracker" =>
               {:record,
                [
                  {"target",
                   {:optional,
                    {:record,
                     [
                       {"dimension", {:resource_key, "minecraft:dimension"}},
                       {"pos", :block_pos}
                     ]}}},
                  {"tracked", :bool, true}
                ]},
             "minecraft:firework_explosion" => @firework_explosion,
             "minecraft:fireworks" =>
               {:record,
                [
                  {"flight_duration", :unsigned_byte, 0},
                  {"explosions", {:list, @firework_explosion, 256}, []}
                ]},
             "minecraft:note_block_sound" => :identifier,
             "minecraft:banner_patterns" =>
               {:list,
                {:record, [{"pattern", {:holder, "minecraft:banner_pattern"}}, {"color", @dye}]},
                :infinity},
             "minecraft:break_sound" => {:holder, "minecraft:sound_event"},
             "minecraft:compostable" => {:record, [{"layers", @resolvable_int}]},
             "minecraft:cooking_fuel" =>
               {:record,
                [{"burn_time", @resolvable_int}, {"speed_multiplier", @resolvable_float}]},
             "minecraft:brewing_fuel" =>
               {:record, [{"uses", @resolvable_int}, {"speed_multiplier", @resolvable_float}]},
             "minecraft:mob_visibility" =>
               {:record,
                [
                  {"targeting_entity_types", {:holder_set, "minecraft:entity_type"}},
                  {"visibility", {:range, :float, 0.0, 10.0}}
                ]},
             "minecraft:attribute_modifiers" =>
               {:list,
                {:record,
                 [
                   {"type", {:registry, "minecraft:attribute"}},
                   {"id", :identifier},
                   {"amount", :double},
                   {"operation", {:enum, "attribute_operation"}},
                   {"slot", {:enum, "equipment_slot_group"}, "any"},
                   {"display",
                    {:dispatch, {:enum, "attribute_display"},
                     %{"default" => [], "hidden" => [], "override" => [{"value", :text}]}},
                    %{"type" => "default"}}
                 ]}, :infinity},
             "minecraft:consumable" =>
               {:record,
                [
                  {"consume_seconds", @non_negative_float, Float32.round(1.6)},
                  {"animation", {:enum, "item_use_animation"}, "eat"},
                  {"sound", @sound, "minecraft:entity.generic.eat"},
                  {"has_consume_particles", :bool, true},
                  {"on_consume_effects", {:list, @consume_effect, :infinity}, []}
                ]},
             "minecraft:death_protection" =>
               {:record, [{"death_effects", {:list, @consume_effect, :infinity}, []}]},
             "minecraft:equippable" =>
               {:record,
                [
                  {"slot", {:enum, "equipment_slot"}},
                  {"equip_sound", @sound, "minecraft:item.armor.equip_generic"},
                  {"asset_id", {:optional, {:resource_key, "minecraft:equipment_asset"}}},
                  {"camera_overlay", {:optional, :identifier}},
                  {"allowed_entities", {:optional, {:holder_set, "minecraft:entity_type"}}},
                  {"dispensable", :bool, true},
                  {"swappable", :bool, true},
                  {"damage_on_hurt", :bool, true},
                  {"equip_on_interact", :bool, false},
                  {"can_be_sheared", :bool, false},
                  {"shearing_sound", @sound, "minecraft:item.shears.snip"}
                ]},
             "minecraft:tool" =>
               {:record,
                [
                  {"rules",
                   {:list,
                    {:record,
                     [
                       {"blocks", {:holder_set, "minecraft:block"}},
                       {"speed", {:optional, {:range, :float, {:gt, 0.0}, nil}}},
                       {"correct_for_drops", {:optional, :bool}}
                     ]}, :infinity}},
                  {"default_mining_speed", :float, 1.0},
                  {"damage_per_block", @non_negative_int, 1},
                  {"can_destroy_blocks_in_creative", :bool, true}
                ]},
             "minecraft:blocks_attacks" =>
               {:record,
                [
                  {"block_delay_seconds", @non_negative_float, 0.0},
                  {"disable_cooldown_scale", @non_negative_float, 1.0},
                  {"damage_reductions",
                   {:list,
                    {:record,
                     [
                       {"horizontal_blocking_angle", {:range, :float, {:gt, 0.0}, nil}, 90.0},
                       {"type", {:optional, {:holder_set, "minecraft:damage_type"}}},
                       {"base", :float},
                       {"factor", :float}
                     ]}, :infinity},
                   [
                     %{
                       "horizontal_blocking_angle" => 90.0,
                       "type" => nil,
                       "base" => 0.0,
                       "factor" => 1.0
                     }
                   ]},
                  {"item_damage",
                   {:record,
                    [{"threshold", @non_negative_float}, {"base", :float}, {"factor", :float}]},
                   %{"threshold" => 1.0, "base" => 0.0, "factor" => 1.0}},
                  {"bypassed_by", {:optional, {:holder_set, "minecraft:damage_type"}}},
                  {"block_sound", {:optional, @sound}},
                  {"disabled_sound", {:optional, @sound}}
                ]},
             "minecraft:kinetic_weapon" =>
               {:record,
                [
                  {"contact_cooldown_ticks", @non_negative_int, 10},
                  {"delay_ticks", @non_negative_int, 0},
                  {"dismount_conditions", {:optional, @kinetic_condition}},
                  {"knockback_conditions", {:optional, @kinetic_condition}},
                  {"damage_conditions", {:optional, @kinetic_condition}},
                  {"forward_movement", :float, 0.0},
                  {"damage_multiplier", :float, 1.0},
                  {"sound", {:optional, @sound}},
                  {"hit_sound", {:optional, @sound}}
                ]},
             "minecraft:piercing_weapon" =>
               {:record,
                [
                  {"deals_knockback", :bool, true},
                  {"dismounts", :bool, false},
                  {"sound", {:optional, @sound}},
                  {"hit_sound", {:optional, @sound}}
                ]},
             "minecraft:can_place_on" => {:compact_list, @block_predicate},
             "minecraft:can_break" => {:compact_list, @block_predicate},
             "minecraft:trim" =>
               {:record,
                [
                  {"material", {:holder, "minecraft:trim_material"}},
                  {"pattern", {:holder, "minecraft:trim_pattern"}}
                ]}
           })

  @doc "Every component type with a schema."
  def names, do: Map.keys(@schemas)

  @doc "The schema of component `name`, or nil."
  def schema(name), do: Map.get(@schemas, name)
end
