import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.core.HolderGetter;
import net.minecraft.resources.ResourceKey;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeManager;
import net.minecraft.world.level.biome.BiomeResolver;
import net.minecraft.world.level.biome.Climate;
import net.minecraft.world.level.biome.MultiNoiseBiomeSourceParameterList;
import net.minecraft.world.level.biome.TheEndBiomeSource;
import net.minecraft.world.level.levelgen.densityfunction.DensityBuffer;
import net.minecraft.world.level.levelgen.densityfunction.SamplerContext;
import net.minecraft.world.level.levelgen.material.rule.MaterialRule;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.biome.Biomes;
import net.minecraft.server.level.WorldGenRegion;
import net.minecraft.world.level.biome.BiomeSource;
import net.minecraft.world.level.biome.MultiNoiseBiomeSource;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.chunk.UpgradeData;
import net.minecraft.world.level.levelgen.Aquifer;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;

/**
 * Vanilla terrain (VMC-024). `fill OUT`: for three seeds and every noise
 * settings entry, eight chunks (two next to the origin, five within 32,000
 * blocks, one up to 30,000,000 blocks away) are filled by vanilla's own
 * `NoiseBasedChunkGenerator.doFill` on a fresh proto chunk, with a noise chunk
 * built as chunk generation builds it but without structures (no beardifier)
 * or blending. `surface OUT` then runs vanilla's `buildSurface` with the
 * settings' material rule through the same noise chunk; its biome manager
 * reads chunk biomes filled as chunk generation fills them (multi-noise
 * presets: overworld, or nether for the nether settings; the End's biome
 * source for the end settings), each chunk from a fresh lookup history.
 * `carve OUT` then runs vanilla's `generateCarvers` for the chunk; the
 * generator's biome source (carver biomes, biomes for grass over carved dirt)
 * starts every lookup from a fresh lookup history. Per chunk: the state ids
 * run-length encoded in volume order (Y fastest from the bottom, then X, then
 * Z) as [id, count] pairs, and the positions marked for fluid
 * post-processing.
 *
 * `bench OUT [overworld|nether|end X0 Z0]` times vanilla's noise fill
 * (`doFill` on a fresh noise chunk) on one thread for the 64 chunks of one
 * 8 × 8 area at seed 20261020 (the overworld's from (0, 0) unless named;
 * eight warm-up and ten timed passes), and the same chunks through
 * `buildTerrain`'s fill, surface and carver steps (without a world region,
 * so carver biomes are looked up per chunk), for `bench/worldgen_terrain.exs`.
 */
public class TerrainOracle {
  public static void main(String[] args) throws Exception {
    if (args[0].equals("bench")) {
      String dimension = args.length > 2 ? args[2] : "overworld";
      int x0 = args.length > 4 ? Integer.parseInt(args[3]) : 0;
      int z0 = args.length > 4 ? Integer.parseInt(args[4]) : 0;
      bench(Path.of(args[1]), dimension, x0, z0);
      return;
    }
    var factory = ChunkOracle.factory();
    var lookup = VanillaRegistries.createWorldLookup();
    var noises = lookup.lookupOrThrow(Registries.NOISE);
    var plains = lookup.lookupOrThrow(Registries.BIOME).getOrThrow(Biomes.PLAINS);
    var settingsList = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).toList();
    boolean carve = args[0].equals("carve");
    boolean surface = carve || args[0].equals("surface");
    var doFill = NoiseBasedChunkGenerator.class.getDeclaredMethod("doFill", NoiseChunk.class, ChunkAccess.class);
    doFill.setAccessible(true);
    var buildSurface = NoiseBasedChunkGenerator.class.getDeclaredMethod("buildSurface", ChunkAccess.class, NoiseChunk.class,
        RandomState.class, BiomeManager.class, Set.class, MaterialRule.class);
    buildSurface.setAccessible(true);
    var generateCarvers = NoiseBasedChunkGenerator.class.getDeclaredMethod("generateCarvers", ChunkAccess.class, Blender.class,
        NoiseChunk.class, RandomState.class, BiomeManager.class, WorldGenRegion.class, MaterialRule.class);
    generateCarvers.setAccessible(true);
    var biomeLookup = lookup.lookupOrThrow(Registries.BIOME);
    var createFluidPicker = NoiseBasedChunkGenerator.class.getDeclaredMethod("createFluidPicker", NoiseGeneratorSettings.class);
    createFluidPicker.setAccessible(true);
    var gen = new Random(20261020L);
    long[] seeds = {20261020L, -8172645723L, gen.nextLong()};
    var cases = new JsonArray();
    long blocks = 0;

    for (long seed : seeds) {
      for (var holder : settingsList) {
        var settings = holder.value();
        var state = RandomState.create(noises, seed, settings);
        var settingsId = holder.key().identifier().toString();
        BiomeSource biomeSource = settingsId.equals("minecraft:end")
            ? TheEndBiomeSource.create(biomeLookup)
            : MultiNoiseBiomeSource.createFromList(freshList(settingsId.equals("minecraft:nether")
                ? MultiNoiseBiomeSourceParameterList.Preset.NETHER : MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD, biomeLookup));
        var generator = new NoiseBasedChunkGenerator(biomeSource, holder);
        var picker = (Aquifer.FluidPicker) createFluidPicker.invoke(null, settings);
        int minY = settings.noiseSettings().minY(), height = settings.noiseSettings().height();
        var heights = LevelHeightAccessor.create(minY, height);
        var positions = new ArrayList<>(List.of(new ChunkPos(0, 0), new ChunkPos(-1, 2)));
        for (int i = 0; i < 5; i++) positions.add(new ChunkPos(gen.nextInt(4001) - 2000, gen.nextInt(4001) - 2000));
        positions.add(new ChunkPos(gen.nextInt(3_750_001) - 1_875_000, gen.nextInt(3_750_001) - 1_875_000));
        for (var pos : positions) {
          var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, heights, factory, null);
          var volume = new DensityVolume(16, height, 16, pos.getMinBlockX(), minY, pos.getMinBlockZ());
          try (var noiseChunk = new NoiseChunk(state, null, settings, picker, Blender.empty(), volume)) {
            doFill.invoke(generator, noiseChunk, chunk);
            if (surface) {
              var id = holder.key().identifier().toString();
              var source = id.equals("minecraft:end") ? "end" : id.equals("minecraft:nether") ? "nether" : "overworld";
              var biomes = new HashMap<ChunkPos, Holder<Biome>[]>();
              BiomeResolver resolver = (qx, qy, qz) -> {
                var column = biomes.computeIfAbsent(new ChunkPos(qx >> 2, qz >> 2),
                    p -> chunkBiomes(state, source, biomeLookup, p, minY, height));
                int minQuart = minY >> 2;
                int clamped = Math.clamp(qy, minQuart, minQuart + (height >> 2) - 1) - minQuart;
                return column[(clamped >> 2) * 64 + ((clamped & 3) * 4 + (qz & 3)) * 4 + (qx & 3)];
              };
              var biomeManager = new BiomeManager(resolver, BiomeManager.obfuscateSeed(seed));
              buildSurface.invoke(generator, chunk, noiseChunk, state, biomeManager, null, settings.materialRule().value());
              if (carve) {
                generateCarvers.invoke(generator, chunk, Blender.empty(), noiseChunk, state, biomeManager, null,
                    settings.materialRule().value());
              }
            }
          }
          var runs = new JsonArray();
          int last = -1, count = 0;
          var cursor = new BlockPos.MutableBlockPos();
          for (int z = 0; z < 16; z++)
            for (int x = 0; x < 16; x++)
              for (int y = 0; y < height; y++) {
                int id = Block.getId(chunk.getBlockState(cursor.set(pos.getMinBlockX() + x, minY + y, pos.getMinBlockZ() + z)));
                if (id != last && count > 0) {
                  runs.add(last);
                  runs.add(count);
                  count = 0;
                }
                last = id;
                count++;
                blocks++;
              }
          runs.add(last);
          runs.add(count);
          var updates = new TreeSet<String>();
          var lists = chunk.getPostProcessing();
          for (int i = 0; i < lists.length; i++) {
            if (lists[i] == null) continue;
            for (short packed : lists[i]) {
              var p = ProtoChunk.unpackOffsetCoordinates(packed, chunk.getSectionYFromSectionIndex(i), pos);
              updates.add(p.getX() + "," + p.getY() + "," + p.getZ());
            }
          }
          var row = new JsonObject();
          row.addProperty("seed", Long.toString(seed));
          row.addProperty("settings", holder.key().identifier().toString());
          row.addProperty("x", pos.x());
          row.addProperty("z", pos.z());
          row.add("runs", runs);
          row.add("fluid_updates", new Gson().toJsonTree(updates));
          cases.add(row);
        }
      }
    }
    var out = new JsonObject();
    out.add("cases", cases);
    Files.writeString(Path.of(args[1]), new Gson().toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla " + (carve ? "carved" : surface ? "surfaced" : "noise-filled") + " chunks over "
        + seeds.length + " seeds and " + settingsList.size() + " noise settings (" + blocks + " blocks)");
  }

  /**
   * A chunk's biomes (sections from the bottom, each in index order y, z, x)
   * as chunk generation fills them, from a fresh lookup history.
   */
  @SuppressWarnings("unchecked")
  static Holder<Biome>[] chunkBiomes(RandomState state, String source, HolderGetter<Biome> lookup, ChunkPos pos, int minY,
      int height) {
    int sections = height / 16;
    var out = (Holder<Biome>[]) new Holder[sections * 64];
    var climate = state.createClimateSampler(SamplerContext.builder().enableCaches().build());
    if (source.equals("end")) {
      var resolver = TheEndBiomeSource.create(lookup).createResolver(climate);
      for (int s = 0; s < sections; s++)
        for (int x = 0; x < 4; x++)
          for (int y = 0; y < 4; y++)
            for (int z = 0; z < 4; z++)
              out[s * 64 + (y * 4 + z) * 4 + x] = resolver.getNoiseBiome(pos.x() * 4 + x, (minY >> 2) + s * 4 + y, pos.z() * 4 + z);
      return out;
    }
    var preset = source.equals("nether") ? MultiNoiseBiomeSourceParameterList.Preset.NETHER : MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD;
    var parameters = PRESETS.computeIfAbsent(preset, p -> MultiNoiseBiomeSourceParameterList.knownPresets().get(p));
    resetHistory(parameters);
    var volume = new DensityVolume(4, height / 4, 4, pos.getMinBlockX(), minY, pos.getMinBlockZ(), 4, 4, 4);
    var bound = List.of(climate.temperature(), climate.humidity(), climate.continentalness(), climate.erosion(), climate.depth(), climate.weirdness());
    var buffers = new ArrayList<DensityBuffer>();
    for (var sampler : bound) {
      var buffer = DensityBuffer.createUnpooled(volume.size());
      sampler.sampleVolume(buffer, volume);
      buffers.add(buffer);
    }
    for (int s = 0; s < sections; s++)
      for (int x = 0; x < 4; x++)
        for (int y = 0; y < 4; y++)
          for (int z = 0; z < 4; z++) {
            int i = volume.indexUnchecked(x, s * 4 + y, z);
            var target = Climate.target(buffers.get(0).get(i), buffers.get(1).get(i), buffers.get(2).get(i),
                buffers.get(3).get(i), buffers.get(4).get(i), buffers.get(5).get(i));
            out[s * 64 + (y * 4 + z) * 4 + x] = lookup.getOrThrow(parameters.findValue(target));
          }
    return out;
  }

  static final Map<MultiNoiseBiomeSourceParameterList.Preset, Climate.ParameterList<ResourceKey<Biome>>> PRESETS = new HashMap<>();

  static void bench(Path out, String dimension, int x0, int z0) throws Exception {
    var factory = ChunkOracle.factory();
    var lookup = VanillaRegistries.createWorldLookup();
    var biomeLookup = lookup.lookupOrThrow(Registries.BIOME);
    var key = switch (dimension) {
      case "nether" -> NoiseGeneratorSettings.NETHER;
      case "end" -> NoiseGeneratorSettings.END;
      default -> NoiseGeneratorSettings.OVERWORLD;
    };
    var holder = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(key);
    var settings = holder.value();
    long seed = 20261020L;
    var state = RandomState.create(lookup.lookupOrThrow(Registries.NOISE), seed, settings);
    BiomeSource biomeSource = switch (dimension) {
      case "end" -> TheEndBiomeSource.create(biomeLookup);
      case "nether" -> MultiNoiseBiomeSource.createFromList(freshList(MultiNoiseBiomeSourceParameterList.Preset.NETHER, biomeLookup));
      default -> MultiNoiseBiomeSource.createFromList(freshList(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD, biomeLookup));
    };
    var generator = new NoiseBasedChunkGenerator(biomeSource, holder);
    int minY = settings.noiseSettings().minY(), height = settings.noiseSettings().height();
    var doFill = NoiseBasedChunkGenerator.class.getDeclaredMethod("doFill", NoiseChunk.class, ChunkAccess.class);
    doFill.setAccessible(true);
    var buildSurface = NoiseBasedChunkGenerator.class.getDeclaredMethod("buildSurface", ChunkAccess.class, NoiseChunk.class,
        RandomState.class, BiomeManager.class, Set.class, MaterialRule.class);
    buildSurface.setAccessible(true);
    var generateCarvers = NoiseBasedChunkGenerator.class.getDeclaredMethod("generateCarvers", ChunkAccess.class, Blender.class,
        NoiseChunk.class, RandomState.class, BiomeManager.class, WorldGenRegion.class, MaterialRule.class);
    generateCarvers.setAccessible(true);
    var createFluidPicker = NoiseBasedChunkGenerator.class.getDeclaredMethod("createFluidPicker", NoiseGeneratorSettings.class);
    createFluidPicker.setAccessible(true);
    var picker = (Aquifer.FluidPicker) createFluidPicker.invoke(null, settings);
    var heights = LevelHeightAccessor.create(minY, height);
    var chunks = new ArrayList<ChunkPos>();
    for (int x = x0; x < x0 + 8; x++) for (int z = z0; z < z0 + 8; z++) chunks.add(new ChunkPos(x, z));
    var biomes = new HashMap<ChunkPos, Holder<Biome>[]>();
    BiomeResolver resolver = (qx, qy, qz) -> {
      var column = biomes.computeIfAbsent(new ChunkPos(qx >> 2, qz >> 2), p -> chunkBiomes(state, dimension, biomeLookup, p, minY, height));
      int minQuart = minY >> 2;
      int clamped = Math.clamp(qy, minQuart, minQuart + (height >> 2) - 1) - minQuart;
      return column[(clamped >> 2) * 64 + ((clamped & 3) * 4 + (qz & 3)) * 4 + (qx & 3)];
    };
    var biomeManager = new BiomeManager(resolver, BiomeManager.obfuscateSeed(seed));
    var fillPasses = new JsonArray();
    var terrainPasses = new JsonArray();
    for (int pass = 0; pass < 18; pass++) {
      long start = System.nanoTime();
      for (var pos : chunks) {
        var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, heights, factory, null);
        var volume = new DensityVolume(16, height, 16, pos.getMinBlockX(), minY, pos.getMinBlockZ());
        try (var noiseChunk = new NoiseChunk(state, null, settings, picker, Blender.empty(), volume)) {
          doFill.invoke(generator, noiseChunk, chunk);
        }
      }
      long fill = System.nanoTime() - start;
      start = System.nanoTime();
      for (var pos : chunks) {
        var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, heights, factory, null);
        var volume = new DensityVolume(16, height, 16, pos.getMinBlockX(), minY, pos.getMinBlockZ());
        try (var noiseChunk = new NoiseChunk(state, null, settings, picker, Blender.empty(), volume)) {
          doFill.invoke(generator, noiseChunk, chunk);
          buildSurface.invoke(generator, chunk, noiseChunk, state, biomeManager, null, settings.materialRule().value());
          generateCarvers.invoke(generator, chunk, Blender.empty(), noiseChunk, state, biomeManager, null, settings.materialRule().value());
        }
      }
      long terrain = System.nanoTime() - start;
      if (pass >= 8) {
        fillPasses.add(fill);
        terrainPasses.add(terrain);
      }
    }
    var result = new JsonObject();
    var list = new JsonArray();
    for (var pos : chunks) { var p = new JsonArray(); p.add(pos.x()); p.add(pos.z()); list.add(p); }
    result.add("chunks", list);
    result.addProperty("dimension", dimension);
    result.addProperty("noise_settings", key.identifier().toString());
    result.addProperty("biome_source", dimension.equals("end") ? "minecraft:the_end" : "minecraft:" + dimension);
    result.addProperty("height", height);
    result.add("vanilla_fill_ns", fillPasses);
    result.add("vanilla_terrain_ns", terrainPasses);
    result.addProperty("java", System.getProperty("java.vm.name") + " " + System.getProperty("java.version"));
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: vanilla noise fill and terrain timings for 64 " + dimension + " chunks");
  }

  /** A preset's parameter list whose every lookup starts from a fresh lookup history. */
  static Climate.ParameterList<Holder<Biome>> freshList(MultiNoiseBiomeSourceParameterList.Preset preset, HolderGetter<Biome> lookup) {
    var values = new ArrayList<com.mojang.datafixers.util.Pair<Climate.ParameterPoint, Holder<Biome>>>();
    for (var pair : MultiNoiseBiomeSourceParameterList.knownPresets().get(preset).values()) {
      values.add(com.mojang.datafixers.util.Pair.of(pair.getFirst(), lookup.getOrThrow(pair.getSecond())));
    }
    return new FreshList<>(values);
  }

  static class FreshList<T> extends Climate.ParameterList<T> {
    FreshList(List<com.mojang.datafixers.util.Pair<Climate.ParameterPoint, T>> values) {
      super(values);
    }

    @Override
    public T findValue(Climate.TargetPoint target) {
      resetHistory(this);
      return super.findValue(target);
    }
  }

  /** Vanilla keeps a parameter list's last lookup result per thread; this forgets it. */
  static void resetHistory(Climate.ParameterList<?> list) {
    try {
      var index = Climate.ParameterList.class.getDeclaredField("index");
      index.setAccessible(true);
      var tree = index.get(list);
      var last = tree.getClass().getDeclaredField("lastResult");
      last.setAccessible(true);
      ((ThreadLocal<?>) last.get(tree)).remove();
    } catch (ReflectiveOperationException e) {
      throw new IllegalStateException(e);
    }
  }
}
