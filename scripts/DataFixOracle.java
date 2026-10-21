import com.google.gson.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtIo;
import net.minecraft.nbt.NbtUtils;
import net.minecraft.nbt.TagParser;
import net.minecraft.resources.Identifier;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ChunkMap;
import net.minecraft.util.datafix.DataFixTypes;
import net.minecraft.util.datafix.DataFixers;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.chunk.storage.SimpleRegionStorage;

/**
 * Older chunks as vanilla 26.3 upgrades them (VMC-028d).
 *
 * <p>`CASES OUT`: CASES is JSON `{"cases": [{name, kind, nbt}]}` (kind `chunk` or `entities`, nbt
 * a chunk's root as named binary NBT in base64, at an older `DataVersion`); this oracle adds its
 * own 26.2 (4903) cases, one or more per fix between 26.2 and 26.3, and writes to OUT each case's
 * input and what vanilla's chunk storage makes of it: `DataFixTypes.CHUNK` with the overworld's
 * data fixing context (`ChunkMap.getChunkDataFixContextTag`) or `DataFixTypes.ENTITY_CHUNK`, from
 * the chunk's version to the current one, the context removed and the current version stored, as
 * `SimpleRegionStorage.upgradeChunkTag` does.
 */
public class DataFixOracle {
  static final int OLD = 4903;

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var gson = new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create();
    var input = JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();
    var cases = new ArrayList<String[]>();
    for (var element : input.getAsJsonArray("cases")) {
      var row = element.getAsJsonObject();
      cases.add(new String[] {row.get("name").getAsString(), row.get("kind").getAsString(), row.get("nbt").getAsString()});
    }
    for (var synthetic : synthetic()) {
      var tag = TagParser.parseCompoundFully(synthetic[2]);
      cases.add(new String[] {synthetic[0], synthetic[1], encode(tag)});
    }

    var target = SharedConstants.getCurrentVersion().dataVersion().version();
    var fixer = DataFixers.getDataFixer();
    var context = ChunkMap.getChunkDataFixContextTag(Level.OVERWORLD, Optional.of(Identifier.withDefaultNamespace("noise")));
    var out = new JsonArray();
    for (var c : cases) {
      var tag = decode(c[2]);
      var version = NbtUtils.getDataVersion(tag, -1);
      var upgraded = tag.copy();
      if (c[1].equals("chunk")) {
        SimpleRegionStorage.injectDatafixingContext(upgraded, context);
        upgraded = DataFixTypes.CHUNK.update(fixer, upgraded, version, target);
        upgraded.remove("__context");
      } else {
        upgraded = DataFixTypes.ENTITY_CHUNK.update(fixer, upgraded, version, target);
      }
      NbtUtils.addDataVersion(upgraded, target);
      var row = new JsonObject();
      row.addProperty("name", c[0]);
      row.addProperty("kind", c[1]);
      row.addProperty("version", version);
      row.addProperty("input", c[2]);
      row.addProperty("expected", encode(upgraded));
      out.add(row);
    }
    var result = new JsonObject();
    result.addProperty("data_version", target);
    result.add("cases", out);
    Files.writeString(Path.of(args[1]), gson.toJson(result) + "\n");
    System.out.println("PASS: " + out.size() + " chunks upgraded by vanilla (" + (out.size() - synthetic().size()) + " exported, "
        + synthetic().size() + " for each fix)");
  }

  static String encode(CompoundTag tag) throws IOException {
    var bytes = new ByteArrayOutputStream();
    NbtIo.writeUnnamedTag(tag, new DataOutputStream(bytes));
    return Base64.getEncoder().encodeToString(bytes.toByteArray());
  }

  static CompoundTag decode(String text) throws IOException {
    var bytes = Base64.getDecoder().decode(text);
    return NbtIo.read(new DataInputStream(new ByteArrayInputStream(bytes)));
  }

  static String chunk(String status, String rest) {
    return "{DataVersion: " + OLD + ", xPos: 3, zPos: -2, yPos: -4, Status: \"" + status + "\", LastUpdate: 40L,"
        + " InhabitedTime: 0L, isLightOn: 1b" + rest + "}";
  }

  static final String SECTIONS = ", sections: ["
      + "{Y: -1b, block_states: {palette: [{Name: \"minecraft:stone\"}, {Name: \"minecraft:deepslate\", Properties: {axis: \"y\"}}],"
      + " data: [L; 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L,"
      + " 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L, 1L, 0L]},"
      + " biomes: {palette: [\"minecraft:plains\"]}},"
      + "{Y: 2b, block_states: {palette: [{Name: \"minecraft:air\"}]}, biomes: {palette: [\"minecraft:forest\"]}}]";

  static final String TEXT = "{messages: [\"\", \"Upgraded\", \"\", \"\"], color: \"black\", has_glowing_text: 0b}";

  static String map(String type, String name) {
    return "{id: \"minecraft:filled_map\", count: 1, components: {\"minecraft:map_id\": 7, \"minecraft:map_decorations\": {\"+\": {type: \""
        + type + "\", x: 120.0d, z: -340.0d, rotation: 180.0f}}" + (name == null ? "" : ", \"minecraft:item_name\": " + name) + "}}";
  }

  static List<String[]> synthetic() {
    var items = "[{Slot: 0b, " + map("minecraft:monument", "{translate: \"filled_map.monument\"}").substring(1)
        + ", {Slot: 1b, " + map("red_x", "{translate: \"filled_map.buried_treasure\"}").substring(1)
        + ", {Slot: 2b, " + map("minecraft:village_taiga", "{translate: \"filled_map.village_taiga\", color: \"gold\"}").substring(1)
        + ", {Slot: 3b, " + map("minecraft:mansion", "{translate: \"filled_map.monument\"}").substring(1)
        + ", {Slot: 4b, " + map("minecraft:player", null).substring(1)
        + ", {Slot: 5b, id: \"minecraft:map\", count: 2, components: {\"minecraft:item_name\": {translate: \"filled_map.buried_treasure\"}}}"
        + ", {Slot: 6b, id: \"minecraft:map\", count: 1, components: {\"minecraft:item_name\": \"Treasure\"}}"
        + ", {Slot: 7b, id: \"minecraft:decorated_pot\", count: 1, components: {\"minecraft:pot_decorations\":"
        + " [\"minecraft:arms_up_pottery_sherd\", \"minecraft:brick\"], \"minecraft:container\": [{slot: 0, item: "
        + map("minecraft:jungle_temple", null) + "}]}}"
        + ", {Slot: 8b, id: \"minecraft:mace\", count: 1, components: {\"minecraft:swing_animation\": {type: \"whack\", duration: 9},"
        + " \"minecraft:map_color\": 4, \"!minecraft:map_color\": {}}}"
        + ", {Slot: 9b, id: \"minecraft:oak_sign\", count: 1, components: {\"minecraft:block_entity_data\": {id: \"minecraft:sign\", front_text: "
        + TEXT + "}}}"
        + ", {Slot: 10b, id: \"minecraft:paper\", count: 1, components: {\"minecraft:custom_data\": {kept: " + map("minecraft:monument", null)
        + ", BlockState: {Name: \"minecraft:stone\"}}}}"
        + ", {Slot: 11b, id: \"minecraft:decorated_pot\", count: 1, components: {\"minecraft:pot_decorations\": [\"\", \"minecraft:brick\"]}}"
        + ", {Slot: 12b, id: \"minecraft:stone\", count: 3, components: {\"minecraft:block_transformer\": {}}}"
        + ", {Slot: 13b, id: \"minecraft:decorated_pot\", count: 1, components: {\"minecraft:pot_decorations\": [\"minecraft:a\", \"minecraft:b\","
        + " \"minecraft:c\", \"minecraft:d\", \"minecraft:e\"]}}"
        + ", {Slot: 14b, id: \"minecraft:cod_bucket\", count: 1, components: {\"minecraft:bucket_entity_data\": {BlockState: {Name: \"minecraft:stone\"}}}}"
        + "]";
    var blockEntities = ", block_entities: ["
        + "{id: \"minecraft:sign\", x: 48, y: 1, z: -32, keepPacked: 0b, is_waxed: 0b, front_text: " + TEXT + ", back_text: " + TEXT + "}"
        + ", {id: \"minecraft:hanging_sign\", x: 49, y: 1, z: -32, keepPacked: 0b, is_waxed: 1b, front_text: " + TEXT + ", back_text: " + TEXT + "}"
        + ", {id: \"minecraft:decorated_pot\", x: 50, y: 1, z: -32, keepPacked: 0b, sherds: [\"minecraft:brick\", \"minecraft:angler_pottery_sherd\","
        + " \"minecraft:brick\", \"minecraft:skull_pottery_sherd\"], item: " + map("minecraft:swamp_hut", "{translate: \"filled_map.explorer_swamp\"}") + "}"
        + ", {id: \"minecraft:decorated_pot\", x: 51, y: 1, z: -32, keepPacked: 0b}"
        + ", {id: \"minecraft:piston\", x: 52, y: 1, z: -32, keepPacked: 0b, blockState: {Name: \"minecraft:piston_head\","
        + " Properties: {facing: \"up\", short: \"false\", type: \"sticky\"}}, facing: 1, progress: 0.5f, extending: 1b, source: 0b}"
        + ", {id: \"minecraft:chest\", x: 53, y: 1, z: -32, keepPacked: 0b, Items: " + items
        + ", components: {\"minecraft:map_color\": 2, \"minecraft:swing_animation\": {type: \"none\", duration: 1}}}"
        + ", {id: \"minecraft:mob_spawner\", x: 54, y: 1, z: -32, keepPacked: 0b, Delay: 20s, SpawnData: {entity: {id: \"minecraft:falling_block\","
        + " BlockState: {Name: \"minecraft:sand\"}, TileEntityData: {id: \"minecraft:hanging_sign\", front_text: " + TEXT + "}}},"
        + " SpawnPotentials: [{weight: 1, data: {entity: {id: \"minecraft:enderman\", carriedBlockState: {Name: \"minecraft:cactus\", Properties: {age: \"3\"}}}}}]}"
        + "]";
    var rest = ", Heightmaps: {WORLD_SURFACE: [L; 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L,"
        + " 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L, 0L]}, structures: {References: {}, starts: {}}, block_ticks: [], fluid_ticks: [],"
        + " PostProcessing: [[], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], [], []],"
        + " blending_data: {min_section: -4, max_section: 20, heights: [63.0d, 64.0d]}";
    var entities = "[{id: \"minecraft:falling_block\", Pos: [48.5d, 3.0d, -31.5d], Motion: [0.0d, 0.0d, 0.0d], Rotation: [0.0f, 0.0f],"
        + " UUID: [I; 1, 2, 3, 4], BlockState: {Name: \"minecraft:oak_sign\", Properties: {rotation: \"4\", waterlogged: \"false\"}},"
        + " TileEntityData: {id: \"minecraft:sign\", front_text: " + TEXT + "}, Time: 1}"
        + ", {id: \"minecraft:enderman\", Pos: [49.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 5], carriedBlockState: {Name: \"minecraft:grass_block\","
        + " Properties: {snowy: \"false\"}}, Passengers: [{id: \"minecraft:minecart\", UUID: [I; 1, 2, 3, 6], DisplayState: {Name: \"minecraft:rail\","
        + " Properties: {shape: \"north_south\", waterlogged: \"false\"}}, DisplayOffset: 6}]}"
        + ", {id: \"minecraft:arrow\", Pos: [50.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 7], inBlockState: {Name: \"minecraft:target\", Properties: {power: \"0\"}},"
        + " item: {id: \"minecraft:arrow\", count: 1}}"
        + ", {id: \"minecraft:block_display\", Pos: [51.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 8], block_state: {Name: \"minecraft:lantern\","
        + " Properties: {hanging: \"true\", waterlogged: \"false\"}}}"
        + ", {id: \"minecraft:tnt\", Pos: [52.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 9], block_state: {Name: \"minecraft:tnt\", Properties: {unstable: \"false\"}}, fuse: 80s}"
        + ", {id: \"minecraft:item\", Pos: [53.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 10], Item: " + map("minecraft:trial_chambers", "{translate: \"filled_map.trial_chambers\"}") + "}"
        + ", {id: \"minecraft:glow_item_frame\", Pos: [54.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 11], Item: " + map("minecraft:village_snowy", null) + "}"
        + ", {id: \"minecraft:villager\", Pos: [55.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 12], Offers: {Recipes: [{buy: {id: \"minecraft:emerald\", count: 13},"
        + " sell: " + map("minecraft:swamp_hut", "{translate: \"filled_map.explorer_swamp\"}") + ", maxUses: 12}]}}"
        + ", {id: \"minecraft:area_effect_cloud\", Pos: [56.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 13], custom_particle: {type: \"minecraft:block\","
        + " block_state: {Name: \"minecraft:redstone_ore\", Properties: {lit: \"true\"}}}}"
        + ", {id: \"minecraft:marker\", Pos: [57.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 14], data: {BlockState: {Name: \"minecraft:stone\"},"
        + " item: " + map("minecraft:monument", null) + "}}"
        + ", {id: \"minecraft:chest_minecart\", Pos: [58.5d, 1.0d, -31.5d], UUID: [I; 1, 2, 3, 15], DisplayState: {Name: \"minecraft:chest\","
        + " Properties: {facing: \"west\", type: \"single\", waterlogged: \"false\"}}, Items: [{Slot: 0b, " + map("minecraft:village_desert", "{translate: \"filled_map.village_desert\"}").substring(1) + "]}"
        + "]";
    var retrogen = ", below_zero_retrogen: {target_status: \"%s\", missing_bedrock: [L; 0L, 0L, 0L, 0L]}";
    var snapshot = "{DataVersion: 5000, xPos: 1, zPos: 1, yPos: -4, Status: \"minecraft:full\", blending_data: {min_section: -4, max_section: 20,"
        + " heights: [1.7976931348623157E308d, 63.0d, -12.25d, 0.1d, 7, 2.5f]}" + SECTIONS + "}";
    return List.of(
        new String[] {"full chunk", "chunk", chunk("minecraft:full", SECTIONS + blockEntities + rest)},
        new String[] {"noise chunk", "chunk", chunk("minecraft:noise", SECTIONS + rest)},
        new String[] {"surface chunk retrogen to full", "chunk", chunk("minecraft:surface", SECTIONS + rest + String.format(retrogen, "minecraft:full"))},
        new String[] {"carvers chunk retrogen to surface", "chunk", chunk("minecraft:carvers", SECTIONS + rest + String.format(retrogen, "surface"))},
        new String[] {"structure starts chunk retrogen to features", "chunk", chunk("minecraft:structure_starts", SECTIONS + String.format(retrogen, "minecraft:features"))},
        new String[] {"biomes chunk", "chunk", chunk("biomes", SECTIONS + rest)},
        new String[] {"chunk without status", "chunk", "{DataVersion: " + OLD + ", xPos: 0, zPos: 0, yPos: -4" + SECTIONS + rest + "}"},
        new String[] {"26.3 snapshot chunk", "chunk", snapshot},
        new String[] {"entities", "entities", "{DataVersion: " + OLD + ", Position: [I; 3, -2], Entities: " + entities + "}"});
  }
}
