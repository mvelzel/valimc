import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Registry;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.nbt.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundLevelChunkWithLightPacket;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.world.Container;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.chunk.storage.*;

/**
 * Imported block entities and entities as vanilla loads them (VMC-021e).
 *
 * `generate DIR OUT` runs the pinned server into DIR with one block of every block
 * entity type plus richer fixtures (named, enchanted and component items in
 * chests and furnaces, a loot-table chest, signs, banners, beds, a campfire,
 * spawner, pot...) and dropped items, XP orbs and other entities. For every block
 * entity of a full chunk it records what `BlockEntity.loadStatic` makes of the
 * stored compound: its type, the digest of `getUpdateTag` (what chunk packets
 * carry) and, for containers, each slot's untrusted network encoding. For every
 * stored entity it records the type, UUID and stored compound digest, and for
 * items the stack's encoding.
 *
 * `verify OUT DIR` decodes ValiMC's chunk packets (`chunk.X.Z.bin`, packet bodies)
 * with vanilla's codec and requires exactly vanilla's block entity list per chunk:
 * positions, types and update tags.
 */
public class AnvilContentOracle {
  static final HexFormat HEX = HexFormat.of();
  static RegistryAccess.Frozen access;
  static PalettedContainerFactory factory;

  public static void main(String[] args) throws Exception {
    var base = MiningToolOracle.initialize();
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
        List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var loaded = RegistryDataLoader.load(resources, base.listRegistries().toList(),
          RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      var all = new ArrayList<Registry<?>>(BuiltInRegistries.REGISTRY.stream().toList());
      loaded.registries().forEach(entry -> all.add(entry.value()));
      access = new RegistryAccess.ImmutableRegistryAccess(all).freeze();
      factory = PalettedContainerFactory.create(loaded);
    }
    switch (args[0]) {
      case "generate" -> generate(Path.of(args[1]).toAbsolutePath(), Path.of(args[2]), fixtures(0, 0));
      case "verify" -> verify(Path.of(args[1]), Path.of(args[2]));
      default -> throw new IllegalArgumentException(args[0]);
    }
  }

  // ---- fixtures ----

  /** Console commands placing the fixtures with their platform's corner at (x0, z0). */
  static List<String> fixtures(int x0, int z0) {
    var c = new ArrayList<String>();
    c.add("forceload add " + x0 + " " + z0 + " " + (x0 + 63) + " " + (z0 + 63));
    c.add("fill " + x0 + " 99 " + z0 + " " + (x0 + 63) + " 99 " + (z0 + 31) + " minecraft:stone");
    c.add("fill " + x0 + " 99 " + (z0 + 32) + " " + (x0 + 63) + " 99 " + (z0 + 63) + " minecraft:stone");
    // One block of every block entity type (the first block creating it), spaced out.
    var seen = new LinkedHashSet<String>();
    int i = 0;
    for (var block : BuiltInRegistries.BLOCK) {
      var state = block.defaultBlockState();
      if (!state.hasBlockEntity()) continue;
      String type = null;
      for (var t : BuiltInRegistries.BLOCK_ENTITY_TYPE) if (t.isValid(state)) type = BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(t).toString();
      if (type == null || type.equals("minecraft:piston") || !seen.add(type)) continue;
      c.add(String.format("setblock %d 100 %d %s", x0 + 2 + 3 * (i % 16), z0 + 2 + 3 * (i / 16), BuiltInRegistries.BLOCK.getKey(block)));
      i++;
    }
    int x = x0 + 2, z = z0 + 20;
    String[] rich = {
      // Owned containers: plain chest contents of supported components; a furnace mid-smelt.
      "chest{Items:[{Slot:0b,id:\"minecraft:diamond_sword\",count:1,components:{\"minecraft:enchantments\":{\"minecraft:sharpness\":5,\"minecraft:unbreaking\":3},\"minecraft:damage\":17,\"minecraft:custom_name\":{text:\"Edge\",color:\"red\",italic:0b}}},{Slot:4b,id:\"minecraft:stone\",count:64},{Slot:9b,id:\"minecraft:potion\",count:1,components:{\"minecraft:potion_contents\":{potion:\"minecraft:strong_swiftness\"}}},{Slot:13b,id:\"minecraft:apple\",count:7,components:{\"minecraft:lore\":[\"first\",{text:\"second\",bold:1b}],\"minecraft:rarity\":\"rare\"}},{Slot:26b,id:\"minecraft:enchanted_book\",count:1,components:{\"minecraft:stored_enchantments\":{\"minecraft:mending\":1}}}]}",
      "furnace[lit=true]{Items:[{Slot:0b,id:\"minecraft:raw_iron\",count:5},{Slot:1b,id:\"minecraft:coal\",count:3},{Slot:2b,id:\"minecraft:iron_ingot\",count:2}],cooking_time_spent:50,cooking_total_time:200,lit_time_remaining:1000,lit_total_time:1600,RecipesUsed:{\"minecraft:iron_ingot_from_smelting_raw_iron\":2}}",
      "smoker{Items:[{Slot:0b,id:\"minecraft:beef\",count:3}]}",
      "blast_furnace",
      "chest",
      // Locked containers: a component ValiMC cannot hold, a custom name, a loot table.
      "chest{Items:[{Slot:1b,id:\"minecraft:writable_book\",count:1,components:{\"minecraft:writable_book_content\":{pages:[\"hello\"]}}}]}",
      "chest{CustomName:\"Named chest\",Items:[{Slot:0b,id:\"minecraft:dirt\",count:3}]}",
      "chest{LootTable:\"minecraft:chests/village/village_plains_house\",LootTableSeed:42L}",
      "furnace{CustomName:\"Named furnace\"}",
      // Preserved kinds with data.
      "oak_sign{front_text:{messages:[\"Hello\",{text:\"world\",color:\"blue\"},\"\",\"\"],color:\"red\",has_glowing_text:1b},is_waxed:1b}",
      "white_banner{patterns:[{pattern:\"minecraft:stripe_top\",color:\"red\"},{pattern:\"minecraft:cross\",color:\"blue\"}],components:{\"minecraft:custom_name\":\"Flag\"}}",
      "campfire{Items:[{Slot:0b,id:\"minecraft:beef\",count:1}],CookingTimes:[I;10,0,0,0],CookingTotalTimes:[I;600,0,0,0]}",
      "decorated_pot{sherds:[\"minecraft:brick\",\"minecraft:angler_pottery_sherd\",\"minecraft:brick\",\"minecraft:archer_pottery_sherd\"]}",
      "spawner{SpawnData:{entity:{id:\"minecraft:zombie\"}},Delay:20s}",
      "skeleton_skull{custom_name:\"Yorick\"}",
      "lectern[has_book=true]{Book:{id:\"minecraft:writable_book\",count:1}}",
      "barrel{Items:[{Slot:3b,id:\"minecraft:gold_ingot\",count:9}]}",
      "white_shulker_box{Items:[{Slot:0b,id:\"minecraft:emerald\",count:2}]}",
      "suspicious_sand{item:{id:\"minecraft:emerald\",count:1},LootTable:\"minecraft:archaeology/desert_pyramid\"}",
      "oak_shelf{Items:[{Slot:1b,id:\"minecraft:book\",count:1}],align_items_to_bottom:1b}",
      "beehive{bees:[]}",
      "enchanting_table{CustomName:\"Desk\"}",
      "vault",
      "trial_spawner",
    };
    for (var block : rich) { c.add(String.format("setblock %d 100 %d minecraft:%s", x, z, block)); x += 3; if (x > x0 + 60) { x = x0 + 2; z += 3; } }
    // A bed (both halves) and a double chest.
    c.add(String.format("setblock %d 100 %d minecraft:red_bed[part=foot,facing=south]", x0 + 2, z0 + 40));
    c.add(String.format("setblock %d 100 %d minecraft:red_bed[part=head,facing=south]", x0 + 2, z0 + 41));
    c.add(String.format("setblock %d 100 %d minecraft:chest[type=right,facing=south]{Items:[{Slot:0b,id:\"minecraft:arrow\",count:16}]}", x0 + 5, z0 + 40));
    c.add(String.format("setblock %d 100 %d minecraft:chest[type=left,facing=south]", x0 + 6, z0 + 40));
    // Entities: dropped items (supported and not), XP orbs, others.
    String[] items = {
      "{id:\"minecraft:stone\",count:3}",
      "{id:\"minecraft:diamond_pickaxe\",count:1,components:{\"minecraft:enchantments\":{\"minecraft:efficiency\":4},\"minecraft:damage\":40}}",
      "{id:\"minecraft:bread\",count:12,components:{\"minecraft:custom_name\":\"Loaf\"}}",
      "{id:\"minecraft:written_book\",count:1,components:{\"minecraft:written_book_content\":{title:\"T\",author:\"A\",pages:[\"p\"]}}}",
    };
    for (int k = 0; k < items.length; k++)
      c.add(String.format("summon minecraft:item %d.5 101 %d.5 {Item:%s,Age:-32768s,PickupDelay:%ds,NoGravity:1b}", x0 + 2 + 3 * k, z0 + 50, items[k], k == 0 ? 32767 : 10));
    c.add(String.format("summon minecraft:item %d.5 101.25 %d.5 {Item:{id:\"minecraft:dirt\",count:5},Age:100s,Motion:[0.0d,0.0d,0.0d]}", x0 + 20, z0 + 50));
    int[] values = {7, 3, 1, 17};
    for (int k = 0; k < values.length; k++)
      c.add(String.format("summon minecraft:experience_orb %d.5 101 %d.5 {Value:%ds,Count:%d,NoGravity:1b}", x0 + 2 + 3 * k, z0 + 55, values[k], k + 1));
    c.add(String.format("summon minecraft:armor_stand %d.5 100 %d.5 {CustomName:\"Stand\",NoGravity:1b}", x0 + 30, z0 + 55));
    c.add(String.format("summon minecraft:villager %d.5 100 %d.5 {NoAI:1b}", x0 + 33, z0 + 55));
    c.add("#sleep 8000");
    return c;
  }

  // ---- generate ----

  static String digest(Tag tag) throws Exception { return WorldNbtOracle.digest(tag); }

  static String itemHex(ItemStack stack) {
    var buffer = new RegistryFriendlyByteBuf(Unpooled.buffer(), access);
    ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC.encode(buffer, stack);
    var bytes = new byte[buffer.readableBytes()];
    buffer.getBytes(0, bytes);
    return HEX.formatHex(bytes);
  }

  static void generate(Path dir, Path out, List<String> commands) throws Exception {
    WorldNbtOracle.runServer(dir, Map.of(), commands);
    var world = dir.resolve("universe/w");
    var dim = world.resolve("dimensions/minecraft/overworld");
    var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
    var blockEntities = new JsonArray();
    var types = new TreeMap<String, Integer>();
    int dropped = 0;
    for (var file : files(dim.resolve("region"))) {
      for (var chunk : chunks(info, file)) {
        var tag = chunk.getValue();
        if (SerializableChunkData.getChunkStatusFromTag(tag) != ChunkStatus.FULL) continue;
        var pos = chunk.getKey();
        var data = SerializableChunkData.parse(ChunkOracle.HEIGHT, factory, tag);
        var sections = new HashMap<Integer, LevelChunkSection>();
        for (var section : data.sectionData()) if (section.chunkSection() != null) sections.put(section.y(), section.chunkSection());
        for (var stored : data.blockEntities()) {
          var at = BlockEntity.getPosFromTag(pos, stored);
          var section = sections.get(at.getY() >> 4);
          var state = section == null ? Block.stateById(0) : section.getBlockState(at.getX() & 15, at.getY() & 15, at.getZ() & 15);
          BlockEntity entity = state.hasBlockEntity() ? BlockEntity.loadStatic(at, state, stored, access) : null;
          if (entity == null) { dropped++; continue; }
          var type = BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(entity.getType()).toString();
          types.merge(type, 1, Integer::sum);
          var row = new JsonObject();
          row.addProperty("chunk_x", pos.x());
          row.addProperty("chunk_z", pos.z());
          row.add("pos", new Gson().toJsonTree(new int[]{at.getX(), at.getY(), at.getZ()}));
          row.addProperty("type", type);
          row.addProperty("state", Block.getId(state));
          row.addProperty("stored", digest(stored));
          row.addProperty("update", digest(entity.getUpdateTag(access)));
          if (entity instanceof Container container) {
            var slots = new JsonArray();
            for (int s = 0; s < container.getContainerSize(); s++) {
              var stack = container.getItem(s);
              if (stack.isEmpty()) continue;
              var slot = new JsonArray(); slot.add(s); slot.add(itemHex(stack)); slots.add(slot);
            }
            row.add("items", slots);
          }
          blockEntities.add(row);
        }
      }
    }
    var entities = new JsonArray();
    var entityTypes = new TreeMap<String, Integer>();
    var ops = access.createSerializationContext(NbtOps.INSTANCE);
    for (var file : files(dim.resolve("entities"))) {
      for (var chunk : chunks(new RegionStorageInfo("oracle", Level.OVERWORLD, "entities"), file)) {
        var list = chunk.getValue().getListOrEmpty("Entities");
        for (int k = 0; k < list.size(); k++) {
          var entity = list.getCompoundOrEmpty(k);
          var type = entity.getStringOr("id", "");
          entityTypes.merge(type, 1, Integer::sum);
          var row = new JsonObject();
          row.addProperty("chunk_x", chunk.getKey().x());
          row.addProperty("chunk_z", chunk.getKey().z());
          row.addProperty("type", type);
          row.addProperty("stored", digest(entity));
          var uuid = java.nio.ByteBuffer.allocate(16);
          for (int part : entity.getIntArray("UUID").orElseThrow()) uuid.putInt(part);
          row.addProperty("uuid", HEX.formatHex(uuid.array()));
          var pos = entity.getListOrEmpty("Pos");
          row.add("pos", new Gson().toJsonTree(new double[]{pos.getDoubleOr(0, 0), pos.getDoubleOr(1, 0), pos.getDoubleOr(2, 0)}));
          if (type.equals("minecraft:item")) {
            var stack = ItemStack.CODEC.parse(ops, entity.get("Item")).getOrThrow();
            row.addProperty("item", itemHex(stack));
          }
          entities.add(row);
        }
      }
    }
    if (types.size() < 40 || !entityTypes.containsKey("minecraft:item") || !entityTypes.containsKey("minecraft:experience_orb"))
      throw new IllegalStateException("fixtures missing: " + types + " " + entityTypes);
    var facts = new JsonObject();
    facts.addProperty("world", world.toString());
    facts.addProperty("dropped", dropped);
    facts.add("block_entities", blockEntities);
    facts.add("entities", entities);
    Files.writeString(out, new Gson().toJson(facts));
    System.out.println("PASS: vanilla loaded " + blockEntities.size() + " block entities of " + types.size() + " types and "
        + entities.size() + " entities " + entityTypes);
  }

  static List<Path> files(Path dir) throws Exception {
    try (var list = Files.list(dir)) { return list.filter(p -> p.toString().endsWith(".mca")).sorted().toList(); }
  }

  static List<Map.Entry<ChunkPos, CompoundTag>> chunks(RegionStorageInfo info, Path file) throws Exception {
    var result = new ArrayList<Map.Entry<ChunkPos, CompoundTag>>();
    var copy = Files.createTempDirectory("valimc-anvil");
    Files.copy(file, copy.resolve(file.getFileName()));
    var name = file.getFileName().toString().split("\\.");
    int rx = Integer.parseInt(name[1]), rz = Integer.parseInt(name[2]);
    try (var region = new RegionFile(info, copy.resolve(file.getFileName()), copy, false)) {
      for (int index = 0; index < 1024; index++) {
        var pos = new ChunkPos(rx * 32 + (index & 31), rz * 32 + (index >> 5));
        try (var stream = region.getChunkDataInputStream(pos)) {
          if (stream != null) result.add(Map.entry(pos, NbtIo.read(stream)));
        }
      }
    }
    return result;
  }

  // ---- verify ----

  static void verify(Path factsPath, Path dir) throws Exception {
    var facts = JsonParser.parseString(Files.readString(factsPath)).getAsJsonObject();
    var expected = new TreeMap<String, TreeMap<String, String>>();
    for (var element : facts.getAsJsonArray("block_entities")) {
      var row = element.getAsJsonObject();
      var p = row.getAsJsonArray("pos");
      expected.computeIfAbsent(row.get("chunk_x") + "." + row.get("chunk_z"), k -> new TreeMap<>())
          .put(p.get(0) + "," + p.get(1) + "," + p.get(2), row.get("type").getAsString() + " " + row.get("update").getAsString());
    }
    var empty = digest(new CompoundTag());
    int checked = 0;
    for (var entry : expected.entrySet()) {
      var file = dir.resolve("chunk." + entry.getKey() + ".bin");
      var buffer = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(Files.readAllBytes(file)), access);
      var packet = ClientboundLevelChunkWithLightPacket.STREAM_CODEC.decode(buffer);
      if (buffer.readableBytes() != 0) throw new AssertionError("trailing bytes in " + file);
      var actual = new TreeMap<String, String>();
      var failure = new Exception[1];
      packet.chunkData().forEachBlockEntityTag(packet.x(), packet.z(), (pos, type, tag) -> {
        try {
          actual.put(pos.getX() + "," + pos.getY() + "," + pos.getZ(),
              BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(type) + " " + (tag == null ? empty : digest(tag)));
        } catch (Exception e) { failure[0] = e; }
      });
      if (failure[0] != null) throw failure[0];
      if (!actual.equals(entry.getValue()))
        throw new AssertionError("chunk " + entry.getKey() + " block entities differ:\n vanilla " + entry.getValue() + "\n valimc  " + actual);
      checked += actual.size();
    }
    System.out.println("PASS: vanilla decodes ValiMC's chunk packets for " + expected.size() + " chunks with exactly vanilla's "
        + checked + " block entities, types and update tags");
  }
}
