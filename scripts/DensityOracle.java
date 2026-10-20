import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.densityfunction.DensityBuffer;
import net.minecraft.world.level.levelgen.densityfunction.DensityFunction;
import net.minecraft.world.level.levelgen.densityfunction.DensityFunctions;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;
import net.minecraft.world.level.levelgen.densityfunction.SamplerContext;

/**
 * Vanilla density function samples (VMC-023c), as raw float bits. For three
 * seeds and every noise settings entry, every noise router and aquifer
 * function and every `worldgen/density_function` entry is compiled by that
 * settings' `RandomState` and sampled through one sampling context per case:
 *
 * - uncached: points (some far away), a noise-cell volume, a block-step
 *   volume, an odd-step volume and a column;
 * - cached: a noise-cell volume, then points on and off its grid, which read
 *   the cached volume where vanilla does;
 * - climate functions also sample a chunk's quart volume in a cached context,
 *   as chunk biome generation does.
 *
 * Function names: `router:FIELD`, `aquifers:FIELD` or a registry identifier.
 */
public class DensityOracle {
  static final Random gen = new Random(20261020L);
  static final Set<String> CLIMATE = Set.of("temperature", "vegetation", "continents", "erosion", "depth", "ridges");
  static int values = 0;

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
    var noises = lookup.lookupOrThrow(Registries.NOISE);
    var registryFunctions = lookup.lookupOrThrow(Registries.DENSITY_FUNCTION).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).toList();
    var settingsList = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).toList();
    long[] seeds = {20261020L, Long.MIN_VALUE + 7L, gen.nextLong()};
    var cases = new JsonArray();

    for (long seed : seeds) {
      for (var settingsHolder : settingsList) {
        var settings = settingsHolder.value();
        var settingsId = settingsHolder.key().identifier().toString();
        var encoded = NoiseGeneratorSettings.DIRECT_CODEC.encodeStart(ops, settings).getOrThrow().getAsJsonObject();
        var functions = new LinkedHashMap<String, DensityFunction>();
        for (var section : List.of("noise_router", "aquifers")) {
          if (!encoded.has(section)) continue;
          var prefix = section.equals("noise_router") ? "router:" : "aquifers:";
          for (var field : new TreeMap<>(encoded.getAsJsonObject(section).asMap()).entrySet()) {
            functions.put(prefix + field.getKey(), DensityFunction.CODEC.parse(ops, field.getValue()).getOrThrow());
          }
        }
        for (var holder : registryFunctions) {
          functions.put(holder.key().identifier().toString(), new DensityFunctions.HolderHolder(holder));
        }
        var state = RandomState.create(noises, seed, settings);
        int minY = settings.noiseSettings().minY(), height = settings.noiseSettings().height();
        for (var entry : functions.entrySet()) {
          var sampler = state.getSampler(entry.getValue());
          var uncached = new ArrayList<int[]>();
          for (int i = 0; i < 6; i++) uncached.add(new int[] {block(), minY - 8 + gen.nextInt(height + 16), block()});
          uncached.add(cellVolume(3, 5, 3, minY, height));
          uncached.add(new int[] {3, 4, 2, block(), minY + gen.nextInt(height), block(), 1, 1, 1});
          uncached.add(new int[] {2, 3, 2, block(), minY + gen.nextInt(height), block(), 2, 3, 5});
          uncached.add(new int[] {1, 12, 1, block(), minY + gen.nextInt(height), block(), 1, 1, 1});
          cases.add(run(seed, settingsId, entry.getKey(), sampler, SamplerContext.EMPTY_UNCACHED, uncached, false));

          var cached = new ArrayList<int[]>();
          var cell = cellVolume(3, 5, 3, minY, height);
          cached.add(cell);
          for (int i = 0; i < 4; i++) {
            cached.add(new int[] {cell[3] + gen.nextInt(cell[0]) * cell[6], cell[4] + gen.nextInt(cell[1]) * cell[7], cell[5] + gen.nextInt(cell[2]) * cell[8]});
          }
          cached.add(new int[] {cell[3] + 1, cell[4] + 3, cell[5] + 2});
          cached.add(new int[] {block(), minY + gen.nextInt(height), block()});
          cases.add(run(seed, settingsId, entry.getKey(), sampler, SamplerContext.builder().enableCaches().build(), cached, true));

          var name = entry.getKey();
          if (name.startsWith("router:") && CLIMATE.contains(name.substring(7))) {
            int chunkX = block() >> 4, chunkZ = block() >> 4;
            var quart = new int[] {4, height / 4, 4, chunkX * 16, minY, chunkZ * 16, 4, 4, 4};
            cases.add(run(seed, settingsId, name, sampler, SamplerContext.builder().enableCaches().build(), List.of(quart), true));
          }
        }
      }
    }
    var out = new JsonObject();
    out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla density sample cases over " + seeds.length + " seeds and "
        + settingsList.size() + " noise settings (router, aquifer and " + registryFunctions.size() + " registry functions), "
        + values + " samples");
  }

  static JsonObject run(long seed, String settings, String function,
      net.minecraft.world.level.levelgen.densityfunction.DensitySampler sampler, SamplerContext context, List<int[]> ops, boolean cached) {
    var opList = new JsonArray();
    var results = new JsonArray();
    for (var op : ops) {
      var opJson = new JsonArray();
      for (int n : op) opJson.add(n);
      opList.add(opJson);
      var result = new JsonArray();
      if (op.length == 3) {
        result.add(bits(sampler.sampleValue(context, op[0], op[1], op[2])));
        values++;
      } else {
        var volume = new DensityVolume(op[0], op[1], op[2], op[3], op[4], op[5], op[6], op[7], op[8]);
        var buffer = DensityBuffer.createUnpooled(volume.size());
        sampler.sampleVolume(context, buffer, volume);
        for (int i = 0; i < volume.size(); i++) result.add(bits(buffer.get(i)));
        values += volume.size();
      }
      results.add(result);
    }
    var row = new JsonObject();
    row.addProperty("seed", Long.toString(seed));
    row.addProperty("settings", settings);
    row.addProperty("function", function);
    row.addProperty("cached", cached);
    row.add("ops", opList);
    row.add("results", results);
    return row;
  }

  /** A volume on the noise cell grid (4 x 8 x 4 blocks), as noise chunks sample. */
  static int[] cellVolume(int sx, int sy, int sz, int minY, int height) {
    int y = Math.floorDiv(minY + gen.nextInt(Math.max(1, height - sy * 8)), 8) * 8;
    return new int[] {sx, sy, sz, Math.floorDiv(block(), 4) * 4, y, Math.floorDiv(block(), 4) * 4, 4, 8, 4};
  }

  static int block() {
    return gen.nextInt(4) == 0 ? gen.nextInt(60_000_001) - 30_000_000 : gen.nextInt(20_001) - 10_000;
  }

  static String bits(float f) {
    return String.format("%08x", Float.floatToRawIntBits(f));
  }
}
