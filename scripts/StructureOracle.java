import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.lang.reflect.Proxy;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.Holder;
import net.minecraft.core.HolderSet;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.Registries;
import net.minecraft.nbt.*;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.StructureManager;
import net.minecraft.world.level.WorldGenLevel;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.MultiNoiseBiomeSource;
import net.minecraft.world.level.biome.MultiNoiseBiomeSourceParameterList;
import net.minecraft.world.level.chunk.ChunkGeneratorStructureState;
import net.minecraft.world.level.chunk.PalettedContainerFactory;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.chunk.UpgradeData;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.levelgen.structure.StructureSet;
import net.minecraft.world.level.levelgen.structure.pieces.StructurePieceSerializationContext;
import net.minecraft.world.level.levelgen.structure.placement.ConcentricRingsStructurePlacement;
import net.minecraft.world.level.levelgen.structure.placement.RandomSpreadStructurePlacement;
import net.minecraft.world.level.levelgen.structure.templatesystem.StructureTemplateManager;

/**
 * Structure placement and starts (VMC-025e), from the vanilla data pack as a server loads it
 * (static registries' tags first, as `WorldLoader` does).
 *
 * `facts STRUCTURES.json STRUCTURE_SETS.json`: the `worldgen/structure` and
 * `worldgen/structure_set` registries as vanilla's codecs encode them, keyed by identifier, with
 * each biome holder set (a structure's biomes, a concentric ring placement's preferred biomes)
 * resolved to its sorted biome identifiers. The registries list their entries in identifier
 * order, which is the order in which chunk generation tries structure sets.
 *
 * `starts OUT.json`: per seed (as the decoration oracle picks them) vanilla's overworld generator
 * over the overworld preset (every climate lookup from a fresh history) and its structure state
 * (`ChunkGenerator.createState`). Recorded: the structure sets whose structures can occur, the
 * concentric ring positions, and for three windows (40 × 40 chunks around the origin, 40 × 40
 * within 2,000 chunks, 24 × 24 far out) every chunk's placement result per set, every start
 * vanilla's `createStructures` makes in a fresh proto chunk (as its `createTag` NBT, printed
 * canonically) and, for the chunks at least 8 from a window's edge, the references
 * `createReferences` adds. Then, per random spread set, placement chunks drawn at random within
 * 30,000 chunks of the origin get `createStructures` too until every structure of the set has
 * eight starts or the set has had its share of attempts (150 per structure, at least 1,000).
 *
 * Canonical NBT: compounds as {key:value,...} with keys sorted, lists as [a,b], int arrays as
 * [I;a,b], bytes with suffix b, shorts s, longs L, floats f, doubles d, strings JSON-quoted.
 */
public class StructureOracle {
  static final int MIN_Y = -64, HEIGHT = 384;

  public static void main(String[] args) throws Exception {
    switch (args[0]) {
      case "facts" -> facts(Path.of(args[1]), Path.of(args[2]));
      case "starts" -> starts(Path.of(args[1]));
      default -> throw new IllegalArgumentException("usage: StructureOracle facts|starts ...");
    }
  }

  /** The worldgen registries as a server loads them (`WorldLoader`): static tags first. */
  static RegistryAccess serverRegistries() throws Exception {
    MiningToolOracle.initialize();
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var layered = net.minecraft.server.RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,
          layered.getLayer(net.minecraft.server.RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(
          layered.getAccessForLoading(net.minecraft.server.RegistryLayer.WORLD), pending);
      var registries = net.minecraft.resources.RegistryDataLoader.load(resources, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(net.minecraft.core.Registry.PendingTags::apply);
      // Static and worldgen registries together (ruined portals read the block registry).
      return layered.replaceFrom(net.minecraft.server.RegistryLayer.WORLD, registries).compositeAccess();
    }
  }

  static JsonArray biomeIds(HolderSet<Biome> biomes) {
    var ids = new JsonArray();
    biomes.stream().map(h -> h.unwrapKey().orElseThrow().identifier().toString()).sorted().forEach(ids::add);
    return ids;
  }

  static void facts(Path structuresOut, Path setsOut) throws Exception {
    var registries = serverRegistries();
    var ops = registries.createSerializationContext(JsonOps.INSTANCE);
    var structures = new TreeMap<String, JsonElement>();
    var order = new ArrayList<String>();
    registries.lookupOrThrow(Registries.STRUCTURE).listElements().forEach(holder -> {
      var json = Structure.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow().getAsJsonObject();
      json.add("biomes", biomeIds(holder.value().biomes()));
      structures.put(holder.key().identifier().toString(), json);
    });
    var sets = new TreeMap<String, JsonElement>();
    registries.lookupOrThrow(Registries.STRUCTURE_SET).listElements().forEach(holder -> {
      var json = StructureSet.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow().getAsJsonObject();
      if (holder.value().placement() instanceof ConcentricRingsStructurePlacement rings) {
        json.getAsJsonObject("placement").add("preferred_biomes", biomeIds(rings.preferredBiomes()));
      }
      order.add(holder.key().identifier().toString());
      sets.put(holder.key().identifier().toString(), json);
    });
    if (!order.equals(new ArrayList<>(sets.keySet()))) {
      throw new IllegalStateException("structure sets are not listed in identifier order: " + order);
    }
    WorldgenFactsOracle.write(structuresOut.toString(), structures);
    WorldgenFactsOracle.write(setsOut.toString(), sets);
    System.out.println("PASS: " + structures.size() + " structures, " + sets.size() + " structure sets");
  }

  /** One seed's vanilla overworld generator and structure state. */
  record World(long seed, RegistryAccess registries, NoiseBasedChunkGenerator generator, ChunkGeneratorStructureState state,
      StructureManager manager, StructureTemplateManager templates, PalettedContainerFactory factory, LevelHeightAccessor heights,
      StructurePieceSerializationContext context, Map<Structure, String> ids) {
    static World overworld(long seed, RegistryAccess registries, PalettedContainerFactory factory) throws Exception {
      var settings = registries.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(NoiseGeneratorSettings.OVERWORLD);
      var randomState = RandomState.create(registries.lookupOrThrow(Registries.NOISE), seed, settings.value());
      var biomeSource = MultiNoiseBiomeSource.createFromList(
          TerrainOracle.freshList(MultiNoiseBiomeSourceParameterList.Preset.OVERWORLD, registries.lookupOrThrow(Registries.BIOME)));
      var generator = new NoiseBasedChunkGenerator(biomeSource, settings);
      var state = generator.createState(registries.lookupOrThrow(Registries.STRUCTURE_SET), randomState, seed);
      var templates = DecorationOracle.Region.templateServer().getStructureTemplateManager();
      var ids = new IdentityHashMap<Structure, String>();
      registries.lookupOrThrow(Registries.STRUCTURE).listElements()
          .forEach(h -> ids.put(h.value(), h.key().identifier().toString()));
      return new World(seed, registries, generator, state, new StructureManager(null, new WorldOptions(seed, true, false), null),
          templates, factory, LevelHeightAccessor.create(MIN_Y, HEIGHT),
          new StructurePieceSerializationContext(null, registries, templates), ids);
    }

    ProtoChunk createStructures(int x, int z) {
      var chunk = new ProtoChunk(new ChunkPos(x, z), UpgradeData.EMPTY, heights, factory, null);
      generator.createStructures(registries, state, manager, chunk, templates, Level.OVERWORLD);
      return chunk;
    }
  }

  static void starts(Path out) throws Exception {
    var registries = serverRegistries();
    var factory = ChunkOracle.factory();
    var gen = new Random(20261020L);
    long[] seeds = {20261020L, -8172645723L, gen.nextLong()};
    var cases = new JsonArray();
    int startCount = 0, referenceCount = 0, chunkCount = 0;
    for (long seed : seeds) {
      var world = World.overworld(seed, registries, factory);
      var row = new JsonObject();
      row.addProperty("seed", Long.toString(seed));
      var possible = new JsonArray();
      var rings = new JsonObject();
      for (var set : world.state.possibleStructureSets()) {
        String id = set.unwrapKey().orElseThrow().identifier().toString();
        possible.add(id);
        if (set.value().placement() instanceof ConcentricRingsStructurePlacement placement) {
          var positions = new JsonArray();
          for (var pos : world.state.getRingPositionsFor(placement)) {
            positions.add(pos.x());
            positions.add(pos.z());
          }
          rings.add(id, positions);
        }
      }
      row.add("possible_sets", possible);
      row.add("rings", rings);

      var chunks = new JsonArray();
      var starts = new JsonArray();
      var placements = new JsonArray();
      var references = new JsonArray();
      int[][] windows = {
        {-20, -20, 40},
        {gen.nextInt(4001) - 2000, gen.nextInt(4001) - 2000, 40},
        {gen.nextInt(3_750_001) - 1_875_000, gen.nextInt(3_750_001) - 1_875_000, 24},
      };
      for (int[] window : windows) {
        var area = new HashMap<ChunkPos, ProtoChunk>();
        for (int dz = 0; dz < window[2]; dz++) {
          for (int dx = 0; dx < window[2]; dx++) {
            int x = window[0] + dx, z = window[1] + dz;
            var chunk = world.createStructures(x, z);
            area.put(chunk.getPos(), chunk);
            chunks.add(x);
            chunks.add(z);
            startCount += addStarts(world, chunk, starts);
          }
        }
        for (var set : world.state.possibleStructureSets()) {
          var hits = new JsonArray();
          for (int dz = 0; dz < window[2]; dz++) {
            for (int dx = 0; dx < window[2]; dx++) {
              if (set.value().placement().isStructureChunk(world.state, window[0] + dx, window[1] + dz)) {
                hits.add(window[0] + dx);
                hits.add(window[1] + dz);
              }
            }
          }
          var entry = new JsonObject();
          entry.add("window", intArray(window));
          entry.addProperty("set", set.unwrapKey().orElseThrow().identifier().toString());
          entry.add("chunks", hits);
          placements.add(entry);
        }
        WorldGenLevel level = areaLevel(area);
        for (int dz = 8; dz < window[2] - 8; dz++) {
          for (int dx = 8; dx < window[2] - 8; dx++) {
            var chunk = area.get(new ChunkPos(window[0] + dx, window[1] + dz));
            world.generator.createReferences(level, world.manager, chunk);
            for (var entry : chunk.getAllReferences().entrySet()) {
              var sources = new JsonArray();
              entry.getValue().longStream().sorted().forEach(key -> {
                var source = ChunkPos.unpack(key);
                sources.add(source.x());
                sources.add(source.z());
              });
              var ref = new JsonObject();
              ref.add("chunk", intArray(new int[] {chunk.getPos().x(), chunk.getPos().z()}));
              ref.addProperty("structure", world.ids.get(entry.getKey()));
              ref.add("sources", sources);
              references.add(ref);
              referenceCount += entry.getValue().size();
            }
          }
        }
      }

      // Targeted placement chunks, so that every structure gets starts.
      var search = new Random(seed);
      for (var set : world.state.possibleStructureSets()) {
        if (!(set.value().placement() instanceof RandomSpreadStructurePlacement placement)) continue;
        var wanted = new HashMap<Structure, Integer>();
        for (var entry : set.value().structures()) wanted.put(entry.structure().value(), 8);
        int attempts = 0, budget = Math.max(150 * set.value().structures().size(), 1000);
        int draws = 0;
        while (!wanted.isEmpty() && attempts < budget && draws < 200_000) {
          draws++;
          int x = search.nextInt(60_001) - 30_000, z = search.nextInt(60_001) - 30_000;
          var candidate = placement.getPotentialStructureChunk(seed, x, z);
          if (!placement.isStructureChunk(world.state, candidate.x(), candidate.z())) continue;
          attempts++;
          var chunk = world.createStructures(candidate.x(), candidate.z());
          chunks.add(candidate.x());
          chunks.add(candidate.z());
          startCount += addStarts(world, chunk, starts);
          for (var structure : chunk.getAllStarts().keySet()) {
            wanted.computeIfPresent(structure, (k, n) -> n > 1 ? n - 1 : null);
          }
        }
      }
      chunkCount += chunks.size() / 2;
      row.add("chunks", chunks);
      row.add("starts", starts);
      row.add("placements", placements);
      row.add("references", references);
      cases.add(row);
    }
    var result = new JsonObject();
    result.add("cases", cases);
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: " + startCount + " vanilla structure starts in " + chunkCount + " chunks and " + referenceCount
        + " references over " + seeds.length + " seeds");
  }

  static int addStarts(World world, ProtoChunk chunk, JsonArray starts) {
    var sorted = new TreeMap<String, net.minecraft.world.level.levelgen.structure.StructureStart>();
    chunk.getAllStarts().forEach((structure, start) -> sorted.put(world.ids.get(structure), start));
    sorted.forEach((id, start) -> {
      var entry = new JsonObject();
      entry.add("chunk", intArray(new int[] {chunk.getPos().x(), chunk.getPos().z()}));
      entry.addProperty("structure", id);
      entry.addProperty("nbt", snbt(start.createTag(world.context, chunk.getPos())));
      starts.add(entry);
    });
    return sorted.size();
  }

  /** A level over an area's proto chunks for `createReferences`, which only reads their starts. */
  static WorldGenLevel areaLevel(Map<ChunkPos, ProtoChunk> area) {
    return (WorldGenLevel) Proxy.newProxyInstance(StructureOracle.class.getClassLoader(), new Class<?>[] {WorldGenLevel.class},
        (proxy, method, args) -> switch (method.getName()) {
          case "getChunk" -> {
            if (args.length < 2 || !(args[0] instanceof Integer x) || !(args[1] instanceof Integer z)) {
              throw new UnsupportedOperationException("getChunk" + Arrays.toString(args));
            }
            var chunk = area.get(new ChunkPos(x, z));
            if (chunk == null) throw new IllegalStateException("chunk outside the area: " + x + ", " + z);
            yield chunk;
          }
          default -> throw new UnsupportedOperationException("WorldGenLevel." + method.getName());
        });
  }

  static JsonArray intArray(int[] values) {
    var array = new JsonArray();
    for (int v : values) array.add(v);
    return array;
  }

  /** Canonical SNBT (see the class comment). */
  static String snbt(Tag tag) {
    var out = new StringBuilder();
    snbt(tag, out);
    return out.toString();
  }

  static void snbt(Tag tag, StringBuilder out) {
    switch (tag) {
      case CompoundTag compound -> {
        out.append('{');
        boolean first = true;
        for (var key : new TreeSet<>(compound.keySet())) {
          if (!first) out.append(',');
          first = false;
          out.append(key).append(':');
          snbt(compound.get(key), out);
        }
        out.append('}');
      }
      case ListTag list -> {
        out.append('[');
        for (int i = 0; i < list.size(); i++) {
          if (i > 0) out.append(',');
          snbt(list.get(i), out);
        }
        out.append(']');
      }
      case IntArrayTag array -> {
        out.append("[I;");
        int[] values = array.getAsIntArray();
        for (int i = 0; i < values.length; i++) {
          if (i > 0) out.append(',');
          out.append(values[i]);
        }
        out.append(']');
      }
      case LongArrayTag array -> {
        out.append("[L;");
        long[] values = array.getAsLongArray();
        for (int i = 0; i < values.length; i++) {
          if (i > 0) out.append(',');
          out.append(values[i]);
        }
        out.append(']');
      }
      case ByteArrayTag array -> {
        out.append("[B;");
        byte[] values = array.getAsByteArray();
        for (int i = 0; i < values.length; i++) {
          if (i > 0) out.append(',');
          out.append(values[i]);
        }
        out.append(']');
      }
      case ByteTag b -> out.append(b.value()).append('b');
      case ShortTag s -> out.append(s.value()).append('s');
      case IntTag i -> out.append(i.value());
      case LongTag l -> out.append(l.value()).append('L');
      case FloatTag f -> out.append(f.value()).append('f');
      case DoubleTag d -> out.append(d.value()).append('d');
      case StringTag s -> out.append(new Gson().toJson(s.value()));
      default -> throw new IllegalArgumentException("unexpected tag " + tag);
    }
  }
}
