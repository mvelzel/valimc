import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.levelgen.LegacyRandomSource;
import net.minecraft.world.level.levelgen.Noises;
import net.minecraft.world.level.levelgen.WorldgenRandom;
import net.minecraft.world.level.levelgen.densityfunction.DensityBuffer;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;
import net.minecraft.world.level.levelgen.synth.BlendedNoise;
import net.minecraft.world.level.levelgen.synth.Noise;

/**
 * Vanilla noise samples (VMC-023b), as raw float bits:
 *
 * - every `worldgen/noise` entry, created as `RandomState` does
 *   (`Noises.instantiate` on a Xoroshiro or legacy positional factory);
 * - the legacy nether climate noises (`createForLegacyNetherBiome`);
 * - the three octave stacks of every blended noise in the density function
 *   registry, from the `minecraft:terrain` random or the legacy random.
 *
 * Each noise is sampled at points (`get` in 3D and 2D) and over volumes
 * (`addToVolume` into a zeroed buffer at amplitude 1, as the noise sampler
 * does), including far coordinates that wrap. Doubles are raw bits too.
 */
public class NoiseOracle {
  static final Random gen = new Random(20261020L);
  static final double[] SCALES = {1.0, 0.25, 0.5, 0.125, 2.0, 684.412 * 0.25, 684.412 * 0.125, 684.412 * 0.25 / 80.0, 1.0 / 1024.0};
  static final double[] SPECIAL = {0.0, -0.0, 0.5, -0.5, Math.nextDown(16777216.0), 16777216.0, -16777216.0,
      Math.nextDown(-16777216.0), 33554432.0, -33554432.0 * 3.0 + 0.75, 1.0e-300, -1.0e-9, 2.5e7, 1.0e15};
  static final int[] STEPS = {1, 2, 4, 8};
  static int values = 0;

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    var noises = lookup.lookupOrThrow(Registries.NOISE).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).toList();
    var blended = new ArrayList<BlendedNoise>();
    lookup.lookupOrThrow(Registries.DENSITY_FUNCTION).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString()))
        .forEach(h -> { if (h.value() instanceof BlendedNoise b && !blended.contains(b)) blended.add(b); });
    if (blended.size() != 3) throw new IllegalStateException("expected 3 blended noises, found " + blended.size());
    blended.add(new BlendedNoise(0.5, 0.3, 40.0, 90.0, 2.5));

    var seeds = new ArrayList<>(List.of(0L, 1L, -1L, 20261020L, Long.MIN_VALUE, Long.MAX_VALUE, 42L));
    while (seeds.size() < 10) seeds.add(gen.nextLong());
    var cases = new JsonArray();

    for (long seed : seeds) {
      for (var algorithm : WorldgenRandom.Algorithm.values()) {
        var kind = algorithm == WorldgenRandom.Algorithm.XOROSHIRO ? "xoroshiro" : "legacy";
        var positional = algorithm.newInstance(seed).forkPositional();
        for (var holder : noises) {
          var id = holder.key().identifier().toString();
          Noise noise = Noises.instantiate(lookup.lookupOrThrow(Registries.NOISE), positional, holder.key());
          var row = sample(noise, 1.0, 1.0, 24);
          row.addProperty("noise", "normal");
          row.addProperty("id", id);
          row.addProperty("kind", kind);
          row.addProperty("seed", Long.toString(seed));
          row.addProperty("source", "hash:" + id);
          cases.add(row);
        }
      }
      for (var nether : List.of(Noises.TEMPERATURE_NETHER, Noises.VEGETATION_NETHER)) {
        long offset = nether == Noises.TEMPERATURE_NETHER ? 0L : 1L;
        var holder = lookup.lookupOrThrow(Registries.NOISE).getOrThrow(nether);
        Noise noise = holder.value().createForLegacyNetherBiome(new LegacyRandomSource(seed + offset));
        var row = sample(noise, 1.0, 1.0, 64);
        row.addProperty("noise", "legacy_nether");
        row.addProperty("id", nether.identifier().toString());
        row.addProperty("kind", "legacy");
        row.addProperty("seed", Long.toString(seed + offset));
        row.addProperty("source", "");
        cases.add(row);
      }
      for (var b : blended) {
        for (boolean legacy : new boolean[] {false, true}) {
          RandomSource random = legacy
              ? new LegacyRandomSource(seed)
              : WorldgenRandom.Algorithm.XOROSHIRO.newInstance(seed).forkPositional().fromHashOf(BlendedNoise.NOISE_SEED);
          var set = b.createFbmSet(random);
          double xzMul = 684.412 * b.xzScale(), yMul = 684.412 * b.yScale();
          var stacks = new Object[][] {
            {"blended_min", set.minLimitNoise(), xzMul, yMul},
            {"blended_max", set.maxLimitNoise(), xzMul, yMul},
            {"blended_main", set.mainNoise(), xzMul / b.xzFactor(), yMul / b.yFactor()},
          };
          for (var stack : stacks) {
            var row = sample((Noise) stack[1], (double) stack[2], (double) stack[3], 32);
            row.addProperty("noise", (String) stack[0]);
            row.addProperty("kind", legacy ? "legacy" : "xoroshiro");
            row.addProperty("seed", Long.toString(seed));
            row.addProperty("source", legacy ? "" : "hash:" + BlendedNoise.NOISE_SEED);
            var params = new JsonArray();
            for (double p : new double[] {b.xzScale(), b.yScale(), b.xzFactor(), b.yFactor(), b.smearScaleMultiplier()}) params.add(hex(p));
            row.add("params", params);
            cases.add(row);
          }
        }
      }
    }
    var out = new JsonObject();
    out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla noises (" + noises.size() + " registry noises, legacy nether climate, "
        + blended.size() + " blended octave sets) over " + seeds.size() + " seeds, " + values + " samples");
  }

  /** Points and volumes for a noise; `xzScale`/`yScale` are the scales its sampler uses. */
  static JsonObject sample(Noise noise, double xzScale, double yScale, int pointCount) {
    var points = new JsonArray();
    var results = new JsonArray();
    var results2d = new JsonArray();
    for (int i = 0; i < pointCount; i++) {
      double x, y, z;
      if (i % 3 == 0) {
        x = block() * xzScale;
        y = (gen.nextInt(385) - 64) * yScale;
        z = block() * xzScale;
      } else {
        x = coordinate();
        y = coordinate();
        z = coordinate();
      }
      points.add(hex(x));
      points.add(hex(y));
      points.add(hex(z));
      results.add(String.format("%08x", Float.floatToRawIntBits(noise.get(x, y, z))));
      results2d.add(String.format("%08x", Float.floatToRawIntBits(noise.get(x, z))));
      values += 2;
    }
    var volumes = new JsonArray();
    for (int v = 0; v < 2; v++) {
      int sx = 1 + gen.nextInt(4), sy = 1 + gen.nextInt(24), sz = 1 + gen.nextInt(4);
      int[] step = {STEPS[gen.nextInt(4)], STEPS[gen.nextInt(4)], STEPS[gen.nextInt(4)]};
      int[] min = {v == 0 ? gen.nextInt(2001) - 1000 : block(), gen.nextInt(385) - 64 - sy * step[1] / 2, v == 0 ? gen.nextInt(2001) - 1000 : block()};
      double xz = v == 0 ? xzScale : SCALES[gen.nextInt(SCALES.length)];
      double ys = v == 0 ? yScale : SCALES[gen.nextInt(SCALES.length)];
      var volume = new DensityVolume(sx, sy, sz, min[0], min[1], min[2], step[0], step[1], step[2]);
      var buffer = DensityBuffer.createUnpooled(volume.size());
      noise.addToVolume(buffer, volume, xz, ys, 1.0F);
      var shape = new JsonArray();
      for (int n : new int[] {sx, sy, sz, min[0], min[1], min[2], step[0], step[1], step[2]}) shape.add(n);
      var vals = new JsonArray();
      for (int i = 0; i < volume.size(); i++) vals.add(String.format("%08x", Float.floatToRawIntBits(buffer.get(i))));
      values += volume.size();
      var row = new JsonObject();
      row.add("volume", shape);
      row.addProperty("xz", hex(xz));
      row.addProperty("y", hex(ys));
      row.add("values", vals);
      volumes.add(row);
    }
    var row = new JsonObject();
    row.add("points", points);
    row.add("results", results);
    row.add("results_2d", results2d);
    row.add("volumes", volumes);
    return row;
  }

  static int block() {
    return gen.nextBoolean() ? gen.nextInt(60_000_001) - 30_000_000 : gen.nextInt(20_001) - 10_000;
  }

  static double coordinate() {
    return switch (gen.nextInt(5)) {
      case 0 -> block() * SCALES[gen.nextInt(SCALES.length)];
      case 1 -> (gen.nextDouble() * 2.0 - 1.0) * 1000.0;
      case 2 -> (gen.nextDouble() * 2.0 - 1.0) * 1.0e10;
      case 3 -> SPECIAL[gen.nextInt(SPECIAL.length)];
      default -> (gen.nextInt(2001) - 1000) * 0.25 + gen.nextInt(3) * 1.0e-7;
    };
  }

  static String hex(double d) {
    return String.format("%016x", Double.doubleToRawLongBits(d));
  }
}
