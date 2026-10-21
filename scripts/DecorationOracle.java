import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Function;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.core.HolderGetter;
import net.minecraft.core.SectionPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.StructureManager;
import net.minecraft.world.level.WorldGenLevel;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeManager;
import net.minecraft.world.level.biome.BiomeSource;
import net.minecraft.world.level.biome.FeatureSorter;
import net.minecraft.world.level.biome.MultiNoiseBiomeSource;
import net.minecraft.world.level.biome.MultiNoiseBiomeSourceParameterList;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.EntityBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.chunk.UpgradeData;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.dimension.BuiltinDimensionTypes;
import net.minecraft.world.level.levelgen.Aquifer;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.WorldgenRandom;
import net.minecraft.world.level.levelgen.XoroshiroRandomSource;
import net.minecraft.world.level.levelgen.RandomSupport;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;
import net.minecraft.world.level.levelgen.feature.Feature;
import net.minecraft.world.level.levelgen.material.rule.MaterialRule;
import net.minecraft.world.level.levelgen.placement.FeaturePlacer;
import net.minecraft.world.level.levelgen.placement.PlacedFeature;
import net.minecraft.world.level.storage.LevelData;
import net.minecraft.world.ticks.WorldGenTickAccess;

/**
 * Vanilla decoration (VMC-025). Cases: per seed, two areas near the origin, two within 32,000
 * blocks and one far out; on the first seed also one area per entry of BIOME_AREAS (a biome
 * at the centre chunk's surface or cave depth, for some also a placed feature that must pass
 * its rarity filter there or change blocks there on its own). Worldgen comes from the vanilla
 * data pack, as a server loads it (static registries' tags first). For each case (seed, centre chunk),
 * the 5 × 5 chunks around the centre get vanilla's overworld terrain as TerrainOracle
 * builds it (fill, surface, carvers; chunk biomes and carver biomes from
 * fresh lookup histories), their biomes stored as chunk generation stores
 * them, and the final heightmaps primed as the terrain step primes them; the
 * chunks then hold status `terrain`. The 3 × 3 chunks around the centre are
 * decorated in order (Z outer, X inner) by vanilla's features step: the loop
 * of `ChunkGenerator.applyBiomeDecoration` (decoration seed, possible biomes
 * of the 3 × 3 around the chunk, feature order and seeds, `FeaturePlacer`
 * with the biome check), without structures, restricted to the placed
 * features whose features (with sub-features) all have a type from the
 * argument list. `WorldGenRegion` needs a running server, so the level is a
 * `WorldGenLevel` over the proto chunks that follows `WorldGenRegion` (3 × 3 write
 * zone, block reads up to the region's bounds, biomes of the 3 × 3 through
 * `BiomeManager`, setBlock with block entities and post-processing marks,
 * heightmaps of the chunks, ticks into the chunks' tick containers at game
 * time 0, the region's own random) and fails on anything a feature asks that it does not
 * implement; `getLevel` holds only the generator, which trees' pale moss decorator asks for, and
 * a server with a structure template manager over the vanilla data pack (template and fossil
 * features).
 *
 * VMC-026a: with `nether` or `end`, the same for that dimension of the normal world preset: its
 * noise settings and biome source (the Nether preset, the End's), dimension type, sea level and
 * build bounds (0 to 256, the noise filling the lower 128), and its own areas (see
 * `NETHER_AREAS` and `END_AREAS`; the End's main island instead of the areas near the origin).
 * The level records the entities features add (the End spikes' crystals).
 *
 * Usage: DecorationOracle OUT TYPE,TYPE,... [nether|end] [bench|live] (`*`: every type; a placed
 * feature's identifier includes that placed feature). Output: the dimension, its noise settings,
 * biome source and bounds, the included
 * placed features per step (vanilla's global index and identifier), and per
 * chunk of the 5 × 5 its states run-length encoded in volume order (Y fastest
 * from the bottom, then X, then Z) as [id, count] pairs, its post-processing
 * marks, scheduled block and fluid ticks (position, type, delay, priority),
 * block entity positions and, for the block entities features created, their type,
 * loot table and seed, spawned entity, a beehive's bees (ticks in the hive) and an end
 * gateway's exit; and the entities features added (type, position, yaw).
 */
public class DecorationOracle {
  /**
   * The dimension decorated (VMC-026a): its name, build bounds, noise settings, dimension type
   * and sea level, as the normal world preset's dimensions have them.
   */
  static String DIMENSION = "overworld";
  static int MIN_Y = -64, HEIGHT = 384, SEA_LEVEL = 63;
  static net.minecraft.resources.ResourceKey<NoiseGeneratorSettings> SETTINGS;
  static net.minecraft.resources.ResourceKey<net.minecraft.world.level.dimension.DimensionType> TYPE;
  static net.minecraft.core.RegistryAccess REGISTRIES;
  /** The entities features added to each proto chunk: type, position, yaw. */
  static final Map<ProtoChunk, List<String>> ENTITIES = Collections.synchronizedMap(new IdentityHashMap<>());

  static void selectDimension(String name) {
    DIMENSION = name;
    switch (name) {
      case "nether" -> {
        MIN_Y = 0;
        HEIGHT = 256;
        SETTINGS = NoiseGeneratorSettings.NETHER;
        TYPE = BuiltinDimensionTypes.NETHER;
      }
      case "end" -> {
        MIN_Y = 0;
        HEIGHT = 256;
        SETTINGS = NoiseGeneratorSettings.END;
        TYPE = BuiltinDimensionTypes.END;
      }
      default -> {
        MIN_Y = -64;
        HEIGHT = 384;
        SETTINGS = NoiseGeneratorSettings.OVERWORLD;
        TYPE = BuiltinDimensionTypes.OVERWORLD;
      }
    }
  }

  /** The dimension's biome source, its multi-noise lists with a fresh lookup history. */
  static BiomeSource biomeSource(HolderGetter<Biome> biomeLookup) {
    return switch (DIMENSION) {
      case "end" -> net.minecraft.world.level.biome.TheEndBiomeSource.create(biomeLookup);
      case "nether" -> MultiNoiseBiomeSource.createFromList(
          TerrainOracle.freshList(MultiNoiseBiomeSourceParameterList.Preset.NETHER, biomeLookup));
      default -> MultiNoiseBiomeSource.createFromList(
          TerrainOracle.freshList(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD, biomeLookup));
    };
  }

  static String biomeSourceId() {
    return switch (DIMENSION) {
      case "end" -> "minecraft:the_end";
      case "nether" -> "minecraft:nether";
      default -> "minecraft:overworld";
    };
  }

  public static void main(String[] args) throws Exception {
    if (args[0].equals("trig")) {
      // Ore shapes take Math.sin and Math.cos of nextFloat() * (float) PI, a float with 2^24
      // possible values: the SHA-256 of all their results (doubles, little-endian bits) on this
      // JVM, and how many differ from StrictMath (Math may differ by platform within an ulp).
      var digest = java.security.MessageDigest.getInstance("SHA-256");
      var buffer = java.nio.ByteBuffer.allocate(16).order(java.nio.ByteOrder.LITTLE_ENDIAN);
      for (int k = 0; k < (1 << 24); k++) {
        float dir = k * 5.9604645E-8F * (float) Math.PI;
        buffer.clear();
        buffer.putLong(Double.doubleToRawLongBits(Math.sin(dir))).putLong(Double.doubleToRawLongBits(Math.cos(dir)));
        digest.update(buffer.array());
      }
      int strictDiffers = 0;
      for (int k = 0; k < (1 << 24); k++) {
        float dir = k * 5.9604645E-8F * (float) Math.PI;
        if (Math.sin(dir) != StrictMath.sin(dir) || Math.cos(dir) != StrictMath.cos(dir)) strictDiffers++;
      }
      System.out.println("PASS: ore trig digest " + java.util.HexFormat.of().formatHex(digest.digest())
          + "; Math differs from StrictMath on " + strictDiffers + " inputs");
      return;
    }
    var factory = ChunkOracle.factory();
    boolean bench = false, live = false;
    selectDimension("overworld");
    for (int i = 2; i < args.length; i++) {
      if (args[i].equals("bench")) bench = true;
      else if (args[i].equals("live")) live = true;
      else selectDimension(args[i]);
    }
    // Fluid tags, as a server binds them (survival and water checks read them).
    SupportOracle.bindFluidTags();
    net.minecraft.core.RegistryAccess registries;
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      MiningToolOracle.initialize();
      // As a server loads them (`WorldLoader`): the static registries' tags from the pack first,
      // so that tag holder sets in worldgen entries (random blocks of a tag) have contents.
      var layered = net.minecraft.server.RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,
          layered.getLayer(net.minecraft.server.RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(
          layered.getAccessForLoading(net.minecraft.server.RegistryLayer.WORLD), pending);
      registries = net.minecraft.resources.RegistryDataLoader.load(resources, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(net.minecraft.core.Registry.PendingTags::apply);
    }
    REGISTRIES = registries;
    var types = new HashSet<>(Arrays.asList(args[1].split(",")));
    // Worldgen as a server loads it, from the vanilla data pack: its JSON is what the code's
    // registries encode to, which differs where a codec writes another field (the cherry foliage
    // placer's corner hole chance is written as its wide bottom layer hole chance, 0.25, not 0.5).
    net.minecraft.core.HolderLookup.Provider lookup = registries;
    var noises = lookup.lookupOrThrow(Registries.NOISE);
    var biomeLookup = lookup.lookupOrThrow(Registries.BIOME);
    var holder = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(SETTINGS);
    var settings = holder.value();
    SEA_LEVEL = settings.seaLevel();
    var doFill = NoiseBasedChunkGenerator.class.getDeclaredMethod("doFill", NoiseChunk.class, ChunkAccess.class);
    doFill.setAccessible(true);
    var buildSurface = NoiseBasedChunkGenerator.class.getDeclaredMethod("buildSurface", ChunkAccess.class, NoiseChunk.class,
        RandomState.class, BiomeManager.class, Set.class, MaterialRule.class);
    buildSurface.setAccessible(true);
    var generateCarvers = NoiseBasedChunkGenerator.class.getDeclaredMethod("generateCarvers", ChunkAccess.class, Blender.class,
        NoiseChunk.class, RandomState.class, BiomeManager.class, net.minecraft.server.level.WorldGenRegion.class, MaterialRule.class);
    generateCarvers.setAccessible(true);
    var createFluidPicker = NoiseBasedChunkGenerator.class.getDeclaredMethod("createFluidPicker", NoiseGeneratorSettings.class);
    createFluidPicker.setAccessible(true);
    var picker = (Aquifer.FluidPicker) createFluidPicker.invoke(null, settings);
    var heights = LevelHeightAccessor.create(MIN_Y, HEIGHT);
    // Vanilla's feature order, from the preset's biomes in parameter order.
    var steps = FeatureSorter.buildFeaturesPerStep(List.copyOf(biomeSource(biomeLookup).possibleBiomes()),
        b -> b.value().getGenerationSettings().features(), true);
    var placedIds = new IdentityHashMap<PlacedFeature, String>();
    lookup.lookupOrThrow(Registries.PLACED_FEATURE).listElements()
        .forEach(h -> placedIds.put(h.value(), h.key().identifier().toString()));
    // Included placed features per step: (global index, feature).
    var included = new ArrayList<Map<Integer, PlacedFeature>>();
    var includedJson = new JsonArray();
    for (var step : steps) {
      var map = new TreeMap<Integer, PlacedFeature>();
      var ids = new JsonArray();
      for (int i = 0; i < step.features().size(); i++) {
        var placed = step.features().get(i);
        if (types.contains("*") || types.contains(placedIds.get(placed))
            || placed.getFeatures().allMatch(f -> types.contains(typeOf(f.value())))) {
          map.put(i, placed);
          var entry = new JsonArray();
          entry.add(i);
          entry.add(placedIds.get(placed));
          ids.add(entry);
        }
      }
      included.add(map);
      includedJson.add(ids);
    }

    if (live) {
      live(Path.of(args[0]), factory, registries, lookup, noises, biomeLookup, holder, settings, doFill, buildSurface,
          generateCarvers, picker, heights, steps, included, includedJson);
      return;
    }
    if (bench) {
      bench(Path.of(args[0]), factory, registries, lookup, noises, biomeLookup, holder, settings, doFill, buildSurface, generateCarvers,
          picker, heights, steps, included, includedJson);
      return;
    }
    var gen = new Random(20261020L);
    long[] seeds = {20261020L, -8172645723L, gen.nextLong()};
    var cases = new JsonArray();
    long blocks = 0;
    int features = 0;
    for (long seed : seeds) {
      var state = RandomState.create(noises, seed, settings);
      BiomeSource biomeSource = biomeSource(biomeLookup);
      var generator = new NoiseBasedChunkGenerator(biomeSource, holder);
      var terrain = new Terrain(factory, seed, state, settings, picker, generator, heights, biomeLookup, doFill, buildSurface, generateCarvers);
      var centres = new ArrayList<>(DIMENSION.equals("end")
          // The main island: its spikes (all ten over four areas on the first seed) and the
          // arrival platform's chunk.
          ? (seed == seeds[0] ? List.of(new ChunkPos(1, 1), new ChunkPos(-2, 1), new ChunkPos(-2, -2), new ChunkPos(1, -2),
              new ChunkPos(6, 0)) : List.of(new ChunkPos(1, 1)))
          : List.of(new ChunkPos(0, 0), new ChunkPos(-3, 5)));
      for (int i = 0; i < 2; i++) centres.add(new ChunkPos(gen.nextInt(4001) - 2000, gen.nextInt(4001) - 2000));
      centres.add(new ChunkPos(gen.nextInt(3_750_001) - 1_875_000, gen.nextInt(3_750_001) - 1_875_000));
      if (seed == seeds[0]) {
        var search = new Random(seed);
        for (var area : biomeAreas()) {
          var target = DIMENSION.equals("end") ? END_TARGETED.get(area) : TARGETED.get(area);
          String biome = target == null ? area : target[0];
          java.util.function.Predicate<ChunkPos> cheap = p -> true, accept = p -> true;
          if (target != null) {
            var placed = lookup.lookupOrThrow(Registries.PLACED_FEATURE)
                .getOrThrow(net.minecraft.resources.ResourceKey.create(Registries.PLACED_FEATURE,
                    net.minecraft.resources.Identifier.parse(target[1]))).value();
            if (target[2].equals("rarity")) {
              cheap = p -> rarityPasses(seed, p, steps, placed);
            } else {
              accept = p -> places(terrain, p, seed, state, biomeSource, lookup, registries, generator, steps, placed);
            }
          }
          centres.add(findBiome(search, generator, biomeSource, state, heights, biome, cheap, accept));
        }
      }
      for (var centre : centres) {
       // The first area is also decorated by vanilla's own
       // applyBiomeDecoration when every placed feature is included, and must
       // come out the same as this oracle's loop.
       boolean selfCheck = cases.isEmpty() && included.stream().mapToInt(Map::size).sum()
           == steps.stream().mapToInt(st -> st.features().size()).sum();
       JsonArray reference = null;
       for (int run = selfCheck ? 0 : 1; run < 2; run++) {
        var chunks = terrain.area(centre, 2);
        var order = new JsonArray();
        for (int dz = -1; dz <= 1; dz++) {
          for (int dx = -1; dx <= 1; dx++) {
            var pos = new ChunkPos(centre.x() + dx, centre.z() + dz);
            var region = new Region(chunks, pos, seed, state, biomeSource, lookup);
            region.registries = registries;
            region.generator = generator;
            WorldGenLevel level = region;
            if (run == 0) {
              generator.applyBiomeDecoration(level, chunks.get(pos), new StructureManager(level, new WorldOptions(seed, false, false), null));
            } else {
              features += decorate(level, generator, chunks.get(pos), steps, included);
            }
            var p = new JsonArray();
            p.add(pos.x());
            p.add(pos.z());
            order.add(p);
          }
        }
        var rows = new JsonArray();
        for (var entry : chunks.entrySet()) {
          rows.add(chunkJson(entry.getKey(), entry.getValue()));
          if (run == 1) blocks += 16 * 16 * HEIGHT;
        }
        if (run == 0) {
          reference = rows;
          continue;
        }
        if (reference != null && !reference.equals(rows)) {
          throw new IllegalStateException("the oracle's decoration loop differs from applyBiomeDecoration");
        }
        if (reference != null) System.out.println("PASS: the decoration loop equals vanilla's applyBiomeDecoration on the first area");
        var row = new JsonObject();
        row.addProperty("seed", Long.toString(seed));
        row.addProperty("x", centre.x());
        row.addProperty("z", centre.z());
        row.add("order", order);
        row.add("chunks", rows);
        cases.add(row);
       }
      }
    }
    var out = new JsonObject();
    out.addProperty("dimension", DIMENSION);
    out.addProperty("noise_settings", SETTINGS.identifier().toString());
    out.addProperty("biome_source", biomeSourceId());
    out.addProperty("min_y", MIN_Y);
    out.addProperty("height", HEIGHT);
    out.add("features", includedJson);
    out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla decorated " + DIMENSION + " areas (" + blocks + " blocks, " + features
        + " placed features run) over " + seeds.length + " seeds");
  }

  /**
   * `OUT TYPES [DIMENSION] bench`: one thread, seed 20261020, the 8 × 8 chunks from the
   * dimension's `BENCH_ORIGIN` decorated (Z outer, X inner) in the 10 × 10 terrain area around
   * them; the terrain is rebuilt for every pass and not timed. Two warm-up and five timed passes;
   * nanoseconds per pass.
   */
  static void bench(Path out, net.minecraft.world.level.chunk.PalettedContainerFactory factory, net.minecraft.core.RegistryAccess registries,
      HolderGetter.Provider lookup, HolderGetter<net.minecraft.world.level.levelgen.synth.NormalNoise> noises, HolderGetter<Biome> biomeLookup,
      Holder<NoiseGeneratorSettings> holder, NoiseGeneratorSettings settings, Method doFill, Method buildSurface, Method generateCarvers,
      Aquifer.FluidPicker picker, LevelHeightAccessor heights, List<FeatureSorter.StepFeatureData> steps,
      List<Map<Integer, PlacedFeature>> included, JsonArray includedJson) throws Exception {
    long seed = 20261020L;
    var state = RandomState.create(noises, seed, settings);
    BiomeSource biomeSource = biomeSource(biomeLookup);
    var generator = new NoiseBasedChunkGenerator(biomeSource, holder);
    int x0 = BENCH_ORIGIN.get(DIMENSION).x(), z0 = BENCH_ORIGIN.get(DIMENSION).z();
    var passes = new JsonArray();
    for (int pass = 0; pass < 7; pass++) {
      var biomeCache = new HashMap<ChunkPos, Holder<Biome>[]>();
      Function<ChunkPos, Holder<Biome>[]> biomesOf = p -> biomeCache.computeIfAbsent(p,
          q -> TerrainOracle.chunkBiomes(state, DIMENSION, biomeLookup, q, MIN_Y, HEIGHT));
      var biomeManager = new BiomeManager((qx, qy, qz) -> biomeAt(biomesOf, qx, qy, qz), BiomeManager.obfuscateSeed(seed));
      var chunks = new LinkedHashMap<ChunkPos, ProtoChunk>();
      var noise = settings.noiseSettings().clampToHeightAccessor(heights);
      for (int z = z0 - 1; z <= z0 + 8; z++) {
        for (int x = x0 - 1; x <= x0 + 8; x++) {
          var pos = new ChunkPos(x, z);
          var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, heights, factory, null);
          var volume = new DensityVolume(16, noise.height(), 16, pos.getMinBlockX(), noise.minY(), pos.getMinBlockZ());
          try (var noiseChunk = new NoiseChunk(state, null, settings, picker, Blender.empty(), volume)) {
            doFill.invoke(generator, noiseChunk, chunk);
            buildSurface.invoke(generator, chunk, noiseChunk, state, biomeManager, null, settings.materialRule().value());
            generateCarvers.invoke(generator, chunk, Blender.empty(), noiseChunk, state, biomeManager, null, settings.materialRule().value());
          }
          chunk.fillBiomesFromNoise((qx, qy, qz) -> biomeAt(biomesOf, qx, qy, qz));
          Heightmap.primeHeightmaps(chunk, EnumSet.of(Heightmap.Types.MOTION_BLOCKING,
              Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, Heightmap.Types.OCEAN_FLOOR, Heightmap.Types.WORLD_SURFACE));
          chunk.setPersistedStatus(ChunkStatus.TERRAIN);
          chunks.put(pos, chunk);
        }
      }
      long start = System.nanoTime();
      for (int z = z0; z < z0 + 8; z++) {
        for (int x = x0; x < x0 + 8; x++) {
          var pos = new ChunkPos(x, z);
          var region = new Region(chunks, pos, seed, state, biomeSource, lookup);
          region.registries = registries;
          region.generator = generator;
          WorldGenLevel level = region;
          decorate(level, generator, chunks.get(pos), steps, included);
        }
      }
      long elapsed = System.nanoTime() - start;
      if (pass >= 2) passes.add(elapsed);
    }
    var result = new JsonObject();
    result.addProperty("dimension", DIMENSION);
    result.addProperty("noise_settings", SETTINGS.identifier().toString());
    result.addProperty("biome_source", biomeSourceId());
    result.addProperty("x", x0);
    result.addProperty("z", z0);
    result.add("features", includedJson);
    result.add("vanilla_decoration_ns", passes);
    result.addProperty("java", System.getProperty("java.vm.name") + " " + System.getProperty("java.version"));
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: vanilla " + DIMENSION + " decoration timings for 64 chunks");
  }

  /** ValiMC's region size in chunks (`:region_size`), which live generation finalizes at once. */
  static final int REGION = 8;

  /**
   * `OUT TYPES live` (VMC-025d2): regions finalized one after the other as ValiMC's live
   * generation does it. For each case (seed, regions in order), the 12 × 12 chunks around each
   * region get terrain, then each region's undecorated chunks of the 10 × 10 around it are
   * decorated, Z outer and X inner. Output per finalized region its 64 chunks as `chunkJson`
   * writes them, plus each block entity as the full chunk saves it: a created one with what
   * features wrote, a pending one as its block's new block entity (`LevelChunk` promotes them
   * so), each `saveWithFullMetadata` written as unnamed binary NBT in base64; and the new block
   * entity of each block decoration places with one.
   */
  static void live(Path out, net.minecraft.world.level.chunk.PalettedContainerFactory factory, net.minecraft.core.RegistryAccess registries,
      HolderGetter.Provider lookup, HolderGetter<net.minecraft.world.level.levelgen.synth.NormalNoise> noises, HolderGetter<Biome> biomeLookup,
      Holder<NoiseGeneratorSettings> holder, NoiseGeneratorSettings settings, Method doFill, Method buildSurface, Method generateCarvers,
      Aquifer.FluidPicker picker, LevelHeightAccessor heights, List<FeatureSorter.StepFeatureData> steps,
      List<Map<Integer, PlacedFeature>> included, JsonArray includedJson) throws Exception {
    // World presets (VMC-028b): noise settings, and a fixed biome or the overworld preset.
    record Case(long seed, List<ChunkPos> regions, String noise, String fixed) {}
    var cases = List.of(
        new Case(20261020L, List.of(new ChunkPos(0, 0), new ChunkPos(1, 0), new ChunkPos(1, 1)), "overworld", null),
        new Case(-8172645723L, List.of(new ChunkPos(-3, 7), new ChunkPos(-4, 7)), "overworld", null),
        new Case(20261020L, List.of(new ChunkPos(25000, -18000)), "overworld", null),
        new Case(20261020L, List.of(new ChunkPos(2, -3), new ChunkPos(3, -3)), "large_biomes", null),
        new Case(12345L, List.of(new ChunkPos(0, 0)), "amplified", null),
        new Case(20261020L, List.of(new ChunkPos(-5, 4)), "overworld", "plains"));
    var createFluidPicker = NoiseBasedChunkGenerator.class.getDeclaredMethod("createFluidPicker", NoiseGeneratorSettings.class);
    createFluidPicker.setAccessible(true);
    var rows = new JsonArray();
    long blocks = 0;
    int entities = 0;
    for (var c : cases) {
      var caseHolder = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(net.minecraft.resources.ResourceKey.create(
          Registries.NOISE_SETTINGS, net.minecraft.resources.Identifier.withDefaultNamespace(c.noise())));
      var caseSettings = caseHolder.value();
      var casePicker = (Aquifer.FluidPicker) createFluidPicker.invoke(null, caseSettings);
      var state = RandomState.create(noises, c.seed(), caseSettings);
      Holder<Biome> fixed = c.fixed() == null ? null : biomeLookup.getOrThrow(net.minecraft.resources.ResourceKey.create(
          Registries.BIOME, net.minecraft.resources.Identifier.withDefaultNamespace(c.fixed())));
      BiomeSource biomeSource = fixed != null ? new net.minecraft.world.level.biome.FixedBiomeSource(fixed)
          : MultiNoiseBiomeSource.createFromList(TerrainOracle.freshList(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD, biomeLookup));
      // A fixed source's feature order: FeatureSorter over its one biome.
      var caseSteps = fixed == null ? steps : FeatureSorter.buildFeaturesPerStep(List.of(fixed),
          b -> b.value().getGenerationSettings().features(), true);
      var caseIncluded = included;
      if (fixed != null) {
        caseIncluded = new ArrayList<>();
        for (var step : caseSteps) {
          var map = new TreeMap<Integer, PlacedFeature>();
          for (int i = 0; i < step.features().size(); i++) map.put(i, step.features().get(i));
          caseIncluded.add(map);
        }
      }
      var generator = new NoiseBasedChunkGenerator(biomeSource, caseHolder);
      var terrain = new Terrain(factory, c.seed(), state, caseSettings, casePicker, generator, heights, biomeLookup,
          doFill, buildSurface, generateCarvers, fixed);
      var area = new LinkedHashSet<ChunkPos>();
      for (var r : c.regions()) area.addAll(around(r, 2));
      var chunks = terrain.build(area);
      var decorated = new HashSet<ChunkPos>();
      var order = new JsonArray();
      for (var r : c.regions()) {
        for (var pos : around(r, 1)) {
          if (!decorated.add(pos)) continue;
          var region = new Region(chunks, pos, c.seed(), state, biomeSource, lookup);
          region.registries = registries;
          region.generator = generator;
          decorate(region, generator, chunks.get(pos), caseSteps, caseIncluded);
          var p = new JsonArray();
          p.add(pos.x());
          p.add(pos.z());
          order.add(p);
        }
      }
      var regions = new JsonArray();
      for (var r : c.regions()) {
        var finalChunks = new JsonArray();
        for (var pos : around(r, 0)) {
          var chunk = chunks.get(pos);
          var row = chunkJson(pos, chunk);
          var nbt = new TreeMap<String, String>();
          for (var be : chunk.getBlockEntities().values()) nbt.put(key(be.getBlockPos()), encode(be));
          for (var bp : chunk.getBlockEntityNbts().keySet()) {
            var blockState = chunk.getBlockState(bp);
            if (blockState.getBlock() instanceof net.minecraft.world.level.block.EntityBlock eb) {
              var be = eb.newBlockEntity(bp, blockState);
              if (be != null) nbt.put(key(bp), encode(be));
            }
          }
          entities += nbt.size();
          var list = new JsonArray();
          nbt.forEach((k, v) -> list.add(k + "," + v));
          row.add("nbt", list);
          finalChunks.add(row);
          blocks += 16 * 16 * HEIGHT;
        }
        var region = new JsonObject();
        region.addProperty("x", r.x());
        region.addProperty("z", r.z());
        region.add("chunks", finalChunks);
        regions.add(region);
      }
      var row = new JsonObject();
      row.addProperty("seed", Long.toString(c.seed()));
      row.addProperty("noise_settings", "minecraft:" + c.noise());
      if (fixed != null) row.addProperty("fixed_biome", "minecraft:" + c.fixed());
      row.add("order", order);
      row.add("regions", regions);
      rows.add(row);
    }
    // The new block entity of each block decoration places with one, at (1, 2, 3): what a pending
    // block entity becomes in the full chunk.
    var defaults = new JsonArray();
    for (var name : List.of("chest", "trapped_chest", "spawner", "bee_nest", "suspicious_sand", "suspicious_gravel",
        "sculk_sensor", "sculk_shrieker", "sculk_catalyst", "creaking_heart", "potent_sulfur")) {
      var block = net.minecraft.core.registries.BuiltInRegistries.BLOCK.getValue(
          net.minecraft.resources.Identifier.withDefaultNamespace(name));
      var be = ((net.minecraft.world.level.block.EntityBlock) block).newBlockEntity(
          new net.minecraft.core.BlockPos(1, 2, 3), block.defaultBlockState());
      defaults.add("minecraft:" + name + "," + encode(be));
    }
    // What decoration writes into the block entities it creates: a beehive's bees (as
    // BeehiveDecorator stores them) and a brushable block's loot (as the desert well's template).
    var nest = (net.minecraft.world.level.block.entity.BeehiveBlockEntity) ((net.minecraft.world.level.block.EntityBlock)
        net.minecraft.world.level.block.Blocks.BEE_NEST).newBlockEntity(new net.minecraft.core.BlockPos(1, 2, 3),
        net.minecraft.world.level.block.Blocks.BEE_NEST.defaultBlockState());
    nest.storeBee(net.minecraft.world.level.block.entity.BeehiveBlockEntity.Occupant.create(123));
    nest.storeBee(net.minecraft.world.level.block.entity.BeehiveBlockEntity.Occupant.create(456));
    defaults.add("minecraft:bee_nest bees 123/456," + encode(nest));
    var sand = (net.minecraft.world.level.block.entity.BrushableBlockEntity) ((net.minecraft.world.level.block.EntityBlock)
        net.minecraft.world.level.block.Blocks.SUSPICIOUS_SAND).newBlockEntity(new net.minecraft.core.BlockPos(1, 2, 3),
        net.minecraft.world.level.block.Blocks.SUSPICIOUS_SAND.defaultBlockState());
    sand.setLootTable(net.minecraft.resources.ResourceKey.create(Registries.LOOT_TABLE,
        net.minecraft.resources.Identifier.parse("minecraft:archaeology/desert_well")), 7L);
    defaults.add("minecraft:suspicious_sand loot minecraft:archaeology/desert_well 7," + encode(sand));
    var result = new JsonObject();
    result.addProperty("region_size", REGION);
    result.add("features", includedJson);
    result.add("defaults", defaults);
    result.add("cases", rows);
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: " + cases.size() + " live generation sequences (" + blocks + " blocks of final chunks, "
        + entities + " block entities)");
  }

  /** The chunks within `r` of region `region`, Z outer and X inner. */
  static List<ChunkPos> around(ChunkPos region, int r) {
    var list = new ArrayList<ChunkPos>();
    for (int z = region.z() * REGION - r; z < region.z() * REGION + REGION + r; z++) {
      for (int x = region.x() * REGION - r; x < region.x() * REGION + REGION + r; x++) list.add(new ChunkPos(x, z));
    }
    return list;
  }

  static String key(net.minecraft.core.BlockPos p) {
    return p.getX() + "," + p.getY() + "," + p.getZ();
  }

  static String encode(net.minecraft.world.level.block.entity.BlockEntity be) throws java.io.IOException {
    var bytes = new java.io.ByteArrayOutputStream();
    net.minecraft.nbt.NbtIo.writeUnnamedTag(be.saveWithFullMetadata(REGISTRIES), new java.io.DataOutputStream(bytes));
    return java.util.Base64.getEncoder().encodeToString(bytes.toByteArray());
  }

  static String typeOf(Feature feature) {
    var key = net.minecraft.core.registries.BuiltInRegistries.FEATURE_TYPE.getKey(feature.codec());
    return Objects.requireNonNull(key, "feature type").toString();
  }

  static Holder<Biome> biomeAt(Function<ChunkPos, Holder<Biome>[]> biomesOf, int qx, int qy, int qz) {
    var column = biomesOf.apply(new ChunkPos(qx >> 2, qz >> 2));
    int clamped = Math.clamp(qy, MIN_Y >> 2, (MIN_Y >> 2) + HEIGHT / 4 - 1) - (MIN_Y >> 2);
    return column[(clamped >> 2) * 64 + ((clamped & 3) * 4 + (qz & 3)) * 4 + (qx & 3)];
  }

  /**
   * Biomes that get an area of their own on the first seed, so that every tree, trunk, foliage
   * and root placer, decorator and large plant is decorated: the centre chunk has the biome at its
   * surface (at y 0 for cave biomes).
   */
  static final List<String> BIOME_AREAS = List.of("jungle", "bamboo_jungle", "sparse_jungle", "dark_forest", "pale_garden",
      "mushroom_fields", "old_growth_spruce_taiga", "old_growth_pine_taiga", "cherry_grove", "mangrove_swamp", "savanna",
      "windswept_savanna", "dappled_forest", "birch_forest", "old_growth_birch_forest", "swamp", "snowy_taiga", "flower_forest",
      "meadow", "wooded_badlands", "grove", "lush_caves",
      // VMC-025c: the remaining features' biomes, and areas where a rare feature's first placement
      // draw passes in the centre chunk.
      "deep_dark", "dripstone_caves", "sulfur_caves", "ice_spikes", "warm_ocean", "frozen_ocean", "deep_frozen_ocean",
      "desert", "desert_fossil", "swamp_fossil", "plains_geode", "lush_caves_roots", "sulfur_caves_spring");
  /**
   * Area name: biome, a placed feature, and whether its rarity filter must pass in the centre chunk
   * ("rarity") or the feature alone must change blocks when it decorates the centre chunk ("places").
   */
  static final Map<String, String[]> TARGETED = Map.of(
      "frozen_ocean", new String[] {"frozen_ocean", "minecraft:iceberg_packed", "rarity"},
      "deep_frozen_ocean", new String[] {"deep_frozen_ocean", "minecraft:iceberg_blue", "rarity"},
      "desert", new String[] {"desert", "minecraft:desert_well", "rarity"},
      "desert_fossil", new String[] {"desert", "minecraft:fossil_lower", "rarity"},
      "swamp_fossil", new String[] {"swamp", "minecraft:fossil_upper", "rarity"},
      "plains_geode", new String[] {"plains", "minecraft:amethyst_geode", "rarity"},
      "lush_caves_roots", new String[] {"lush_caves", "minecraft:rooted_azalea_tree", "places"},
      "sulfur_caves_spring", new String[] {"sulfur_caves", "minecraft:rooted_sulfur_spring", "places"});
  /** Cave biomes, found at a depth instead of the surface. */
  static final Map<String, Integer> CAVE_BIOMES = Map.of("lush_caves", 0, "dripstone_caves", 0, "sulfur_caves", 0,
      "deep_dark", -48);

  /**
   * VMC-026a: one area per Nether biome (its biome at y 64 in the centre chunk), and in the End
   * the outer islands' biomes, with the end gateway and the small islands' extra island where
   * their rarity filters pass in the centre chunk.
   */
  static final List<String> NETHER_AREAS = List.of("nether_wastes", "soul_sand_valley", "crimson_forest", "warped_forest",
      "basalt_deltas");
  static final List<String> END_AREAS = List.of("end_highlands", "end_midlands", "end_barrens", "small_end_islands_island",
      "end_highlands_gateway");
  static final Map<String, String[]> END_TARGETED = Map.of(
      "small_end_islands_island", new String[] {"small_end_islands", "minecraft:end_island_decorated", "rarity"},
      "end_highlands_gateway", new String[] {"end_highlands", "minecraft:end_gateway_return", "rarity"});
  /** Benchmark areas: 8 × 8 chunks from here (the End's outer islands, past its main island). */
  static final Map<String, ChunkPos> BENCH_ORIGIN = Map.of("overworld", new ChunkPos(0, 0), "nether", new ChunkPos(0, 0),
      "end", new ChunkPos(100, 0));

  static List<String> biomeAreas() {
    return switch (DIMENSION) {
      case "nether" -> NETHER_AREAS;
      case "end" -> END_AREAS;
      default -> BIOME_AREAS;
    };
  }


  /** One seed's terrain for decoration areas, as TerrainOracle builds it. */
  record Terrain(net.minecraft.world.level.chunk.PalettedContainerFactory factory, long seed, RandomState state,
      NoiseGeneratorSettings settings, Aquifer.FluidPicker picker, NoiseBasedChunkGenerator generator, LevelHeightAccessor heights,
      HolderGetter<Biome> biomeLookup, Method doFill, Method buildSurface, Method generateCarvers, Holder<Biome> fixed) {
    Terrain(net.minecraft.world.level.chunk.PalettedContainerFactory factory, long seed, RandomState state,
        NoiseGeneratorSettings settings, Aquifer.FluidPicker picker, NoiseBasedChunkGenerator generator, LevelHeightAccessor heights,
        HolderGetter<Biome> biomeLookup, Method doFill, Method buildSurface, Method generateCarvers) {
      this(factory, seed, state, settings, picker, generator, heights, biomeLookup, doFill, buildSurface, generateCarvers, null);
    }

    /** The (2r + 1)² chunks around `centre` at status `terrain`, Z outer and X inner. */
    LinkedHashMap<ChunkPos, ProtoChunk> area(ChunkPos centre, int r) throws ReflectiveOperationException {
      var positions = new ArrayList<ChunkPos>();
      for (int dz = -r; dz <= r; dz++) {
        for (int dx = -r; dx <= r; dx++) positions.add(new ChunkPos(centre.x() + dx, centre.z() + dz));
      }
      return build(positions);
    }

    /** Chunks at status `terrain`, in the given order. */
    LinkedHashMap<ChunkPos, ProtoChunk> build(Collection<ChunkPos> positions) throws ReflectiveOperationException {
      var biomeCache = new HashMap<ChunkPos, Holder<Biome>[]>();
      // A fixed biome source (VMC-028b) has its one biome everywhere.
      @SuppressWarnings("unchecked")
      Function<ChunkPos, Holder<Biome>[]> biomesOf = fixed != null
          ? p -> { Holder<Biome>[] all = new Holder[HEIGHT * 4]; Arrays.fill(all, fixed); return all; }
          : p -> biomeCache.computeIfAbsent(p, q -> TerrainOracle.chunkBiomes(state, DIMENSION, biomeLookup, q, MIN_Y, HEIGHT));
      var biomeManager = new BiomeManager((qx, qy, qz) -> biomeAt(biomesOf, qx, qy, qz), BiomeManager.obfuscateSeed(seed));
      var chunks = new LinkedHashMap<ChunkPos, ProtoChunk>();
      // The noise fills the generator's bounds within the chunk's (the Nether's and the End's
      // lower 128 of 256 blocks), as `doFill` clamps them.
      var noise = settings.noiseSettings().clampToHeightAccessor(heights);
      for (var pos : positions) {
        var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, heights, factory, null);
        var volume = new DensityVolume(16, noise.height(), 16, pos.getMinBlockX(), noise.minY(), pos.getMinBlockZ());
        try (var noiseChunk = new NoiseChunk(state, null, settings, picker, Blender.empty(), volume)) {
          doFill.invoke(generator, noiseChunk, chunk);
          buildSurface.invoke(generator, chunk, noiseChunk, state, biomeManager, null, settings.materialRule().value());
          generateCarvers.invoke(generator, chunk, Blender.empty(), noiseChunk, state, biomeManager, null,
              settings.materialRule().value());
        }
        chunk.fillBiomesFromNoise((qx, qy, qz) -> biomeAt(biomesOf, qx, qy, qz));
        Heightmap.primeHeightmaps(chunk, EnumSet.of(Heightmap.Types.MOTION_BLOCKING,
            Heightmap.Types.MOTION_BLOCKING_NO_LEAVES, Heightmap.Types.OCEAN_FLOOR, Heightmap.Types.WORLD_SURFACE));
        chunk.setPersistedStatus(ChunkStatus.TERRAIN);
        chunks.put(pos, chunk);
      }
      return chunks;
    }
  }

  /** Whether the placed feature alone changes any block when it decorates the chunk. */
  static boolean places(Terrain terrain, ChunkPos pos, long seed, RandomState state, BiomeSource biomeSource, HolderGetter.Provider lookup,
      net.minecraft.core.RegistryAccess registries, NoiseBasedChunkGenerator generator, List<FeatureSorter.StepFeatureData> steps,
      PlacedFeature feature) {
    try {
      var chunks = terrain.area(pos, 2);
      var before = new JsonArray();
      chunks.forEach((p, c) -> before.add(chunkJson(p, c).get("runs")));
      var only = new ArrayList<Map<Integer, PlacedFeature>>();
      for (var step : steps) {
        var map = new TreeMap<Integer, PlacedFeature>();
        if (step.features().contains(feature)) map.put(step.indexMapping().applyAsInt(feature), feature);
        only.add(map);
      }
      var region = new Region(chunks, pos, seed, state, biomeSource, lookup);
      region.registries = registries;
      region.generator = generator;
      decorate(region, generator, chunks.get(pos), steps, only);
      var after = new JsonArray();
      chunks.forEach((p, c) -> after.add(chunkJson(p, c).get("runs")));
      return !before.equals(after);
    } catch (ReflectiveOperationException e) {
      throw new IllegalStateException(e);
    }
  }

  /**
   * Whether a placed feature's first modifier, a rarity filter, passes in a chunk: its feature seed
   * and draw as `applyBiomeDecoration` makes them.
   */
  static boolean rarityPasses(long seed, ChunkPos pos, List<FeatureSorter.StepFeatureData> steps, PlacedFeature feature) {
    for (int step = 0; step < steps.size(); step++) {
      var data = steps.get(step);
      if (!data.features().contains(feature)) continue;
      var random = new WorldgenRandom(new XoroshiroRandomSource(RandomSupport.generateUniqueSeed()));
      long decorationSeed = random.setDecorationSeed(seed, pos.getMinBlockX(), pos.getMinBlockZ());
      random.setFeatureSeed(decorationSeed, data.indexMapping().applyAsInt(feature), step);
      var rarity = (net.minecraft.world.level.levelgen.placement.RarityFilter) feature.placement().get(0);
      try {
        var chance = net.minecraft.world.level.levelgen.placement.RarityFilter.class.getDeclaredField("chance");
        chance.setAccessible(true);
        return random.nextFloat() < 1.0F / chance.getInt(rarity);
      } catch (ReflectiveOperationException e) {
        throw new IllegalStateException(e);
      }
    }
    throw new IllegalStateException("placed feature in no step");
  }

  /**
   * A seeded random search for a chunk whose centre has the biome (and, when given, where the
   * placed feature's rarity filter passes).
   */
  static ChunkPos findBiome(Random search, NoiseBasedChunkGenerator generator, BiomeSource source, RandomState state,
      LevelHeightAccessor heights, String biome, java.util.function.Predicate<ChunkPos> cheap, java.util.function.Predicate<ChunkPos> accept) {
    var key = net.minecraft.resources.ResourceKey.create(Registries.BIOME, net.minecraft.resources.Identifier.withDefaultNamespace(biome));
    var resolver = source.createResolver(
        state.createClimateSampler(net.minecraft.world.level.levelgen.densityfunction.SamplerContext.builder().enableCaches().build()));
    for (int attempt = 0; attempt < 2_000_000; attempt++) {
      int cx = search.nextInt(8001) - 4000;
      int cz = search.nextInt(8001) - 4000;
      if (!cheap.test(new ChunkPos(cx, cz))) continue;
      int x = cx * 16 + 8;
      int z = cz * 16 + 8;
      int qx = net.minecraft.core.QuartPos.fromBlock(x);
      int qz = net.minecraft.core.QuartPos.fromBlock(z);
      if (CAVE_BIOMES.containsKey(biome)) {
        if (resolver.getNoiseBiome(qx, net.minecraft.core.QuartPos.fromBlock(CAVE_BIOMES.get(biome)), qz).is(key)
            && accept.test(new ChunkPos(cx, cz))) return new ChunkPos(cx, cz);
        continue;
      }
      // A cheap look at sea level first, then at the surface; the Nether's and the End's at y 64.
      if (!resolver.getNoiseBiome(qx, net.minecraft.core.QuartPos.fromBlock(64), qz).is(key)) continue;
      if (!DIMENSION.equals("overworld")) {
        if (accept.test(new ChunkPos(cx, cz))) return new ChunkPos(cx, cz);
        continue;
      }
      int y = generator.getBaseHeight(x, z, Heightmap.Types.WORLD_SURFACE_WG, heights, state);
      if (resolver.getNoiseBiome(qx, net.minecraft.core.QuartPos.fromBlock(y), qz).is(key) && accept.test(new ChunkPos(cx, cz))) {
        return new ChunkPos(cx, cz);
      }
    }
    throw new IllegalStateException("no " + biome + " found");
  }

  /**
   * The features part of `ChunkGenerator.applyBiomeDecoration` (structures
   * off), with only the included placed features; returns how many ran.
   */
  static int decorate(WorldGenLevel level, NoiseBasedChunkGenerator generator, ChunkAccess chunk,
      List<FeatureSorter.StepFeatureData> steps, List<Map<Integer, PlacedFeature>> included) {
    var centerPos = chunk.getPos();
    var sectionPos = SectionPos.of(centerPos, level.getMinSectionY());
    var origin = sectionPos.origin();
    var random = new WorldgenRandom(new XoroshiroRandomSource(RandomSupport.generateUniqueSeed()));
    long decorationSeed = random.setDecorationSeed(level.getSeed(), origin.getX(), origin.getZ());
    Set<Holder<Biome>> possibleBiomes = new it.unimi.dsi.fastutil.objects.ObjectArraySet<>();
    ChunkPos.rangeClosed(sectionPos.chunk(), 1).forEach(chunkPos -> {
      var chunkInRange = level.getChunk(chunkPos.x(), chunkPos.z());
      for (var section : chunkInRange.getSections()) section.getBiomes().getAll(possibleBiomes::add);
    });
    possibleBiomes.retainAll(generator.getBiomeSource().possibleBiomes());
    var placer = new FeaturePlacer(level, generator);
    int ran = 0;
    for (int stepIndex = 0; stepIndex < steps.size(); stepIndex++) {
      var possible = new it.unimi.dsi.fastutil.ints.IntArraySet();
      var stepData = steps.get(stepIndex);
      for (var biome : possibleBiomes) {
        var featuresInBiome = biome.value().getGenerationSettings().features();
        if (stepIndex < featuresInBiome.size()) {
          featuresInBiome.get(stepIndex).stream().map(Holder::value)
              .forEach(f -> possible.add(stepData.indexMapping().applyAsInt(f)));
        }
      }
      int[] indices = possible.toIntArray();
      Arrays.sort(indices);
      for (int index : indices) {
        var feature = included.get(stepIndex).get(index);
        if (feature == null) continue;
        random.setFeatureSeed(decorationSeed, index, stepIndex);
        placer.placeWithBiomeCheck(feature, random, origin);
        ran++;
      }
    }
    return ran;
  }

  static JsonObject chunkJson(ChunkPos pos, ProtoChunk chunk) {
    var runs = new JsonArray();
    int last = -1, count = 0;
    var cursor = new BlockPos.MutableBlockPos();
    for (int z = 0; z < 16; z++)
      for (int x = 0; x < 16; x++)
        for (int y = 0; y < HEIGHT; y++) {
          int id = Block.getId(chunk.getBlockState(cursor.set(pos.getMinBlockX() + x, MIN_Y + y, pos.getMinBlockZ() + z)));
          if (id != last && count > 0) {
            runs.add(last);
            runs.add(count);
            count = 0;
          }
          last = id;
          count++;
        }
    runs.add(last);
    runs.add(count);
    var marks = new TreeSet<String>();
    var lists = chunk.getPostProcessing();
    for (int i = 0; i < lists.length; i++) {
      if (lists[i] == null) continue;
      for (short packed : lists[i]) {
        var p = ProtoChunk.unpackOffsetCoordinates(packed, chunk.getSectionYFromSectionIndex(i), pos);
        marks.add(p.getX() + "," + p.getY() + "," + p.getZ());
      }
    }
    var blockTicks = new JsonArray();
    for (var tick : ((net.minecraft.world.ticks.ProtoChunkTicks<Block>) chunk.getBlockTicks()).scheduledTicks()) {
      blockTicks.add(tick.pos().getX() + "," + tick.pos().getY() + "," + tick.pos().getZ() + ","
          + net.minecraft.core.registries.BuiltInRegistries.BLOCK.getKey(tick.type()) + "," + tick.delay() + "," + tick.priority().getValue());
    }
    var fluidTicks = new JsonArray();
    for (var tick : ((net.minecraft.world.ticks.ProtoChunkTicks<net.minecraft.world.level.material.Fluid>) chunk.getFluidTicks()).scheduledTicks()) {
      fluidTicks.add(tick.pos().getX() + "," + tick.pos().getY() + "," + tick.pos().getZ() + ","
          + net.minecraft.core.registries.BuiltInRegistries.FLUID.getKey(tick.type()) + "," + tick.delay() + "," + tick.priority().getValue());
    }
    var entities = new TreeSet<String>();
    chunk.getBlockEntityNbts().keySet().forEach(p -> entities.add(p.getX() + "," + p.getY() + "," + p.getZ()));
    var added = new JsonArray();
    ENTITIES.getOrDefault(chunk, List.of()).forEach(added::add);
    chunk.getBlockEntities().keySet().forEach(p -> entities.add(p.getX() + "," + p.getY() + "," + p.getZ()));
    // What features wrote into the block entities they created: loot table and seed, spawned entity.
    var entityData = new TreeSet<String>();
    chunk.getBlockEntities().forEach((p, be) -> {
      var tag = be.saveWithoutMetadata(REGISTRIES);
      String loot = tag.getString("LootTable").orElse("-");
      long lootSeed = tag.getLongOr("LootTableSeed", 0L);
      String mob = tag.getCompound("SpawnData").flatMap(d -> d.getCompound("entity")).flatMap(e -> e.getString("id")).orElse("-");
      // A beehive's bees: each one's ticks in the hive.
      var bees = new ArrayList<String>();
      tag.getList("bees").ifPresent(list -> list.forEach(bee ->
          bees.add(String.valueOf(((net.minecraft.nbt.CompoundTag) bee).getIntOr("ticks_in_hive", -1)))));
      // An end gateway's exit and exact teleport (VMC-026a).
      String exit = tag.getIntArray("exit_portal").map(a -> a[0] + ";" + a[1] + ";" + a[2] + ";"
          + tag.getBooleanOr("ExactTeleport", false)).orElse("-");
      entityData.add(p.getX() + "," + p.getY() + "," + p.getZ() + ","
          + net.minecraft.core.registries.BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(be.getType()) + "," + loot + "," + lootSeed + "," + mob
          + "," + (bees.isEmpty() ? "-" : String.join("/", bees)) + "," + exit);
    });
    var row = new JsonObject();
    row.addProperty("x", pos.x());
    row.addProperty("z", pos.z());
    row.add("runs", runs);
    row.add("marks", new Gson().toJsonTree(marks));
    row.add("block_ticks", blockTicks);
    row.add("fluid_ticks", fluidTicks);
    row.add("block_entities", new Gson().toJsonTree(entities));
    row.add("block_entity_data", new Gson().toJsonTree(entityData));
    row.add("entities", added);
    return row;
  }

  /** The features step's `WorldGenRegion`, over proto chunks. */
  static class Region implements WorldGenLevel {
    final Map<ChunkPos, ProtoChunk> chunks;
    final ChunkPos center;
    final long seed;
    final RandomState state;
    final BiomeSource biomeSource;
    final HolderGetter.Provider lookup;
    final net.minecraft.util.RandomSource random;
    final WorldGenTickAccess<Block> blockTicks;
    final WorldGenTickAccess<net.minecraft.world.level.material.Fluid> fluidTicks;
    final LevelData levelData;
    long subTickCount;
    net.minecraft.core.RegistryAccess registries;
    // No chunk is lit during decoration: sky light 15, block light 0.
    final net.minecraft.world.level.lighting.LevelLightEngine lightEngine = new net.minecraft.world.level.lighting.LevelLightEngine(
        (net.minecraft.world.level.chunk.LightChunkGetter) Proxy.newProxyInstance(DecorationOracle.class.getClassLoader(),
            new Class<?>[] {net.minecraft.world.level.chunk.LightChunkGetter.class}, (proxy, method, args) -> switch (method.getName()) {
              case "getChunkForLighting" -> null;
              case "getLevel" -> net.minecraft.world.level.EmptyBlockGetter.INSTANCE;
              default -> throw new UnsupportedOperationException("LightChunkGetter." + method.getName());
            }), true, true);
    WorldGenLevel self = this;
    BiomeManager biomeManager;

    Region(Map<ChunkPos, ProtoChunk> chunks, ChunkPos center, long seed, RandomState state, BiomeSource biomeSource,
        HolderGetter.Provider lookup) {
      this.chunks = chunks;
      this.center = center;
      this.seed = seed;
      this.state = state;
      this.biomeSource = biomeSource;
      this.lookup = lookup;
      this.random = state.getOrCreateRandomFactory(net.minecraft.resources.Identifier.withDefaultNamespace("worldgen_region_random"))
          .at(center.getWorldPosition());
      this.blockTicks = new WorldGenTickAccess<>(pos -> chunk(pos).getBlockTicks());
      this.fluidTicks = new WorldGenTickAccess<>(pos -> chunk(pos).getFluidTicks());
      this.levelData = (LevelData) Proxy.newProxyInstance(DecorationOracle.class.getClassLoader(), new Class<?>[] {LevelData.class},
          (proxy, method, args) -> switch (method.getName()) {
            case "getGameTime" -> 0L;
            default -> throw new UnsupportedOperationException("LevelData." + method.getName());
          });
      this.biomeManager = new BiomeManager(this, BiomeManager.obfuscateSeed(seed));
    }

    int distance(int chunkX, int chunkZ) {
      return Math.max(Math.abs(chunkX - center.x()), Math.abs(chunkZ - center.z()));
    }

    ProtoChunk chunk(int chunkX, int chunkZ) {
      var chunk = chunks.get(new ChunkPos(chunkX, chunkZ));
      if (chunk == null || distance(chunkX, chunkZ) > 8) {
        throw new IllegalStateException("Requested chunk unavailable during world generation: " + chunkX + ", " + chunkZ);
      }
      return chunk;
    }

    ProtoChunk chunk(BlockPos pos) {
      return chunk(SectionPos.blockToSectionCoord(pos.getX()), SectionPos.blockToSectionCoord(pos.getZ()));
    }

    static net.minecraft.server.level.ServerLevel generatorOnlyLevel(net.minecraft.world.level.chunk.ChunkGenerator generator) {
      try {
        var f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        var unsafe = (sun.misc.Unsafe) f.get(null);
        var map = unsafe.allocateInstance(net.minecraft.server.level.ChunkMap.class);
        set(map, net.minecraft.server.level.ChunkMap.class, "worldGenContext",
            new net.minecraft.world.level.chunk.status.WorldGenContext(null, generator, null, null, null, null));
        // A new entity (the End spikes' crystals) takes an id no tracked entity has.
        set(map, net.minecraft.server.level.ChunkMap.class, "entityMap", new it.unimi.dsi.fastutil.ints.Int2ObjectOpenHashMap<>());
        var cache = unsafe.allocateInstance(net.minecraft.server.level.ServerChunkCache.class);
        set(cache, net.minecraft.server.level.ServerChunkCache.class, "chunkMap", map);
        var level = unsafe.allocateInstance(net.minecraft.server.level.ServerLevel.class);
        set(level, net.minecraft.server.level.ServerLevel.class, "chunkSource", cache);
        // Template and fossil features ask its server for the structure template manager.
        var server = templateServer();
        set(level, net.minecraft.server.level.ServerLevel.class, "server", server);
        return (net.minecraft.server.level.ServerLevel) level;
      } catch (ReflectiveOperationException e) {
        throw new IllegalStateException(e);
      }
    }

    static net.minecraft.server.MinecraftServer TEMPLATE_SERVER;

    /**
     * A server allocated without construction that holds only a structure template manager, which
     * loads templates from the vanilla data pack (kept open) as a server's does and caches them.
     */
    static synchronized net.minecraft.server.MinecraftServer templateServer() throws ReflectiveOperationException {
      if (TEMPLATE_SERVER == null) {
        var f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
        f.setAccessible(true);
        var unsafe = (sun.misc.Unsafe) f.get(null);
        var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
            List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()));
        var managerClass = net.minecraft.world.level.levelgen.structure.templatesystem.StructureTemplateManager.class;
        var manager = unsafe.allocateInstance(managerClass);
        var templates = new net.minecraft.world.level.levelgen.structure.templatesystem.loader.ResourceManagerTemplateSource(
            net.minecraft.util.datafix.DataFixers.getDataFixer(), net.minecraft.core.registries.BuiltInRegistries.BLOCK, resources,
            new net.minecraft.resources.FileToIdConverter("structure", ".nbt"));
        set(manager, managerClass, "structureRepository", new java.util.concurrent.ConcurrentHashMap<>());
        set(manager, managerClass, "resourceManagerSource", templates);
        set(manager, managerClass, "sources", List.of(templates));
        var server = unsafe.allocateInstance(net.minecraft.server.dedicated.DedicatedServer.class);
        set(server, net.minecraft.server.MinecraftServer.class, "structureTemplateManager", manager);
        // The End spikes create their crystals through the level, which asks the server's world
        // data for its enabled features (VMC-026a).
        set(server, net.minecraft.server.MinecraftServer.class, "worldData", Proxy.newProxyInstance(
            DecorationOracle.class.getClassLoader(), new Class<?>[] {net.minecraft.world.level.storage.WorldData.class},
            (proxy, method, a) -> switch (method.getName()) {
              case "enabledFeatures" -> FeatureFlags.DEFAULT_FLAGS;
              default -> throw new UnsupportedOperationException("WorldData." + method.getName());
            }));
        TEMPLATE_SERVER = (net.minecraft.server.MinecraftServer) server;
      }
      return TEMPLATE_SERVER;
    }

    static void set(Object target, Class<?> owner, String name, Object value) throws ReflectiveOperationException {
      var field = owner.getDeclaredField(name);
      field.setAccessible(true);
      field.set(target, value);
    }

    static UnsupportedOperationException unsupported(String what) {
      return new UnsupportedOperationException("WorldGenLevel." + what);
    }

    public boolean isOldChunkAround(ChunkPos pos, int range) { return false; }
    @Override public void setCurrentlyGenerating(java.util.function.Supplier<String> currentlyGenerating) {}
    @Override public ChunkAccess getChunk(int chunkX, int chunkZ) { return chunk(chunkX, chunkZ); }
    @Override public ChunkAccess getChunk(int x, int z, ChunkStatus status, boolean loadOrGenerate) {
      var allowed = distance(x, z) <= 1 ? ChunkStatus.TERRAIN : distance(x, z) <= 8 ? ChunkStatus.STRUCTURE_STARTS : null;
      if (allowed != null && status.isOrBefore(allowed)) return chunk(x, z);
      throw new IllegalStateException("Requested chunk unavailable during world generation: " + x + ", " + z + " " + status);
    }
    @Override public boolean hasChunk(int chunkX, int chunkZ) { return distance(chunkX, chunkZ) <= 8; }
    @Override public BlockState getBlockState(BlockPos pos) { return chunk(pos).getBlockState(pos); }
    @Override public net.minecraft.world.level.material.FluidState getFluidState(BlockPos pos) { return chunk(pos).getFluidState(pos); }
    @Override public net.minecraft.world.entity.player.Player getNearestPlayer(double x, double y, double z, double maxDist,
        java.util.function.Predicate<net.minecraft.world.entity.Entity> predicate) { return null; }
    @Override public int getSkyDarken() { return 0; }
    @Override public BiomeManager getBiomeManager() { return biomeManager; }
    @Override public Holder<Biome> getUncachedNoiseBiome(int quartX, int quartY, int quartZ) {
      return biomeSource.createResolver(state.createClimateSampler(
          net.minecraft.world.level.levelgen.densityfunction.SamplerContext.builder().build())).getNoiseBiome(quartX, quartY, quartZ);
    }
    @Override public net.minecraft.world.level.lighting.LevelLightEngine getLightEngine() { return lightEngine; }
    @Override public boolean destroyBlock(BlockPos pos, boolean dropResources, net.minecraft.world.entity.Entity breaker, int updateLimit) {
      var blockState = getBlockState(pos);
      return blockState.isAir() ? false : setBlock(pos, Blocks.AIR.defaultBlockState(), 3, updateLimit);
    }
    @Override public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos pos) {
      var chunk = chunk(pos);
      var blockEntity = chunk.getBlockEntity(pos);
      if (blockEntity != null) return blockEntity;
      var tag = chunk.getBlockEntityNbt(pos);
      var blockState = chunk.getBlockState(pos);
      if (tag != null && "DUMMY".equals(tag.getStringOr("id", "")) && blockState.hasBlockEntity()) {
        blockEntity = ((EntityBlock) blockState.getBlock()).newBlockEntity(pos, blockState);
        if (blockEntity != null) {
          chunk.setBlockEntity(blockEntity);
          return blockEntity;
        }
      }
      if (tag != null) throw unsupported("getBlockEntity of " + tag);
      return null;
    }
    @Override public boolean ensureCanWrite(BlockPos pos) {
      return distance(SectionPos.blockToSectionCoord(pos.getX()), SectionPos.blockToSectionCoord(pos.getZ())) <= 1;
    }
    @Override public boolean setBlock(BlockPos pos, BlockState blockState, int flags, int updateLimit) {
      if (!ensureCanWrite(pos)) return false;
      var chunk = chunk(pos);
      var oldState = chunk.setBlockState(pos, blockState, flags);
      if (blockState.hasBlockEntity()) {
        var tag = new CompoundTag();
        tag.putInt("x", pos.getX());
        tag.putInt("y", pos.getY());
        tag.putInt("z", pos.getZ());
        tag.putString("id", "DUMMY");
        chunk.setBlockEntityNbt(tag);
      } else if (oldState != null && oldState.hasBlockEntity()) {
        chunk.removeBlockEntity(pos);
      }
      if ((flags & 16) == 0) {
        var postProcessPos = blockState.getPostProcessPos(this, pos);
        if (postProcessPos != null) chunk(postProcessPos).markPosForPostProcessing(postProcessPos);
      }
      return true;
    }
    @Override public boolean removeBlock(BlockPos pos, boolean movedByPiston) { return setBlock(pos, Blocks.AIR.defaultBlockState(), 3); }
    // `WorldGenRegion.addFreshEntity`: into the chunk at the entity's block position (the End
    // spikes' crystals); recorded as type, position and yaw.
    @Override public boolean addFreshEntity(net.minecraft.world.entity.Entity entity) {
      var chunk = chunk(SectionPos.blockToSectionCoord(entity.getBlockX()), SectionPos.blockToSectionCoord(entity.getBlockZ()));
      ENTITIES.computeIfAbsent(chunk, c -> new ArrayList<>()).add(
          net.minecraft.core.registries.BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()) + "," + entity.getX() + ","
              + entity.getY() + "," + entity.getZ() + "," + entity.getYRot());
      return true;
    }
    @Override public net.minecraft.world.level.border.WorldBorder getWorldBorder() { throw unsupported("getWorldBorder"); }
    @Override public boolean isClientSide() { return false; }
    net.minecraft.server.level.ServerLevel serverLevel;
    net.minecraft.world.level.chunk.ChunkGenerator generator;
    // Only trees' pale moss decorator asks, for the generator it hands its moss patch: a level
    // allocated without construction whose chunk source holds just the generator.
    @Override public net.minecraft.server.level.ServerLevel getLevel() {
      if (serverLevel == null) serverLevel = generatorOnlyLevel(generator);
      return serverLevel;
    }
    @Override public net.minecraft.core.RegistryAccess registryAccess() { return registries; }
    @Override public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return FeatureFlags.DEFAULT_FLAGS; }
    @Override public LevelData getLevelData() { return levelData; }
    @Override public net.minecraft.world.DifficultyInstance getCurrentDifficultyAt(BlockPos pos) { throw unsupported("getCurrentDifficultyAt"); }
    @Override public net.minecraft.server.MinecraftServer getServer() { throw unsupported("getServer"); }
    @Override public net.minecraft.world.level.chunk.ChunkSource getChunkSource() { throw unsupported("getChunkSource"); }
    @Override public long getSeed() { return seed; }
    @Override public net.minecraft.world.ticks.LevelTickAccess<Block> getBlockTicks() { return blockTicks; }
    @Override public net.minecraft.world.ticks.LevelTickAccess<net.minecraft.world.level.material.Fluid> getFluidTicks() { return fluidTicks; }
    @Override public int getSeaLevel() { return SEA_LEVEL; }
    @Override public net.minecraft.util.RandomSource getRandom() { return random; }
    @Override public int getHeight(Heightmap.Types type, int x, int z) {
      return chunk(SectionPos.blockToSectionCoord(x), SectionPos.blockToSectionCoord(z)).getHeight(type, x & 15, z & 15) + 1;
    }
    @Override public void playSound(net.minecraft.world.entity.Entity except, BlockPos pos, net.minecraft.sounds.SoundEvent sound,
        net.minecraft.sounds.SoundSource source, float volume, float pitch) {}
    @Override public void addParticle(net.minecraft.core.particles.ParticleOptions particle, double x, double y, double z,
        double xd, double yd, double zd) {}
    @Override public void levelEvent(net.minecraft.world.entity.Entity source, int type, BlockPos pos, int data) {}
    @Override public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> gameEvent, net.minecraft.world.phys.Vec3 position,
        net.minecraft.world.level.gameevent.GameEvent.Context context) {}
    @Override public net.minecraft.world.level.dimension.DimensionType dimensionType() {
      return lookup.lookupOrThrow(Registries.DIMENSION_TYPE).getOrThrow(TYPE).value();
    }
    @Override public boolean isStateAtPosition(BlockPos pos, java.util.function.Predicate<BlockState> predicate) {
      return predicate.test(getBlockState(pos));
    }
    @Override public boolean isFluidAtPosition(BlockPos pos, java.util.function.Predicate<net.minecraft.world.level.material.FluidState> predicate) {
      return predicate.test(getFluidState(pos));
    }
    @Override public <T extends net.minecraft.world.entity.Entity> List<T> getEntities(
        net.minecraft.world.level.entity.EntityTypeTest<net.minecraft.world.entity.Entity, T> type, net.minecraft.world.phys.AABB bb,
        java.util.function.Predicate<? super T> selector) { return Collections.emptyList(); }
    @Override public List<net.minecraft.world.entity.Entity> getEntities(net.minecraft.world.entity.Entity except, net.minecraft.world.phys.AABB bb,
        java.util.function.Predicate<? super net.minecraft.world.entity.Entity> selector) { return Collections.emptyList(); }
    @Override public List<net.minecraft.world.entity.player.Player> players() { return Collections.emptyList(); }
    @Override public int getMinY() { return MIN_Y; }
    @Override public int getHeight() { return HEIGHT; }
    @Override public long nextSubTickCount() { return subTickCount++; }
    @Override public net.minecraft.world.attribute.EnvironmentAttributeReader environmentAttributes() { throw unsupported("environmentAttributes"); }
  }
}
