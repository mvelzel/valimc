import com.google.gson.*;
import java.io.InputStream;
import java.nio.file.*;
import java.util.*;
import java.util.zip.ZipFile;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtAccounter;
import net.minecraft.nbt.NbtIo;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.NoiseSpawnFinder;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.densityfunction.SamplerContext;

/**
 * Vanilla's world spawn search (VMC-027d).
 *
 * `origins OUT`: per seed, the spawn target origin column vanilla's overworld
 * generator searches from (`NoiseSpawnFinder.findSpawnPosition` over the
 * noise settings' spawn target with cached samplers, as
 * `NoiseBasedChunkGenerator.getOrigin` calls it).
 *
 * `worlds OUT SCOPE`: per seed, the world spawn an actual dedicated server
 * chooses when it creates the world (`MinecraftServer.setInitialSpawn`, read
 * from `level.dat`). SCOPE is the generation ValiMC runs live: `terrain`
 * creates the world with structures off and a data pack that empties every
 * biome's feature list (noise, surface and carvers remain); `features` keeps
 * the features (VMC-025d); `full` also generates structures.
 */
public class SpawnOracle {
  static final long[] ORIGIN_SEEDS = {0L, 1L, -1L, 42L, 12345L, 20261020L, 8675309L, Long.MIN_VALUE, Long.MAX_VALUE,
      -4172144997902289642L, 3257840388504953787L, 7L, 1000L, -1000L, 2147483648L, 123456789012345L,
      64L, 99L, 31337L, -31337L, 5L, 6L, 8L, 9L, 10L, 11L, 13L, 17L, 19L, 23L, 29L, 31L};
  // 315 and 225 spawn beyond their origin chunk (the spiral).
  static final long[] WORLD_SEEDS = {12345L, 0L, 20261020L, -1L, 7L, 315L, 225L};

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    switch (args[0]) {
      case "origins" -> origins(args[1]);
      case "worlds" -> worlds(args[1], args[2]);
      default -> throw new AssertionError(args[0]);
    }
  }

  static void origins(String out) throws Exception {
    var lookup = VanillaRegistries.createWorldLookup();
    var settings = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(NoiseGeneratorSettings.OVERWORLD).value();
    var noises = lookup.lookupOrThrow(Registries.NOISE);
    var rows = new JsonArray();
    for (long seed : ORIGIN_SEEDS) {
      var state = RandomState.create(noises, seed, settings);
      var origin = NoiseSpawnFinder.findSpawnPosition(settings.spawnTarget(),
          state.samplersWithContext(SamplerContext.builder().enableCaches().build()));
      var row = new JsonObject();
      row.addProperty("seed", Long.toString(seed));
      row.addProperty("x", origin.getX());
      row.addProperty("z", origin.getZ());
      rows.add(row);
    }
    Files.writeString(Path.of(out), new Gson().toJson(rows));
    System.out.println("PASS: " + rows.size() + " actual overworld spawn target origins.");
  }

  static void worlds(String out, String scope) throws Exception {
    if (!List.of("terrain", "features", "full").contains(scope)) throw new AssertionError(scope);
    var rows = new JsonArray();
    var root = Files.createTempDirectory("valimc-spawn-");
    try {
      for (long seed : WORLD_SEEDS) {
        var dir = root.resolve(Long.toString(seed));
        if (scope.equals("terrain")) featureless(dir.resolve("universe/w/datapacks/featureless"));
        WorldNbtOracle.runServer(dir, Map.of("level-seed", Long.toString(seed),
            "generate-structures", Boolean.toString(scope.equals("full"))), List.of());
        CompoundTag level = NbtIo.readCompressed(dir.resolve("universe/w/level.dat"), NbtAccounter.unlimitedHeap());
        var spawn = level.getCompoundOrEmpty("Data").getCompoundOrEmpty("spawn");
        int[] pos = spawn.getIntArray("pos").orElseThrow();
        if (!spawn.getStringOr("dimension", "").equals("minecraft:overworld")) throw new AssertionError("spawn dimension");
        var row = new JsonObject();
        row.addProperty("seed", Long.toString(seed));
        row.addProperty("x", pos[0]);
        row.addProperty("y", pos[1]);
        row.addProperty("z", pos[2]);
        rows.add(row);
      }
    } finally {
      try (var walk = Files.walk(root)) {
        walk.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete());
      }
    }
    Files.writeString(Path.of(out), new Gson().toJson(rows));
    System.out.println("PASS: " + rows.size() + " actual dedicated-server world spawns (" + scope + ").");
  }

  /** A data pack that empties every vanilla biome's feature steps, from the jar's own biome files. */
  static void featureless(Path pack) throws Exception {
    var jar = Path.of(SharedConstants.class.getProtectionDomain().getCodeSource().getLocation().toURI());
    try (var zip = new ZipFile(jar.toFile())) {
      String meta;
      try (InputStream in = zip.getInputStream(zip.getEntry("data/minecraft/datapacks/trade_rebalance/pack.mcmeta"))) {
        var json = JsonParser.parseString(new String(in.readAllBytes())).getAsJsonObject();
        json.remove("features");
        json.getAsJsonObject("pack").addProperty("description", "ValiMC spawn oracle: no features");
        meta = json.toString();
      }
      Files.createDirectories(pack);
      Files.writeString(pack.resolve("pack.mcmeta"), meta);
      var prefix = "data/minecraft/worldgen/biome/";
      int count = 0;
      for (var entry : Collections.list(zip.entries())) {
        if (!entry.getName().startsWith(prefix) || !entry.getName().endsWith(".json")) continue;
        try (InputStream in = zip.getInputStream(entry)) {
          var biome = JsonParser.parseString(new String(in.readAllBytes())).getAsJsonObject();
          biome.add("features", new JsonArray());
          var target = pack.resolve(entry.getName());
          Files.createDirectories(target.getParent());
          Files.writeString(target, biome.toString());
          count++;
        }
      }
      if (count < 60) throw new AssertionError("biomes: " + count);
    }
  }
}
