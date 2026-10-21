import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.Holder;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeSource;
import net.minecraft.world.level.biome.Climate;
import net.minecraft.world.level.biome.FeatureSorter;
import net.minecraft.world.level.biome.MultiNoiseBiomeSource;
import net.minecraft.world.level.biome.MultiNoiseBiomeSourceParameterList;
import net.minecraft.world.level.biome.TheEndBiomeSource;
import net.minecraft.world.level.levelgen.feature.Feature;
import net.minecraft.world.level.levelgen.feature.stateproviders.BlockStateProvider;
import net.minecraft.world.level.levelgen.placement.PlacedFeature;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.carver.WorldCarver;
import net.minecraft.world.level.levelgen.densityfunction.DensityFunctions;
import net.minecraft.world.level.levelgen.material.condition.MaterialCondition;
import net.minecraft.world.level.levelgen.material.rule.MaterialRule;
import net.minecraft.world.level.levelgen.synth.NormalNoise;

/**
 * Worldgen facts (VMC-023), each registry entry as vanilla's own codec encodes
 * it (defaults omitted, references to other entries as identifiers), keyed by
 * identifier:
 *
 * - noises.json: the `worldgen/noise` registry;
 * - density_functions.json: the `worldgen/density_function` registry;
 * - noise_settings.json: per `worldgen/noise_settings` entry, its noise
 *   bounds, sea level, default block and fluid, legacy random flag, noise
 *   router, aquifer functions, material rule and spawn target (VMC-027);
 * - material_rules.json and material_conditions.json: the
 *   `worldgen/material_rule` and `worldgen/material_condition` registries;
 * - biomes.json: per biome, its climate (precipitation, temperature and its
 *   modifier, downfall), carvers and placed features per decoration step;
 * - carvers.json: the `worldgen/carver` registry;
 * - features.json, placed_features.json and block_state_providers.json: the
 *   `worldgen/feature`, `worldgen/placed_feature` and
 *   `worldgen/block_state_provider` registries (VMC-025);
 * - feature_order.json: per biome source (the overworld and nether presets,
 *   the End), the placed features of each decoration step in the order
 *   vanilla's `FeatureSorter` gives them, whose index seeds each feature;
 * - dimensions.json: the dimensions of the normal world preset (VMC-026a), each
 *   with its dimension type's build bounds (bottom, height, logical height),
 *   noise settings and biome source (a multi-noise preset, or the End's);
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
    // The registries a server loads (VMC-028c): the vanilla data pack, then the
    // packs named after `--packs` (data pack folders or zips), in order.
    var packs = packs(args);
    args = withoutPacks(args);
    String tagsOut = null;
    var tagsAt = Arrays.asList(args).indexOf("--tags");
    if (tagsAt >= 0) {
      tagsOut = args[tagsAt + 1];
      args = Arrays.copyOf(args, tagsAt);
    }
    var registries = loadRegistries(packs);
    net.minecraft.core.HolderLookup.Provider lookup = registries;
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
      for (var key : List.of("noise", "sea_level", "default_block", "default_fluid", "legacy_random_source",
          "noise_router", "aquifers", "material_rule", "spawn_target")) {
        if (full.has(key)) kept.add(key, full.get(key));
      }
      // A spawn target point maps functions to ranges: its order is a map's, so sort it.
      if (kept.has("spawn_target")) {
        var points = new JsonArray();
        for (var point : kept.getAsJsonArray("spawn_target")) {
          var sorted = new JsonObject();
          new TreeMap<>(point.getAsJsonObject().asMap()).forEach(sorted::add);
          points.add(sorted);
        }
        kept.add("spawn_target", points);
      }
      settings.put(holder.key().identifier().toString(), kept);
    });

    var rules = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.MATERIAL_RULE).listElements().forEach(holder ->
        rules.put(holder.key().identifier().toString(), MaterialRule.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));
    var conditions = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.MATERIAL_CONDITION).listElements().forEach(holder ->
        conditions.put(holder.key().identifier().toString(), MaterialCondition.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));
    var biomes = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.BIOME).listElements().forEach(holder -> {
      var full = Biome.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow().getAsJsonObject();
      var kept = new JsonObject();
      for (var key : List.of("has_precipitation", "temperature", "temperature_modifier", "downfall", "carvers", "features")) {
        if (full.has(key)) kept.add(key, full.get(key));
      }
      biomes.put(holder.key().identifier().toString(), kept);
    });

    var carvers = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.CARVER).listElements().forEach(holder ->
        carvers.put(holder.key().identifier().toString(), WorldCarver.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));

    var features = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.FEATURE).listElements().forEach(holder ->
        features.put(holder.key().identifier().toString(), Feature.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));
    var placed = new TreeMap<String, JsonElement>();
    var placedIds = new IdentityHashMap<PlacedFeature, String>();
    lookup.lookupOrThrow(Registries.PLACED_FEATURE).listElements().forEach(holder -> {
      placedIds.put(holder.value(), holder.key().identifier().toString());
      placed.put(holder.key().identifier().toString(), PlacedFeature.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow());
    });
    var providers = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.BLOCK_STATE_PROVIDER).listElements().forEach(holder ->
        providers.put(holder.key().identifier().toString(), BlockStateProvider.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));

    var biomeLookup = lookup.lookupOrThrow(Registries.BIOME);
    var sources = new TreeMap<String, BiomeSource>();
    for (var preset : List.of(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD, MultiNoiseBiomeSourceParameterList.Preset.NETHER)) {
      var values = new ArrayList<com.mojang.datafixers.util.Pair<Climate.ParameterPoint, Holder<Biome>>>();
      for (var pair : MultiNoiseBiomeSourceParameterList.knownPresets().get(preset).values()) {
        values.add(com.mojang.datafixers.util.Pair.of(pair.getFirst(), biomeLookup.getOrThrow(pair.getSecond())));
      }
      sources.put(preset.id().toString(), MultiNoiseBiomeSource.createFromList(new Climate.ParameterList<>(values)));
    }
    sources.put("minecraft:the_end", TheEndBiomeSource.create(biomeLookup));
    var order = new TreeMap<String, JsonElement>();
    sources.forEach((name, source) -> {
      var steps = new JsonArray();
      for (var step : FeatureSorter.buildFeaturesPerStep(List.copyOf(source.possibleBiomes()),
          b -> b.value().getGenerationSettings().features(), true)) {
        var ids = new JsonArray();
        step.features().forEach(feature -> ids.add(Objects.requireNonNull(placedIds.get(feature))));
        steps.add(ids);
      }
      order.put(name, steps);
    });

    write(args[0], noises);
    write(args[1], functions);
    write(args[2], settings);
    write(args[4], rules);
    write(args[5], conditions);
    write(args[6], biomes);
    write(args[7], carvers);
    write(args[8], features);
    write(args[9], placed);
    write(args[10], providers);
    write(args[11], order);

    var dimensions = new TreeMap<String, JsonElement>();
    var normal = lookup.lookupOrThrow(Registries.WORLD_PRESET)
        .getOrThrow(net.minecraft.world.level.levelgen.presets.WorldPresets.NORMAL).value();
    normal.createWorldDimensions().dimensions().forEach((key, stem) -> {
      var generator = net.minecraft.world.level.dimension.LevelStem.CODEC.encodeStart(ops, stem).getOrThrow()
          .getAsJsonObject().getAsJsonObject("generator");
      var source = generator.getAsJsonObject("biome_source");
      var type = stem.type().value();
      var entry = new JsonObject();
      entry.addProperty("min_y", type.minY());
      entry.addProperty("height", type.height());
      entry.addProperty("logical_height", type.logicalHeight());
      entry.add("noise_settings", generator.get("settings"));
      entry.add("biome_source", source.has("preset") ? source.get("preset") : source.get("type"));
      dimensions.put(key.identifier().toString(), entry);
    });
    write(args[12], dimensions);

    // A data pack's block and fluid tags (decoration reads them; vanilla's come from the
    // protocol facts).
    if (tagsOut != null) {
      var tags = new JsonObject();
      for (var key : List.of(Registries.BLOCK, Registries.FLUID)) {
        var byTag = new TreeMap<String, JsonElement>();
        var registry = registries.lookupOrThrow(key);
        registry.listTags().forEach(named -> {
          var ids = new JsonArray();
          named.stream().forEach(holder -> ids.add(registry.getId(holder.value())));
          byTag.put(named.key().location().toString(), ids);
        });
        var entry = new JsonObject();
        byTag.forEach(entry::add);
        tags.add(key.identifier().toString(), entry);
      }
      Files.writeString(Path.of(tagsOut), new GsonBuilder().setPrettyPrinting().create().toJson(tags) + "\n");
    }

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
        + presets.size() + " biome parameter presets, " + rules.size() + " material rules, " + conditions.size()
        + " material conditions, " + biomes.size() + " biomes, " + carvers.size() + " carvers, "
        + features.size() + " features, " + placed.size() + " placed features, " + providers.size()
        + " block state providers, feature order for " + order.size() + " biome sources, "
        + dimensions.size() + " dimensions");
  }

  /** The data pack folders after `--packs` (VMC-028c): they come last in a command line. */
  static List<Path> packs(String[] args) {
    var split = Arrays.asList(args).indexOf("--packs");
    var packs = new ArrayList<Path>();
    if (split >= 0) for (var pack : Arrays.asList(args).subList(split + 1, args.length)) packs.add(Path.of(pack));
    return packs;
  }

  static String[] withoutPacks(String[] args) {
    var split = Arrays.asList(args).indexOf("--packs");
    return split >= 0 ? Arrays.copyOf(args, split) : args;
  }

  /** The server data of vanilla's pack, then `packs` (folders; zips are unpacked by the caller). */
  static List<net.minecraft.server.packs.PackResources> packResources(List<Path> packs) {
    var resources = new ArrayList<net.minecraft.server.packs.PackResources>();
    resources.add(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources());
    for (var pack : packs) {
      var info = new net.minecraft.server.packs.PackLocationInfo(pack.getFileName().toString(),
          net.minecraft.network.chat.Component.literal(pack.getFileName().toString()),
          net.minecraft.server.packs.repository.PackSource.WORLD, Optional.empty());
      if (!Files.isDirectory(pack)) throw new IllegalArgumentException("not a data pack folder: " + pack);
      resources.add(new net.minecraft.server.packs.PathPackResources(info, pack));
    }
    return resources;
  }

  /**
   * Worldgen registries as `WorldLoader` loads them: static registries' tags from the packs first,
   * then the world registries from vanilla's pack and `packs`.
   */
  static net.minecraft.core.RegistryAccess loadRegistries(List<Path> packs) throws Exception {
    MiningToolOracle.initialize();
    try (var manager = new net.minecraft.server.packs.resources.MultiPackResourceManager(
        net.minecraft.server.packs.PackType.SERVER_DATA, packResources(packs))) {
      var layered = net.minecraft.server.RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(manager,
          layered.getLayer(net.minecraft.server.RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(
          layered.getAccessForLoading(net.minecraft.server.RegistryLayer.WORLD), pending);
      var registries = net.minecraft.resources.RegistryDataLoader.load(manager, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(net.minecraft.core.Registry.PendingTags::apply);
      // Codecs also read the static registries (blocks, fluids...).
      return layered.replaceFrom(net.minecraft.server.RegistryLayer.WORLD, registries).compositeAccess();
    }
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
