import java.io.*;
import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponentType;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.nbt.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.RegistryOps;

/**
 * Item component values in both of vanilla's formats (VMC-004b): every item
 * prototype's components and values parsed from SNBT by each type's own codec.
 * Usage: ItemComponentOracle generate CASES.json | verify ELIXIR.json
 *
 * A case holds the network bytes (`type.streamCodec()`) and the data form
 * (`type.codec()` through `NbtOps`, as network NBT). `verify` decodes ValiMC's
 * re-encoded bytes and data with the same codecs: each must equal the case's
 * value, and ValiMC's data tag must equal the one Mojang writes.
 */
public class ItemComponentOracle {
  private static RegistryAccess.Frozen registries;
  private static RegistryOps<Tag> ops;

  // Values no prototype holds, written as their data form.
  private static final String[][] CONSTRUCTED = {
    {"use_effects", "{can_sprint:1b,interact_vibrations:0b,speed_multiplier:0.75f}"},
    {"use_effects", "{}"},
    {"damage_type", "'minecraft:falling_anvil'"},
    {"custom_model_data", "{floats:[1.5f,-0.0f],flags:[1b,0b],strings:['a','Ünicode 😀'],colors:[16711680,-1]}"},
    {"custom_model_data", "{colors:[[1.0f,0.5f,0.0f]]}"},
    {"use_cooldown", "{seconds:1.5f,cooldown_group:'valimc:test'}"},
    {"use_cooldown", "{seconds:0.25f}"},
    {"damage_resistant", "{types:['minecraft:lava','minecraft:in_fire']}"},
    {"damage_resistant", "{types:'minecraft:cactus'}"},
    {"weapon", "{item_damage_per_attack:3,disable_blocking_for_seconds:2.5f}"},
    {"attack_range", "{min_reach:1.0f,max_reach:6.5f,min_creative_reach:0.5f,max_creative_reach:8.0f,hitbox_margin:0.1f,mob_factor:0.5f}"},
    {"enchantable", "{value:22}"},
    {"repairable", "{items:['minecraft:diamond','minecraft:stick']}"},
    {"repairable", "{items:'#minecraft:planks'}"},
    {"glider", "{}"},
    {"waxed", "{}"},
    {"attack_animation", "{type:'stab',duration:12}"},
    {"interact_animation", "{type:'none'}"},
    {"additional_trade_cost", "7"},
    {"villager_food", "{nutrition:5}"},
    {"dye", "'magenta'"},
    {"dyed_color", "-6265536"},
    {"dyed_color", "[0.25f,0.5f,1.0f]"},
    {"map_post_processing", "'scale'"},
    {"potion_duration_scale", "0.25f"},
    {"provides_trim_material", "'minecraft:amethyst'"},
    {"jukebox_playable", "'minecraft:pigstep'"},
    {"provides_banner_patterns", "'#minecraft:pattern_item/globe'"},
    {"provides_banner_patterns", "['minecraft:creeper','minecraft:skull']"},
    {"lodestone_tracker", "{target:{dimension:'minecraft:the_nether',pos:[I;-30000000,-64,29999999]},tracked:0b}"},
    {"lodestone_tracker", "{}"},
    {"firework_explosion", "{shape:'creeper',colors:[I;1,16777215],fade_colors:[I;-1],has_trail:1b,has_twinkle:1b}"},
    {"firework_explosion", "{shape:'small_ball'}"},
    {"fireworks", "{flight_duration:3b,explosions:[{shape:'star',colors:[I;255]},{shape:'burst'}]}"},
    {"fireworks", "{flight_duration:-56b}"},
    {"note_block_sound", "'minecraft:entity.pig.ambient'"},
    {"banner_patterns", "[{pattern:'minecraft:creeper',color:'lime'},{pattern:'minecraft:flow',color:'black'}]"},
    {"break_sound", "'minecraft:entity.item.break'"},
    {"compostable", "{layers:3}"},
    {"cooking_fuel", "{burn_time:200,speed_multiplier:1.5f}"},
    {"brewing_fuel", "{uses:20,speed_multiplier:1.0f}"},
    {"mob_visibility", "{targeting_entity_types:['minecraft:zombie','minecraft:husk'],visibility:0.5f}"},
    {"trim", "{material:'minecraft:redstone',pattern:'minecraft:silence'}"},
    {"villager/variant", "'minecraft:taiga'"},
    {"wolf/variant", "'minecraft:snowy'"},
    {"wolf/sound_variant", "'minecraft:grumpy'"},
    {"wolf/collar", "'blue'"},
    {"fox/variant", "'snow'"},
    {"parrot/variant", "'gray'"},
    {"mooshroom/variant", "'brown'"},
    {"rabbit/variant", "'evil'"},
    {"pig/variant", "'minecraft:cold'"},
    {"pig/sound_variant", "'minecraft:big'"},
    {"cow/variant", "'minecraft:warm'"},
    {"cow/sound_variant", "'minecraft:moody'"},
    {"chicken/variant", "'minecraft:cold'"},
    {"chicken/sound_variant", "'minecraft:picky'"},
    {"zombie_nautilus/variant", "'minecraft:warm'"},
    {"frog/variant", "'minecraft:cold'"},
    {"horse/variant", "'dark_brown'"},
    {"painting/variant", "'minecraft:kebab'"},
    {"llama/variant", "'gray'"},
    {"cat/variant", "'minecraft:jellie'"},
    {"cat/sound_variant", "'minecraft:royal'"},
    {"cat/collar", "'red'"},
    {"sheep/color", "'pink'"},
    {"shulker/color", "'black'"},
    {"cushion/color", "'green'"},
    {"provides_pottery_pattern", "'minecraft:skull'"},
    {"base_color", "'yellow'"},
    {"block_transformer", "'minecraft:hoe'"},
    // VMC-004b5: gameplay records.
    {"attribute_modifiers", "[{type:'minecraft:attack_damage',id:'valimc:a',amount:2.5d,operation:'add_value',slot:'mainhand'},"
      + "{type:'minecraft:scale',id:'valimc:b',amount:-0.5d,operation:'add_multiplied_total',display:{type:'hidden'}},"
      + "{type:'minecraft:armor',id:'valimc:c',amount:1.0d,operation:'add_multiplied_base',slot:'armor',display:{type:'override',value:'Shiny'}}]"},
    {"consumable", "{consume_seconds:0.5f,animation:'drink',sound:'minecraft:item.honey_bottle.drink',has_consume_particles:0b,on_consume_effects:["
      + "{type:'apply_effects',effects:[{id:'minecraft:speed',amplifier:2b,duration:200,ambient:1b,show_particles:0b},"
      + "{id:'minecraft:poison',duration:40,show_icon:0b,hidden_effect:{amplifier:1b,duration:600}}],probability:0.5f},"
      + "{type:'remove_effects',effects:['minecraft:wither','minecraft:hunger']},"
      + "{type:'clear_all_effects'},{type:'teleport_randomly',diameter:8.0f,directional_particles:0b},{type:'play_sound',sound:'minecraft:entity.fox.teleport'}]}"},
    {"death_protection", "{}"},
    {"equippable", "{slot:'head',equip_sound:'minecraft:item.armor.equip_gold',asset_id:'minecraft:gold',camera_overlay:'minecraft:misc/pumpkinblur',"
      + "allowed_entities:['minecraft:player','minecraft:zombie'],dispensable:0b,swappable:0b,damage_on_hurt:0b,equip_on_interact:1b,can_be_sheared:1b,shearing_sound:'minecraft:item.saddle.unequip'}"},
    {"equippable", "{slot:'saddle',allowed_entities:'#minecraft:can_equip_saddle'}"},
    {"tool", "{rules:[{blocks:'#minecraft:mineable/pickaxe',speed:4.5f,correct_for_drops:1b},{blocks:['minecraft:cobweb'],speed:15.0f},{blocks:'minecraft:stone',correct_for_drops:0b}],default_mining_speed:0.5f,damage_per_block:2,can_destroy_blocks_in_creative:0b}"},
    {"blocks_attacks", "{block_delay_seconds:0.25f,disable_cooldown_scale:2.0f,damage_reductions:[{horizontal_blocking_angle:45.0f,type:'#minecraft:is_projectile',base:1.0f,factor:0.5f},{base:-1.0f,factor:0.0f}],"
      + "item_damage:{threshold:3.0f,base:1.0f,factor:2.0f},bypassed_by:'#minecraft:bypasses_shield',block_sound:'minecraft:item.shield.block',disabled_sound:'minecraft:item.shield.break'}"},
    {"blocks_attacks", "{damage_reductions:[]}"},
    {"kinetic_weapon", "{contact_cooldown_ticks:3,delay_ticks:7,dismount_conditions:{max_duration_ticks:20,min_speed:0.5f},knockback_conditions:{max_duration_ticks:5,min_relative_speed:1.5f},"
      + "damage_conditions:{max_duration_ticks:60},forward_movement:0.25f,damage_multiplier:1.5f,sound:'minecraft:item.spear.use',hit_sound:'minecraft:item.spear.hit'}"},
    {"piercing_weapon", "{deals_knockback:0b,dismounts:1b,sound:'minecraft:item.spear.attack',hit_sound:'minecraft:item.spear.hit'}"},
    // VMC-004b6: item-holding components.
    {"container", "[{slot:0,item:{id:'minecraft:stone',count:64}},{slot:13,item:'minecraft:diamond_sword'},{slot:26,item:{id:'minecraft:bundle',components:{"
      + "'minecraft:bundle_contents':[{id:'minecraft:shulker_box',components:{'minecraft:container':[{slot:2,item:{id:'minecraft:diamond_pickaxe',components:{"
      + "'minecraft:custom_name':'Pick','minecraft:enchantments':{'minecraft:efficiency':5},'minecraft:damage':12}}}]}},{id:'minecraft:arrow',count:12}]}}}]"},
    {"container", "[{slot:255,item:{id:'minecraft:dirt',count:3,components:{'!minecraft:item_name':{}}}}]"},
    {"bundle_contents", "[{id:'minecraft:dirt',count:16},'minecraft:ender_pearl',{id:'minecraft:red_bundle',components:{'minecraft:bundle_contents':[]}}]"},
    {"charged_projectiles", "[{id:'minecraft:firework_rocket',components:{'minecraft:fireworks':{flight_duration:2b}}},'minecraft:arrow','minecraft:arrow']"},
    {"use_remainder", "{id:'minecraft:bowl',count:2}"},
    {"sulfur_cube_content", "'minecraft:sand'"},
    {"pot_decorations", "{back:'minecraft:brick',front:{id:'minecraft:skull_pottery_sherd'},left:'minecraft:angler_pottery_sherd'}"},
    // VMC-004b7: entity, block-entity, profile, book and sign data.
    {"entity_data", "{id:'minecraft:zombie',CustomName:'Bob',Health:5.0f,Tags:['a','b']}"},
    {"block_entity_data", "{id:'minecraft:chest',Lock:{items:'minecraft:diamond'},CustomName:'Loot'}"},
    {"bees", "[{entity_data:{id:'minecraft:bee',HasNectar:1b},ticks_in_hive:120,min_ticks_in_hive:600},{entity_data:{id:'minecraft:bee'},ticks_in_hive:0,min_ticks_in_hive:0}]"},
    {"profile", "'Notch'"},
    {"profile", "{id:[I;1,2,3,4],name:'Steve',properties:[{name:'textures',value:'e30=',signature:'c2ln'}]}"},
    {"profile", "{id:[I;-1,0,7,8],texture:'minecraft:entity/player/wide/alex',model:'slim'}"},
    {"profile", "{name:'Alex',properties:{textures:['e30=']},cape:'minecraft:cape/x',elytra:'minecraft:elytra/x'}"},
    {"writable_book_content", "{pages:['one',{raw:'two',filtered:'t*o'}]}"},
    {"written_book_content", "{title:{raw:'Title',filtered:'T'},author:'Author',generation:2,pages:['{\"text\":\"raw\"}',{raw:{text:'Hello',bold:1b}}],resolved:1b}"},
    {"written_book_content", "{title:'Short',author:''}"},
    {"sign_text_front", "{messages:['a',{text:'b',color:'red'},'','d'],color:'blue',has_glowing_text:1b}"},
    {"sign_text_back", "{messages:['','','',''],filtered_messages:['x','','',''],color:'black'}"},
    {"lock", "{items:'minecraft:tripwire_hook',count:{min:1,max:3},components:{'minecraft:custom_name':'Key'}}"},
    {"lock", "{count:2}"},
    {"container_loot", "{loot_table:'minecraft:chests/simple_dungeon',seed:-123456789012L}"},
    {"debug_stick_state", "{'minecraft:oak_stairs':'facing','minecraft:redstone_wire':'power'}"},
    {"recipes", "['minecraft:crafting_table','minecraft:stick']"},
    {"recipes", "[]"},
    // Types no prototype holds, with older hand-written codecs.
    {"axolotl/variant", "'gold'"},
    {"salmon/size", "'large'"},
    {"tropical_fish/pattern", "'stripey'"},
    {"tropical_fish/base_color", "'orange'"},
    {"tropical_fish/pattern_color", "'cyan'"},
    {"custom_data", "{a:1b,b:[I;1,2],c:{d:'e'}}"},
    {"custom_name", "{text:'Named',italic:0b}"},
    {"intangible_projectile", "{}"},
    {"map_id", "42"},
    {"tooltip_style", "'valimc:fancy'"},
    {"unbreakable", "{}"},
    {"creative_slot_lock", "{}"},
    {"can_place_on", "{blocks:'minecraft:stone'}"},
    {"can_break", "[{blocks:['minecraft:oak_log','minecraft:birch_log'],state:{axis:'y'}},{blocks:'#minecraft:wool'},"
      + "{state:{age:{min:'2',max:'5'},half:{min:'lower'}}},{components:{'minecraft:dyed_color':255,'minecraft:enchantable':{value:3}}}]"},
  };

  private static DataComponentType<?> type(String name) {
    var type = BuiltInRegistries.DATA_COMPONENT_TYPE.getValue(Identifier.parse(name));
    if (type == null) throw new AssertionError("Unknown component " + name);
    return type;
  }

  @SuppressWarnings("unchecked")
  private static <T> byte[] stream(DataComponentType<T> type, Object value) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      type.streamCodec().encode(buf, (T) value);
      var bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes); return bytes;
    } finally { buf.release(); }
  }

  private static <T> T fromStream(DataComponentType<T> type, byte[] bytes) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(bytes), registries);
    try {
      var value = type.streamCodec().decode(buf);
      if (buf.isReadable()) throw new AssertionError("Trailing bytes for " + type);
      return value;
    } finally { buf.release(); }
  }

  @SuppressWarnings("unchecked")
  private static <T> Tag data(DataComponentType<T> type, Object value) {
    return type.codecOrThrow().encodeStart(ops, (T) value).getOrThrow();
  }

  private static byte[] nbt(Tag tag) throws IOException {
    var out = new ByteArrayOutputStream();
    NbtIo.writeAnyTag(tag, new DataOutputStream(out));
    return out.toByteArray();
  }

  private static Tag readNbt(byte[] bytes) throws IOException {
    return NbtIo.readAnyTag(new DataInputStream(new ByteArrayInputStream(bytes)), NbtAccounter.unlimitedHeap());
  }

  private static List<Map.Entry<String, Object>> cases() throws Exception {
    var cases = new ArrayList<Map.Entry<String, Object>>();
    for (var item : BuiltInRegistries.ITEM)
      for (var component : item.components())
        cases.add(Map.entry(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(component.type()).toString(), component.value()));
    for (var constructed : CONSTRUCTED) {
      var type = type(constructed[0]);
      var tag = TagParser.create(NbtOps.INSTANCE).parseFully(constructed[1]);
      var codec = type.codec() != null ? type.codec() : null;
      Object value;
      if (codec != null) value = codec.parse(ops, tag).getOrThrow();
      else value = constructedTransient(constructed[0], tag);
      cases.add(Map.entry(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type).toString(), value));
    }
    return cases;
  }

  // Components with no data form are built directly.
  private static Object constructedTransient(String name, Tag tag) {
    return switch (name) {
      case "additional_trade_cost" -> ((IntTag) tag).intValue();
      case "creative_slot_lock" -> net.minecraft.util.Unit.INSTANCE;
      case "map_post_processing" -> net.minecraft.world.item.component.MapPostProcessing.valueOf(
        tag.asString().orElseThrow().toUpperCase(Locale.ROOT));
      default -> throw new AssertionError("No data codec for " + name);
    };
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    // Prototypes bind to the client's registries, so every holder and tag has one owner.
    registries = NetworkRegistries.load(VanillaRegistries.createWorldLookup());
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(registries).forEach(p -> p.apply());
    ops = registries.createSerializationContext(NbtOps.INSTANCE);
    var cases = cases();
    var hex = HexFormat.of();
    if (args[0].equals("generate")) {
      var seen = new HashSet<String>();
      var fixtures = new ArrayList<Map<String, Object>>();
      for (int i = 0; i < cases.size(); i++) {
        var entry = cases.get(i);
        var type = type(entry.getKey());
        var bytes = hex.formatHex(stream(type, entry.getValue()));
        if (!seen.add(entry.getKey() + " " + bytes)) continue;
        var fixture = new LinkedHashMap<String, Object>();
        fixture.put("index", i); fixture.put("component", entry.getKey()); fixture.put("stream", bytes);
        if (type.codec() != null) fixture.put("data", hex.formatHex(nbt(data(type, entry.getValue()))));
        fixtures.add(fixture);
      }
      Files.writeString(Path.of(args[1]), new Gson().toJson(fixtures));
      System.out.println("PASS: Generated " + fixtures.size() + " distinct component values across "
        + fixtures.stream().map(f -> f.get("component")).distinct().count() + " component types.");
    } else if (args[0].equals("verify")) {
      var rows = JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      int data = 0;
      for (var row : rows) {
        var object = row.getAsJsonObject();
        var entry = cases.get(object.get("index").getAsInt());
        var type = type(entry.getKey());
        var expected = entry.getValue();
        var decoded = fromStream(type, hex.parseHex(object.get("stream").getAsString()));
        if (!expected.equals(decoded))
          throw new AssertionError("ValiMC stream value differs: " + entry.getKey() + " " + expected + " / " + decoded);
        if (object.has("data")) {
          var tag = readNbt(hex.parseHex(object.get("data").getAsString()));
          if (!tag.equals(data(type, expected)))
            throw new AssertionError("ValiMC data form differs: " + entry.getKey() + " " + tag + " / " + data(type, expected));
          var parsed = type.codecOrThrow().parse(ops, tag).getOrThrow();
          if (!expected.equals(parsed))
            throw new AssertionError("ValiMC data value differs: " + entry.getKey());
          data++;
        }
      }
      System.out.println("PASS: Mojang decoded " + rows.size() + " ValiMC component values from the network and "
        + data + " from the data form.");
    } else throw new IllegalArgumentException("generate/verify expected");
  }
}
