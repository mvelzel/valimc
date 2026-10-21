import com.google.gson.*;
import com.mojang.serialization.Dynamic;
import com.mojang.serialization.JsonOps;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtIo;
import net.minecraft.nbt.NbtOps;
import net.minecraft.nbt.NbtUtils;
import net.minecraft.world.level.levelgen.WorldGenSettings;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPreset;

/**
 * World generation settings (VMC-028a). Registries as a server loads them from the vanilla data
 * pack (static tags first, then applied).
 *
 * <p>`facts OUT`: the `worldgen/world_preset` registry, each preset as `WorldPreset.DIRECT_CODEC`
 * writes it to JSON (its dimensions).
 *
 * <p>`cases OUT`: for each case (`level-type`, `generator-settings`, seed, `generate-structures`),
 * the `WorldGenSettings` a dedicated server creates (`DedicatedServerProperties.WorldDimensionData`
 * over `WorldOptions(seed, structures, false)`, as `server.properties` gives them), written by its
 * codec to JSON and, as `world_gen_settings.dat` stores it (`data` plus the current
 * `DataVersion`), to unnamed binary NBT in base64. A generator setting a server rejects is
 * reported with the error.
 */
public class WorldSettingsOracle {
  public static void main(String[] args) throws Exception {
    var base = MiningToolOracle.initialize();
    net.minecraft.core.RegistryAccess registries;
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(
        net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var layered = net.minecraft.server.RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,
          layered.getLayer(net.minecraft.server.RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(
          layered.getAccessForLoading(net.minecraft.server.RegistryLayer.WORLD), pending);
      registries = net.minecraft.resources.RegistryDataLoader.load(resources, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(net.minecraft.core.Registry.PendingTags::apply);
    }
    if (base == null) throw new IllegalStateException("bootstrap");
    var json = registries.createSerializationContext(JsonOps.INSTANCE);
    var nbt = registries.createSerializationContext(NbtOps.INSTANCE);
    var gson = new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create();

    if (args[0].equals("facts")) {
      var presets = new TreeMap<String, JsonElement>();
      registries.lookupOrThrow(Registries.WORLD_PRESET).listElements().forEach(holder ->
          presets.put(holder.key().identifier().toString(),
              WorldPreset.DIRECT_CODEC.encodeStart(json, holder.value()).getOrThrow()));
      var out = new JsonObject();
      out.addProperty("version", net.minecraft.SharedConstants.getCurrentVersion().name());
      out.addProperty("data_version", net.minecraft.SharedConstants.getCurrentVersion().dataVersion().version());
      out.addProperty("server_sha1", VersionMetadata.serverSha1());
      out.add("presets", gson.toJsonTree(presets));
      Files.writeString(Path.of(args[1]), gson.toJson(out) + "\n");
      System.out.println("PASS: " + presets.size() + " world presets");
      return;
    }

    if (args[0].equals("verify")) {
      verify(Path.of(args[1]), Path.of(args[2]));
      return;
    }

    var flat = "{\"layers\":[{\"block\":\"minecraft:bedrock\",\"height\":1},{\"block\":\"minecraft:stone\",\"height\":123},"
        + "{\"block\":\"minecraft:dirt\",\"height\":3},{\"block\":\"minecraft:grass_block\",\"height\":1}],"
        + "\"biome\":\"minecraft:plains\"}";
    var desert = "{\"layers\":[{\"block\":\"minecraft:bedrock\",\"height\":1},{\"block\":\"minecraft:sandstone\",\"height\":60},"
        + "{\"block\":\"minecraft:sand\",\"height\":4}],\"biome\":\"minecraft:desert\",\"features\":true,\"lakes\":true,"
        + "\"structure_overrides\":\"#minecraft:village\"}";
    String[][] specs = {
        {"minecraft:normal", "", "20261020", "true"},
        {"minecraft:normal", "", "-8172645723", "false"},
        {"minecraft:large_biomes", "", "20261020", "true"},
        {"minecraft:amplified", "", "12345", "true"},
        {"minecraft:single_biome_surface", "", "20261020", "true"},
        {"minecraft:flat", "", "20261020", "true"},
        {"minecraft:flat", flat, "7", "false"},
        {"minecraft:flat", desert, "-1", "true"},
        {"minecraft:flat_all_dimensions", "", "99", "true"},
        {"minecraft:debug_all_block_states", "", "1", "true"},
        // A level type that is not a preset falls back to the normal one, as a server does.
        {"minecraft:no_such_preset", "", "3", "true"},
        // Generator settings that are not flat settings keep the flat preset's own.
        {"minecraft:flat", "{\"layers\":5}", "4", "true"},
    };
    var cases = new JsonArray();
    for (var spec : specs) {
      var row = new JsonObject();
      row.addProperty("level_type", spec[0]);
      row.addProperty("generator_settings", spec[1]);
      row.addProperty("seed", spec[2]);
      row.addProperty("generate_structures", Boolean.parseBoolean(spec[3]));
      var settingsJson = spec[1].isEmpty() ? new JsonObject() : JsonParser.parseString(spec[1]).getAsJsonObject();
      // `DedicatedServerProperties.WorldDimensionData` is private: construct it reflectively.
      var type = Class.forName("net.minecraft.server.dedicated.DedicatedServerProperties$WorldDimensionData");
      var constructor = type.getDeclaredConstructor(JsonObject.class, String.class);
      constructor.setAccessible(true);
      var create = type.getDeclaredMethod("create", net.minecraft.core.HolderLookup.Provider.class);
      create.setAccessible(true);
      var dimensions = (net.minecraft.world.level.levelgen.WorldDimensions)
          create.invoke(constructor.newInstance(settingsJson, spec[0]), registries);
      var options = new WorldOptions(Long.parseLong(spec[2]), Boolean.parseBoolean(spec[3]), false);
      var settings = new WorldGenSettings(options, dimensions);
      row.add("json", WorldGenSettings.CODEC.encodeStart(json, settings).getOrThrow());
      var tag = new CompoundTag();
      tag.put("data", WorldGenSettings.CODEC.encodeStart(nbt, settings).getOrThrow());
      NbtUtils.addCurrentDataVersion(tag);
      var bytes = new ByteArrayOutputStream();
      NbtIo.writeUnnamedTag(tag, new DataOutputStream(bytes));
      row.addProperty("nbt", Base64.getEncoder().encodeToString(bytes.toByteArray()));
      // Vanilla reads its own file back to the same settings.
      var read = WorldGenSettings.CODEC.parse(new Dynamic<>(nbt, tag.get("data"))).getOrThrow();
      if (!WorldGenSettings.CODEC.encodeStart(json, read).getOrThrow().equals(row.get("json"))) {
        throw new IllegalStateException("vanilla's settings do not round trip: " + spec[0]);
      }
      cases.add(row);
    }
    var out = new JsonObject();
    out.add("cases", cases);
    Files.writeString(Path.of(args[1]), gson.toJson(out) + "\n");
    System.out.println("PASS: " + cases.size() + " world generation settings cases");
  }

  /**
   * `verify EXPORTED DIR`: each world ValiMC exported (one per directory) runs on the pinned
   * server, which saves it; vanilla must keep ValiMC's `world_gen_settings.dat` (the same `data`
   * and data version) and the spawn in its `level.dat`, without errors.
   */
  static void verify(Path exported, Path dir) throws Exception {
    int worlds = 0;
    try (var list = Files.list(exported)) {
      for (var world : list.filter(Files::isDirectory).sorted().toList()) {
        var name = world.getFileName().toString();
        var target = dir.resolve(name).resolve("universe/w");
        try (var walk = Files.walk(world)) {
          for (var path : walk.toList()) {
            var copy = target.resolve(world.relativize(path).toString());
            if (Files.isDirectory(path)) Files.createDirectories(copy);
            else Files.copy(path, copy);
          }
        }
        // A flat export's chunk (0, 0) is generated by vanilla from ValiMC's settings.
        var expected = exported.resolve(name + ".expected.json");
        var commands = Files.exists(expected) ? List.of("forceload add 0 0", "#sleep 3000") : List.<String>of();
        WorldNbtOracle.runServer(dir.resolve(name), Map.of(), commands);
        var ours = NbtIo.readCompressed(world.resolve("data/minecraft/world_gen_settings.dat"),
            net.minecraft.nbt.NbtAccounter.unlimitedHeap());
        var theirs = NbtIo.readCompressed(target.resolve("data/minecraft/world_gen_settings.dat"),
            net.minecraft.nbt.NbtAccounter.unlimitedHeap());
        if (!ours.equals(theirs))
          throw new AssertionError(name + ": vanilla saved other settings:\n " + ours + "\n " + theirs);
        var spawn = NbtIo.readCompressed(world.resolve("level.dat"), net.minecraft.nbt.NbtAccounter.unlimitedHeap())
            .getCompoundOrEmpty("Data").getCompoundOrEmpty("spawn").get("pos");
        var saved = NbtIo.readCompressed(target.resolve("level.dat"), net.minecraft.nbt.NbtAccounter.unlimitedHeap())
            .getCompoundOrEmpty("Data").getCompoundOrEmpty("spawn").get("pos");
        if (spawn == null || !spawn.equals(saved))
          throw new AssertionError(name + ": vanilla moved the spawn from " + spawn + " to " + saved);
        if (Files.exists(expected)) flatChunks(name, JsonParser.parseString(Files.readString(expected)).getAsJsonObject(), target);
        worlds++;
      }
    }
    if (worlds == 0) throw new AssertionError("no exported worlds");
    System.out.println("PASS: vanilla keeps the generation settings and spawn of " + worlds + " ValiMC exports and generates ValiMC's flat chunk from the flat one");
  }

  /**
   * A flat export: vanilla generated its spawn chunks from ValiMC's settings; every column of chunk
   * (0, 0) must hold ValiMC's states from the bottom up, and its biome ValiMC's.
   */
  static void flatChunks(String name, JsonObject expected, Path world) throws Exception {
    var info = new net.minecraft.world.level.chunk.storage.RegionStorageInfo("oracle", net.minecraft.world.level.Level.OVERWORLD, "chunk");
    var factory = ChunkOracle.factory();
    var file = world.resolve("dimensions/minecraft/overworld/region/r.0.0.mca");
    var origin = new net.minecraft.world.level.ChunkPos(0, 0);
    CompoundTag tag = null;
    for (var chunk : AnvilContentOracle.chunks(info, file)) if (chunk.getKey().equals(origin)) tag = chunk.getValue();
    if (tag == null) throw new AssertionError(name + ": vanilla did not generate chunk 0, 0");
    var data = net.minecraft.world.level.chunk.storage.SerializableChunkData.parse(ChunkOracle.HEIGHT, factory, tag);
    var sections = new HashMap<Integer, net.minecraft.world.level.chunk.LevelChunkSection>();
    for (var section : data.sectionData()) if (section.chunkSection() != null) sections.put(section.y(), section.chunkSection());
    var states = expected.getAsJsonArray("states");
    for (int y = -64; y < 320; y++) {
      int want = states.get(y + 64).getAsInt();
      var section = sections.get(y >> 4);
      for (int x = 0; x < 16; x++)
        for (int z = 0; z < 16; z++) {
          int got = section == null ? 0 : net.minecraft.world.level.block.Block.getId(section.getBlockState(x, y & 15, z));
          if (got != want) throw new AssertionError(name + ": at " + x + ", " + y + ", " + z + " vanilla has " + got + ", ValiMC " + want);
        }
      if (section != null) {
        var biome = section.getNoiseBiome(0, (y & 15) >> 2, 0).unwrapKey().orElseThrow().identifier().toString();
        if (!biome.equals(expected.get("biome").getAsString()))
          throw new AssertionError(name + ": vanilla's biome " + biome + ", ValiMC's " + expected.get("biome"));
      }
    }
  }
}
