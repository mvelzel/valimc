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
 * `export OUT EXPORTED DIR` compares ValiMC's export of the imported world with
 * the original as vanilla loads both (section blocks and biomes, block entities
 * through `loadStatic` and `saveWithFullMetadata`, preserved entities unchanged,
 * items' UUID, position, motion, age, delay and stack, orbs' UUID, position,
 * motion, age, value and count). Then the pinned server
 * runs on copies of the export and of the original reduced to what an import
 * keeps (full chunks, no POI) alike (ticking frozen, every
 * exported chunk force-loaded, saved, any logged error refused) and both saves
 * must hold the same chunks and entities.
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
      case "client" -> client(Path.of(args[1]).toAbsolutePath());
      case "export" -> export(Path.of(args[1]), Path.of(args[2]).toAbsolutePath(), Path.of(args[3]).toAbsolutePath());
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
      "decorated_pot{sherds:{back:{id:\"minecraft:angler_pottery_sherd\"},left:{id:\"minecraft:archer_pottery_sherd\"}}}",
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

  // ---- client world ----

  /**
   * The VMC-021e client test world: full chunks for x −160..319 and z −160..287
   * (spawn, a pillager outpost around x 150, z 40 and the savanna village around
   * x 265, z 228) plus the fixture platform at y 100 over x 128..191, z −64..−1.
   * Not a stage; a dataset for the client run.
   */
  static void client(Path dir) throws Exception {
    var commands = new ArrayList<String>();
    // At most 256 chunks per forceload command.
    for (var x : new int[][]{{-160, 15}, {16, 191}, {192, 319}})
      for (var z : new int[][]{{-160, 63}, {64, 287}})
        commands.add("forceload add " + x[0] + " " + z[0] + " " + x[1] + " " + z[1]);
    commands.add("#sleep 90000");
    commands.addAll(fixtures(128, -64));
    WorldNbtOracle.runServer(dir, Map.of(), commands);
    System.out.println("PASS: client world in " + dir.resolve("universe/w"));
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
          if (type.equals("minecraft:experience_orb")) {
            row.addProperty("value", entity.getShortOr("Value", (short) 0));
            row.addProperty("count", entity.getIntOr("Count", 1));
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
    int checked = 0, lit = 0;
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
      // Computed light (VMC-022c): every section of both kinds is sent, as data or
      // as an empty (all-zero) section; the light stage checks the values against
      // vanilla's engine.
      var light = packet.lightData();
      for (var kind : List.of("SkyLight", "BlockLight")) {
        var mask = kind.equals("SkyLight") ? light.skyYMask() : light.blockYMask();
        var emptyMask = kind.equals("SkyLight") ? light.emptySkyYMask() : light.emptyBlockYMask();
        var updates = kind.equals("SkyLight") ? light.skyUpdates() : light.blockUpdates();
        var all = (BitSet) mask.clone();
        all.or(emptyMask);
        if (mask.intersects(emptyMask) || all.cardinality() != 26 || all.nextClearBit(0) != 26 || updates.size() != mask.cardinality()
            || updates.stream().anyMatch(data -> data.length != 2048))
          throw new AssertionError("chunk " + entry.getKey() + " " + kind + " does not cover every light section");
      }
      if (!light.skyYMask().isEmpty()) lit++;
    }
    if (lit == 0) throw new AssertionError("no lit chunk checked");
    // Block entity update packets (corrections after refused changes).
    int updates = 0;
    for (var element : facts.getAsJsonArray("block_entities")) {
      var row = element.getAsJsonObject();
      var p = row.getAsJsonArray("pos");
      var file = dir.resolve("update." + p.get(0) + "." + p.get(1) + "." + p.get(2) + ".bin");
      if (!Files.exists(file)) continue;
      var buffer = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(Files.readAllBytes(file)), access);
      var packet = net.minecraft.network.protocol.game.ClientboundBlockEntityDataPacket.STREAM_CODEC.decode(buffer);
      if (buffer.readableBytes() != 0 || !packet.getPos().equals(new BlockPos(p.get(0).getAsInt(), p.get(1).getAsInt(), p.get(2).getAsInt()))
          || !BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(packet.getType()).toString().equals(row.get("type").getAsString())
          || !digest(packet.getTag()).equals(row.get("update").getAsString()))
        throw new AssertionError("update packet for " + p + " differs from vanilla's getUpdateTag");
      updates++;
    }
    if (updates < 10) throw new AssertionError("too few update packets: " + updates);
    System.out.println("PASS: vanilla decodes ValiMC's chunk packets for " + expected.size() + " chunks with exactly vanilla's "
        + checked + " block entities, types and update tags, light in every section of " + expected.size() + " chunks (" + lit + " with sky data), and "
        + updates + " block entity update packets");
  }

  // ---- export ----

  /** Per full chunk: section digests and canonical block entity digests by position. */
  static Map<ChunkPos, List<String>> chunkFacts(Path regionDir) throws Exception {
    var result = new TreeMap<ChunkPos, List<String>>(Comparator.comparingLong(ChunkPos::pack));
    var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
    for (var file : files(regionDir))
      for (var chunk : chunks(info, file)) {
        var tag = chunk.getValue();
        if (SerializableChunkData.getChunkStatusFromTag(tag) != ChunkStatus.FULL) continue;
        var data = SerializableChunkData.parse(ChunkOracle.HEIGHT, factory, tag);
        var sections = new HashMap<Integer, LevelChunkSection>();
        for (var section : data.sectionData()) if (section.chunkSection() != null) sections.put(section.y(), section.chunkSection());
        var facts = new ArrayList<String>();
        for (int y = -4; y < 20; y++) facts.add(ChunkOracle.digest(sections.getOrDefault(y, new LevelChunkSection(factory))));
        var entities = new TreeMap<String, String>();
        for (var stored : data.blockEntities()) {
          var at = BlockEntity.getPosFromTag(chunk.getKey(), stored);
          var section = sections.get(at.getY() >> 4);
          var state = section == null ? Block.stateById(0) : section.getBlockState(at.getX() & 15, at.getY() & 15, at.getZ() & 15);
          var entity = state.hasBlockEntity() ? BlockEntity.loadStatic(at, state, stored, access) : null;
          if (entity != null) entities.put(at.toShortString(), digest(entity.saveWithFullMetadata(access)));
        }
        facts.add(entities.toString());
        result.put(chunk.getKey(), facts);
      }
    return result;
  }

  /** Every stored entity by UUID: the stored digest, or for items the modelled fields. */
  static Map<String, String> entityFacts(Path entityDir) throws Exception { return entityFacts(entityDir, null); }

  /** As above, for the entities stored in `only` chunks (all when null). */
  static Map<String, String> entityFacts(Path entityDir, Set<ChunkPos> only) throws Exception {
    var result = new TreeMap<String, String>();
    if (!Files.isDirectory(entityDir)) return result;
    var ops = access.createSerializationContext(NbtOps.INSTANCE);
    for (var file : files(entityDir))
      for (var chunk : chunks(new RegionStorageInfo("oracle", Level.OVERWORLD, "entities"), file)) {
        if (only != null && !only.contains(chunk.getKey())) continue;
        var list = chunk.getValue().getListOrEmpty("Entities");
        for (int k = 0; k < list.size(); k++) {
          var entity = list.getCompoundOrEmpty(k);
          var uuid = HEX.formatHex(java.nio.ByteBuffer.allocate(16).putInt(entity.getIntArray("UUID").orElseThrow()[0])
              .putInt(entity.getIntArray("UUID").orElseThrow()[1]).putInt(entity.getIntArray("UUID").orElseThrow()[2])
              .putInt(entity.getIntArray("UUID").orElseThrow()[3]).array());
          String fact;
          if (entity.getStringOr("id", "").equals("minecraft:item") && !entity.contains("Owner")) {
            var stack = ItemStack.CODEC.parse(ops, entity.get("Item")).getOrThrow();
            fact = "item " + entity.get("Pos") + " " + entity.get("Motion") + " " + entity.getShortOr("Age", (short) 0) + " "
                + entity.getShortOr("PickupDelay", (short) 0) + " " + entity.getBooleanOr("OnGround", false) + " "
                + entity.getBooleanOr("NoGravity", false) + " " + itemHex(stack);
          } else if (entity.getStringOr("id", "").equals("minecraft:experience_orb"))
            fact = "orb " + entity.get("Pos") + " " + entity.get("Motion") + " " + entity.getShortOr("Age", (short) 0) + " "
                + entity.getShortOr("Value", (short) 0) + " " + entity.getIntOr("Count", 1) + " "
                + entity.getBooleanOr("OnGround", false) + " " + entity.getBooleanOr("NoGravity", false);
          else fact = digest(entity);
          if (result.put(uuid, fact) != null) throw new AssertionError("repeated UUID " + uuid);
        }
      }
    return result;
  }

  static void compare(String what, Map<ChunkPos, List<String>> original, Map<ChunkPos, List<String>> exported) {
    for (var entry : original.entrySet()) {
      var other = exported.get(entry.getKey());
      if (other == null) throw new AssertionError(what + ": chunk " + entry.getKey() + " missing");
      for (int i = 0; i < 24; i++)
        if (!entry.getValue().get(i).equals(other.get(i)))
          throw new AssertionError(what + ": chunk " + entry.getKey() + " section " + (i - 4) + " differs");
      if (!entry.getValue().get(24).equals(other.get(24)))
        throw new AssertionError(what + ": chunk " + entry.getKey() + " block entities differ:\n vanilla " + entry.getValue().get(24) + "\n export  " + other.get(24));
    }
  }

  /**
   * Copy `world` into `dir` and run the pinned server on it; returns its overworld
   * folder. With `fullOnly`, overworld region files keep only full chunks and POI
   * files are left out, which is what an import keeps of the world.
   */
  static Path run(Path world, Path dir, List<String> commands, boolean fullOnly) throws Exception {
    var target = dir.resolve("universe/w");
    var regions = world.resolve("dimensions/minecraft/overworld/region");
    var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
    try (var walk = Files.walk(world)) {
      for (var path : walk.toList()) {
        if (path.getFileName().toString().equals("session.lock")) continue;
        var copy = target.resolve(world.relativize(path).toString());
        if (Files.isDirectory(path)) { Files.createDirectories(copy); continue; }
        if (fullOnly && path.getParent().getFileName().toString().equals("poi")) continue;
        if (fullOnly && path.getParent().equals(regions)) {
          try (var region = new RegionFile(info, copy, copy.getParent(), true)) {
            for (var chunk : chunks(info, path))
              if (SerializableChunkData.getChunkStatusFromTag(chunk.getValue()) == ChunkStatus.FULL)
                try (var out = region.getChunkDataOutputStream(chunk.getKey())) { NbtIo.write(chunk.getValue(), out); }
          }
        } else Files.copy(path, copy);
      }
    }
    WorldNbtOracle.runServer(dir, Map.of(), commands);
    return target.resolve("dimensions/minecraft/overworld");
  }

  static void export(Path factsPath, Path exported, Path dir) throws Exception {
    var facts = JsonParser.parseString(Files.readString(factsPath)).getAsJsonObject();
    var original = Path.of(facts.get("world").getAsString()).resolve("dimensions/minecraft/overworld");
    var ours = exported.resolve("dimensions/minecraft/overworld");
    var chunks = chunkFacts(original.resolve("region"));
    var entities = entityFacts(original.resolve("entities"));
    var written = chunkFacts(ours.resolve("region"));
    compare("export", chunks, written);
    if (!entityFacts(ours.resolve("entities")).equals(entities)) throw new AssertionError("exported entities differ from vanilla's");

    // Vanilla loads the export as it loads the original: copies of both (the
    // original reduced to what an import keeps: its full chunks, no POI) run on
    // the pinned server, frozen, with every exported chunk force-loaded, and save.
    // Loading applies vanilla's pending post-processing to both alike.
    var commands = new ArrayList<String>();
    commands.add("tick freeze");
    for (var chunk : written.keySet()) commands.add("forceload add " + chunk.getMinBlockX() + " " + chunk.getMinBlockZ());
    commands.add("#sleep 5000");
    var vanilla = run(original.getParent().getParent().getParent(), dir.resolve("original"), commands, true);
    var loaded = run(exported, dir.resolve("export"), commands, false);
    // Generating a missing neighbour may place features into a bordering chunk,
    // and parallel generation need not do that the same way twice; only chunks
    // whose eight neighbours were exported too are beyond its reach.
    var reloaded = chunkFacts(vanilla.resolve("region"));
    reloaded.keySet().removeIf(pos -> {
      for (int dx = -1; dx <= 1; dx++)
        for (int dz = -1; dz <= 1; dz++)
          if (!written.containsKey(new ChunkPos(pos.x() + dx, pos.z() + dz))) return true;
      return false;
    });
    if (reloaded.size() < 16) throw new AssertionError("too few interior chunks: " + reloaded.size());
    compare("vanilla's save of the export", reloaded, chunkFacts(loaded.resolve("region")));
    // Chunks vanilla generates around both spawn their own animals; only the
    // exported chunks' entities are compared.
    var mine = entityFacts(loaded.resolve("entities"), written.keySet());
    var theirs = entityFacts(vanilla.resolve("entities"), written.keySet());
    if (!mine.equals(theirs) || !mine.keySet().containsAll(entities.keySet()))
      throw new AssertionError("vanilla's saves of the export and the original hold different entities:\n " + theirs + "\n " + mine);
    System.out.println("PASS: ValiMC's export holds vanilla's blocks, biomes and " + chunks.values().stream().mapToInt(c -> c.get(24).split("=").length - 1).sum()
        + " block entities in " + chunks.size() + " full chunks and its " + entities.size() + " entities; the pinned server loads it without errors and saves what it saves for the original ("
        + reloaded.size() + " interior chunks compared)");
  }
}
