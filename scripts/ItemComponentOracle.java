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
