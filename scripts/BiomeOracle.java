import com.google.gson.*;
import java.io.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.nbt.NbtIo;
import net.minecraft.resources.ResourceKey;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.Climate;
import net.minecraft.world.level.biome.MultiNoiseBiomeSourceParameterList;
import net.minecraft.world.level.chunk.LevelChunkSection;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.chunk.storage.RegionFile;
import net.minecraft.world.level.chunk.storage.RegionStorageInfo;
import net.minecraft.world.level.chunk.storage.SerializableChunkData;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.densityfunction.DensityBuffer;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;
import net.minecraft.world.level.levelgen.densityfunction.SamplerContext;

/**
 * Overworld chunk biomes (VMC-023d). `generate DIR OUT` runs the pinned server
 * at seed 20261020 into DIR (a 16×16-chunk force-loaded area) and records, for
 * every full chunk in region-file order:
 *
 * - `world`: the 1,536 biomes vanilla stored (sections from the bottom, each in
 *   index order y, z, x), as palette indices;
 * - `reference`: the biomes vanilla's own code gives on one thread, chunk after
 *   chunk in the same order: the climate sampler over the chunk's quart volume
 *   in a cached context, then `findValue` per quart in section fill order;
 * - `targets`: a SHA-256 of the reference's climate targets (six big-endian
 *   longs per lookup, in lookup order).
 *
 * The world's chunks were filled on worker threads, so where biomes tie on
 * climate distance their lookup history differs from the reference's.
 * After the world's chunks follow 300 chunks scattered up to 30,000,000 blocks
 * away with only the reference and targets, for broader climate coverage.
 *
 * `bench OUT` times the same chunk biome fill on one thread for 256 fixed
 * chunks (eight warm-up passes, then ten timed passes) and writes the chunk
 * list and per-pass nanoseconds, for `bench/worldgen_biomes.exs`.
 */
public class BiomeOracle {
  public static void main(String[] args) throws Exception {
    if (args[0].equals("bench")) {
      bench(Path.of(args[1]));
      return;
    }
    var factory = ChunkOracle.factory();
    var dir = Path.of(args[1]);
    WorldNbtOracle.runServer(dir, Map.of(), List.of("forceload add ~-128 ~-128 ~127 ~127", "#sleep 25000"));
    var regionDir = dir.resolve("universe/w/dimensions/minecraft/overworld/region");
    List<Path> files;
    try (var list = Files.list(regionDir)) { files = list.filter(p -> p.toString().endsWith(".mca")).sorted().toList(); }

    var palette = new ArrayList<String>();
    var paletteIndex = new HashMap<String, Integer>();
    var lookup = VanillaRegistries.createWorldLookup();
    var settings = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(NoiseGeneratorSettings.OVERWORLD).value();
    var state = RandomState.create(lookup.lookupOrThrow(Registries.NOISE), 20261020L, settings);
    var parameters = MultiNoiseBiomeSourceParameterList.knownPresets().get(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD);

    var chunks = new JsonArray();
    var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
    int full = 0;
    for (var file : files) {
      var copy = Files.createTempDirectory("valimc-biomes");
      Files.copy(file, copy.resolve(file.getFileName()));
      var name = file.getFileName().toString().split("\\.");
      int rx = Integer.parseInt(name[1]), rz = Integer.parseInt(name[2]);
      try (var region = new RegionFile(info, copy.resolve(file.getFileName()), copy, false)) {
        for (int index = 0; index < 1024; index++) {
          var pos = new ChunkPos(rx * 32 + (index & 31), rz * 32 + (index >> 5));
          CompoundTag tag;
          try (var stream = region.getChunkDataInputStream(pos)) {
            if (stream == null) continue;
            tag = NbtIo.read(stream);
          }
          if (SerializableChunkData.getChunkStatusFromTag(tag) != ChunkStatus.FULL) continue;
          full++;
          var data = SerializableChunkData.parse(ChunkOracle.HEIGHT, factory, tag);
          var byY = new HashMap<Integer, LevelChunkSection>();
          for (var section : data.sectionData()) if (section.chunkSection() != null) byY.put(section.y(), section.chunkSection());
          var world = new StringBuilder();
          for (int sy = -4; sy < 20; sy++) {
            var section = byY.get(sy);
            if (section == null) throw new IllegalStateException("full chunk " + pos + " lacks section " + sy);
            var biomes = section.getBiomes();
            for (int y = 0; y < 4; y++)
              for (int z = 0; z < 4; z++)
                for (int x = 0; x < 4; x++)
                  world.append(hex(index(palette, paletteIndex, biomes.get(x, y, z).unwrapKey().orElseThrow().identifier().toString())));
          }

          var row = reference(state, parameters, pos, palette, paletteIndex);
          row.addProperty("world", world.toString());
          chunks.add(row);
        }
      }
    }
    if (full < 100) throw new IllegalStateException("too few full chunks: " + full);
    var gen = new Random(20261020L);
    for (int i = 0; i < 300; i++) {
      int range = i % 3 == 0 ? 1_875_000 : 20_000;
      chunks.add(reference(state, parameters, new ChunkPos(gen.nextInt(2 * range + 1) - range, gen.nextInt(2 * range + 1) - range),
          palette, paletteIndex));
    }
    var facts = new JsonObject();
    facts.add("biomes", new Gson().toJsonTree(palette));
    facts.add("chunks", chunks);
    Files.writeString(Path.of(args[2]), new Gson().toJson(facts));
    System.out.println("PASS: " + full + " full overworld chunks at seed 20261020 with stored and single-thread reference biomes, "
        + "300 scattered reference chunks (" + palette.size() + " biomes)");
  }

  /** Vanilla's biomes for a chunk on this thread, continuing its lookup history. */
  static JsonObject reference(RandomState state, Climate.ParameterList<ResourceKey<Biome>> parameters,
      ChunkPos pos, List<String> palette, Map<String, Integer> paletteIndex) throws Exception {
    var digest = MessageDigest.getInstance("SHA-256");
    var targetBytes = new ByteArrayOutputStream();
    var reference = fill(state, parameters, pos, new DataOutputStream(targetBytes));
    var referenceText = new StringBuilder();
    for (var biome : reference) referenceText.append(hex(index(palette, paletteIndex, biome.identifier().toString())));
    var row = new JsonObject();
    row.addProperty("x", pos.x());
    row.addProperty("z", pos.z());
    row.addProperty("reference", referenceText.toString());
    row.addProperty("targets", HexFormat.of().formatHex(digest.digest(targetBytes.toByteArray())));
    return row;
  }

  /**
   * Chunk biome fill as vanilla's chunk generation does it; climate targets go
   * to `targets` unless it is null.
   */
  @SuppressWarnings("unchecked")
  static ResourceKey<Biome>[] fill(RandomState state, Climate.ParameterList<ResourceKey<Biome>> parameters, ChunkPos pos,
      DataOutputStream targets) throws IOException {
    var volume = new DensityVolume(4, 96, 4, pos.getMinBlockX(), -64, pos.getMinBlockZ(), 4, 4, 4);
    var climate = state.createClimateSampler(SamplerContext.builder().enableCaches().build());
    var bound = List.of(climate.temperature(), climate.humidity(), climate.continentalness(), climate.erosion(), climate.depth(), climate.weirdness());
    var buffers = new ArrayList<DensityBuffer>();
    for (var sampler : bound) {
      var buffer = DensityBuffer.createUnpooled(volume.size());
      sampler.sampleVolume(buffer, volume);
      buffers.add(buffer);
    }
    var reference = (ResourceKey<Biome>[]) new ResourceKey[24 * 64];
    for (int s = 0; s < 24; s++)
      for (int x = 0; x < 4; x++)
        for (int y = 0; y < 4; y++)
          for (int z = 0; z < 4; z++) {
            int i = volume.indexUnchecked(x, s * 4 + y, z);
            var target = Climate.target(buffers.get(0).get(i), buffers.get(1).get(i), buffers.get(2).get(i),
                buffers.get(3).get(i), buffers.get(4).get(i), buffers.get(5).get(i));
            if (targets != null)
              for (long v : new long[] {target.temperature(), target.humidity(), target.continentalness(),
                  target.erosion(), target.depth(), target.weirdness()}) targets.writeLong(v);
            reference[s * 64 + (y * 4 + z) * 4 + x] = parameters.findValue(target);
          }
    return reference;
  }

  static void bench(Path out) throws Exception {
    MiningToolOracle.initialize();
    var lookup = VanillaRegistries.createWorldLookup();
    var settings = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(NoiseGeneratorSettings.OVERWORLD).value();
    var state = RandomState.create(lookup.lookupOrThrow(Registries.NOISE), 20261020L, settings);
    var parameters = MultiNoiseBiomeSourceParameterList.knownPresets().get(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD);
    var gen = new Random(7L);
    var chunks = new ArrayList<ChunkPos>();
    for (int i = 0; i < 256; i++) chunks.add(new ChunkPos(gen.nextInt(40_001) - 20_000, gen.nextInt(40_001) - 20_000));
    var passes = new JsonArray();
    for (int pass = 0; pass < 18; pass++) {
      long start = System.nanoTime();
      for (var pos : chunks) fill(state, parameters, pos, null);
      long elapsed = System.nanoTime() - start;
      if (pass >= 8) passes.add(elapsed);
    }
    var result = new JsonObject();
    var list = new JsonArray();
    for (var pos : chunks) { var p = new JsonArray(); p.add(pos.x()); p.add(pos.z()); list.add(p); }
    result.add("chunks", list);
    result.add("vanilla_pass_ns", passes);
    result.addProperty("java", System.getProperty("java.vm.name") + " " + System.getProperty("java.version"));
    Files.writeString(out, new Gson().toJson(result));
    var sorted = new ArrayList<Long>();
    passes.forEach(e -> sorted.add(e.getAsLong()));
    Collections.sort(sorted);
    System.out.println("PASS: vanilla chunk biome fill, 256 chunks per pass, median " + sorted.get(sorted.size() / 2) / 256_000 + " µs per chunk");
  }

  static int index(List<String> palette, Map<String, Integer> indices, String biome) {
    return indices.computeIfAbsent(biome, b -> { palette.add(b); return palette.size() - 1; });
  }

  static String hex(int index) {
    if (index > 255) throw new IllegalStateException("biome palette over 256 entries");
    return String.format("%02x", index);
  }
}
