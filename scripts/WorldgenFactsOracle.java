import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.biome.MultiNoiseBiomeSourceParameterList;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.densityfunction.DensityFunctions;
import net.minecraft.world.level.levelgen.synth.NormalNoise;

/**
 * Worldgen facts (VMC-023), each registry entry as vanilla's own codec encodes
 * it (defaults omitted, references to other entries as identifiers), keyed by
 * identifier:
 *
 * - noises.json: the `worldgen/noise` registry;
 * - density_functions.json: the `worldgen/density_function` registry;
 * - noise_settings.json: per `worldgen/noise_settings` entry, its noise
 *   bounds, legacy random flag, noise router and aquifer functions;
 * - biome_parameters.json: per multi-noise preset, its climate parameter list
 *   in order, one row per entry: the biome, then the quantized minimum and
 *   maximum of temperature, humidity, continentalness, erosion, depth and
 *   weirdness, then the offset.
 *
 * Float values are written as their exact double value, so reading them as a
 * double and narrowing to float is exact.
 */
public class WorldgenFactsOracle {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    var ops = lookup.createSerializationContext(JsonOps.INSTANCE);

    var noises = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.NOISE).listElements().forEach(holder ->
        noises.put(holder.key().identifier().toString(),
            NormalNoise.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));

    var functions = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.DENSITY_FUNCTION).listElements().forEach(holder ->
        functions.put(holder.key().identifier().toString(),
            DensityFunctions.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));

    var settings = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.NOISE_SETTINGS).listElements().forEach(holder -> {
      var full = NoiseGeneratorSettings.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow().getAsJsonObject();
      var kept = new JsonObject();
      for (var key : List.of("noise", "legacy_random_source", "noise_router", "aquifers")) {
        if (full.has(key)) kept.add(key, full.get(key));
      }
      settings.put(holder.key().identifier().toString(), kept);
    });

    write(args[0], noises);
    write(args[1], functions);
    write(args[2], settings);

    var presets = new TreeMap<String, List<String>>();
    MultiNoiseBiomeSourceParameterList.knownPresets().forEach((preset, list) -> {
      var rows = new ArrayList<String>();
      for (var entry : list.values()) {
        var p = entry.getFirst();
        var row = new StringBuilder("[\"" + entry.getSecond().identifier() + "\"");
        for (var parameter : List.of(p.temperature(), p.humidity(), p.continentalness(), p.erosion(), p.depth(), p.weirdness())) {
          row.append(", ").append(parameter.min()).append(", ").append(parameter.max());
        }
        rows.add(row.append(", ").append(p.offset()).append("]").toString());
      }
      presets.put(preset.id().toString(), rows);
    });
    var text = new StringBuilder("{\n");
    var names = new ArrayList<>(presets.keySet());
    for (int i = 0; i < names.size(); i++) {
      text.append("  \"").append(names.get(i)).append("\": [\n    ");
      text.append(String.join(",\n    ", presets.get(names.get(i))));
      text.append("\n  ]").append(i + 1 < names.size() ? ",\n" : "\n");
    }
    Files.writeString(Path.of(args[3]), text.append("}\n").toString());
    System.out.println("PASS: " + noises.size() + " noise parameter sets, " + functions.size()
        + " density functions, " + settings.size() + " noise settings, "
        + presets.size() + " biome parameter presets");
  }

  static void write(String path, Map<String, JsonElement> entries) throws Exception {
    var out = new JsonObject();
    entries.forEach((key, value) -> out.add(key, widenFloats(value)));
    Files.writeString(Path.of(path), new GsonBuilder().setPrettyPrinting().create().toJson(out) + "\n");
  }

  static JsonElement widenFloats(JsonElement element) {
    if (element.isJsonObject()) {
      var out = new JsonObject();
      element.getAsJsonObject().entrySet().forEach(e -> out.add(e.getKey(), widenFloats(e.getValue())));
      return out;
    }
    if (element.isJsonArray()) {
      var out = new JsonArray();
      element.getAsJsonArray().forEach(e -> out.add(widenFloats(e)));
      return out;
    }
    if (element.isJsonPrimitive() && element.getAsJsonPrimitive().isNumber()
        && element.getAsNumber() instanceof Float f) {
      return new JsonPrimitive((double) f);
    }
    return element;
  }
}
