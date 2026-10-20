import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.levelgen.LegacyRandomSource;
import net.minecraft.world.level.levelgen.WorldgenRandom;
import net.minecraft.world.level.levelgen.XoroshiroRandomSource;

/**
 * Vanilla random sources (VMC-023a): operation traces on XoroshiroRandomSource
 * and LegacyRandomSource across seeds, and on WorldgenRandom over Xoroshiro
 * as decoration uses it (VMC-025a: reseeding, decoration and feature seeds),
 * with the values vanilla returns (floats and doubles as raw bits). See
 * valimc_core::worldgen::trace for the operations.
 */
public class RandomOracle {
  public static void main(String[] args) throws Exception {
    var gen = new Random(20261020L);
    var cases = new JsonArray();
    long[] fixed = {0L, 1L, -1L, 20261020L, Long.MIN_VALUE, Long.MAX_VALUE, 42L};
    String[] texts = {"", "minecraft:overworld", "minecraft:temperature", "octave_-7", "ünïcødé 𝄞", "a"};
    int[] bounds = {1, 2, 3, 7, 10, 16, 100, 1 << 30, (1 << 30) + 1, Integer.MAX_VALUE};
    for (int c = 0; c < 600; c++) {
      var kind = c >= 400 ? "worldgen" : c % 2 == 0 ? "xoroshiro" : "legacy";
      long seed = c < 2 * fixed.length ? fixed[c / 2] : gen.nextLong();
      var ops = new ArrayList<String>();
      for (int i = 0; i < 40; i++) {
        switch (gen.nextInt(kind.equals("worldgen") ? 17 : 14)) {
          case 0 -> ops.add("int");
          case 1 -> ops.add("bounded:" + bounds[gen.nextInt(bounds.length)]);
          case 2 -> ops.add("long");
          case 3 -> ops.add("bool");
          case 4 -> ops.add("float");
          case 5 -> ops.add("double");
          case 6 -> ops.add("gaussian");
          case 7 -> ops.add("consume:" + gen.nextInt(5));
          case 8 -> ops.add("fork");
          case 9 -> ops.add("at:" + (gen.nextInt(2000001) - 1000000) + "," + (gen.nextInt(385) - 64) + "," + (gen.nextInt(2000001) - 1000000));
          case 10 -> ops.add("hash:" + texts[gen.nextInt(texts.length)]);
          case 11 -> ops.add("seed:" + gen.nextLong());
          case 14 -> ops.add("reseed:" + gen.nextLong());
          case 15 -> ops.add("decoration:" + gen.nextLong() + "," + (gen.nextInt(3750001) - 1875000) + "," + (gen.nextInt(3750001) - 1875000));
          case 16 -> ops.add("feature:" + gen.nextLong() + "," + gen.nextInt(200) + "," + gen.nextInt(11));
          default -> ops.add("bounded:" + (1 + gen.nextInt(1000)));
        }
      }
      RandomSource random = switch (kind) {
        case "xoroshiro" -> new XoroshiroRandomSource(seed);
        case "legacy" -> new LegacyRandomSource(seed);
        default -> new WorldgenRandom(new XoroshiroRandomSource(seed));
      };
      var results = new JsonArray();
      for (var op : ops) {
        var parts = op.split(":", 2);
        var arg = parts.length > 1 ? parts[1] : "";
        switch (parts[0]) {
          case "int" -> results.add(Integer.toString(random.nextInt()));
          case "bounded" -> results.add(Integer.toString(random.nextInt(Integer.parseInt(arg))));
          case "long" -> results.add(Long.toString(random.nextLong()));
          case "bool" -> results.add(Boolean.toString(random.nextBoolean()));
          case "float" -> results.add(String.format("%08x", Float.floatToRawIntBits(random.nextFloat())));
          case "double" -> results.add(String.format("%016x", Double.doubleToRawLongBits(random.nextDouble())));
          case "gaussian" -> results.add(String.format("%016x", Double.doubleToRawLongBits(random.nextGaussian())));
          case "consume" -> { random.consumeCount(Integer.parseInt(arg)); results.add("-"); }
          case "fork" -> { random = random.fork(); results.add("-"); }
          case "at" -> {
            var p = arg.split(",");
            random = random.forkPositional().at(Integer.parseInt(p[0]), Integer.parseInt(p[1]), Integer.parseInt(p[2]));
            results.add("-");
          }
          case "hash" -> { random = random.forkPositional().fromHashOf(arg); results.add("-"); }
          case "seed" -> { random = random.forkPositional().fromSeed(Long.parseLong(arg)); results.add("-"); }
          case "reseed" -> { random.setSeed(Long.parseLong(arg)); results.add("-"); }
          // After a fork the trace continues on a plain source: no seeds.
          case "decoration" -> {
            var p = arg.split(",");
            results.add(random instanceof WorldgenRandom w
                ? Long.toString(w.setDecorationSeed(Long.parseLong(p[0]), Integer.parseInt(p[1]), Integer.parseInt(p[2])))
                : "skip");
          }
          case "feature" -> {
            var p = arg.split(",");
            if (random instanceof WorldgenRandom w) {
              w.setFeatureSeed(Long.parseLong(p[0]), Integer.parseInt(p[1]), Integer.parseInt(p[2]));
              results.add("-");
            } else {
              results.add("skip");
            }
          }
          default -> throw new IllegalStateException(op);
        }
      }
      var row = new JsonObject();
      row.addProperty("kind", kind);
      row.addProperty("seed", Long.toString(seed));
      row.add("ops", new Gson().toJsonTree(ops));
      row.add("results", results);
      cases.add(row);
    }
    var facts = new JsonObject();
    facts.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(facts));
    System.out.println("PASS: " + cases.size() + " vanilla random traces of 40 operations (Xoroshiro, legacy and WorldgenRandom, positional factories, Gaussians, decoration and feature seeds)");
  }
}
