import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.HolderGetter;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LevelAccessor;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.StructureManager;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.BiomeManager;
import net.minecraft.world.level.biome.BiomeSource;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.levelgen.Aquifer;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.material.rule.MaterialRule;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.levelgen.structure.StructureStart;
import net.minecraft.world.level.levelgen.structure.placement.RandomSpreadStructurePlacement;

/**
 * Vanilla structure placement (VMC-025f): chunk decoration with structures on, as
 * `ChunkGenerator.applyBiomeDecoration` does it.
 *
 * For each case (seed, centre chunk) the starts of the 21 × 21 chunks around the centre come from
 * vanilla's `createStructures` (as `StructureOracle` makes them, kept only for the structures
 * named), each chunk of the 5 × 5 around the centre gets its references from vanilla's
 * `createReferences`, and those chunks get their terrain as `DecorationOracle` builds it, with
 * each chunk's beards (`Beardifier.forStructuresInChunk`) in the noise fill (VMC-025f3). The 3 × 3 chunks are then decorated in order (Z outer, X inner)
 * by vanilla's own `applyBiomeDecoration` with every placed feature, through `DecorationOracle`'s
 * region and a `StructureManager` (structures on) whose level serves the chunks holding the starts
 * and references. Structure pieces that ask the region for the current difficulty get a normal
 * one, and for environment attributes their defaults; the server level the region hands out holds
 * that structure manager (a swamp hut's cat asks whether it stands in a structure) and its server
 * the world's seed (capped processors ask).
 *
 * Cases: per seed (`DecorationOracle`'s seeds) an area at the origin and one within 2,000 chunks,
 * and per structure named, areas whose centre holds that structure's first piece (a start found
 * through its set's placement from a seeded search, or its ring positions in order), on the first seed two of them (the second
 * with the centre one chunk short of the piece's lowest corner, so that the structure reaches past
 * the decorated chunks), on the others one.
 *
 * Usage: StructurePlacementOracle OUT STRUCTURE,STRUCTURE,... [nether|end]. Output: as
 * `DecorationOracle`'s (dimension, settings, every placed feature, per case the chunks, each also
 * with its block entities as they save), with the structures named and per case the structure it
 * targets (or none) and every start of the 21 × 21 as placement left it
 * (`StructureStart.createTag`, canonical SNBT, sorted). See `verify` for block entity NBT, and
 * `live`, `verifyLive` and `bench` for live generation (VMC-025f5). For debugging,
 * `PLACEMENT_CENTRE=X,Z` decorates only that area (first seed), `PLACEMENT_STOP=N` only the first N
 * chunks of its order, and `LIVE_ONLY=ID,...` keeps only those structures' live cases.
 */
public class StructurePlacementOracle {
  public static void main(String[] args) throws Exception {
    var factory = ChunkOracle.factory();
    if (args[0].equals("verify")) {
      verify(Path.of(args[1]), Path.of(args[2]));
      return;
    }
    if (args[0].equals("verify-live")) {
      verifyLive(Path.of(args[1]), Path.of(args[2]));
      return;
    }
    var dimension = args.length > 2 ? args[2] : "overworld";
    DecorationOracle.selectDimension(dimension);
    String source = switch (dimension) {
      case "nether" -> "minecraft:nether";
      case "end" -> "minecraft:the_end";
      default -> "minecraft:overworld";
    };
    var structures = new TreeSet<>(Arrays.asList(args[1].split(",")));
    SupportOracle.bindFluidTags();
    var registries = StructureOracle.serverRegistries();
    DecorationOracle.REGISTRIES = registries;
    HolderGetter<Biome> biomeLookup = registries.lookupOrThrow(Registries.BIOME);
    var settings = registries.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(DecorationOracle.SETTINGS).value();
    DecorationOracle.SEA_LEVEL = settings.seaLevel();
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
    var heights = LevelHeightAccessor.create(DecorationOracle.MIN_Y, DecorationOracle.HEIGHT);

    if (args[1].equals("live")) {
      live(Path.of(args[0]), source, registries, factory, settings, picker, heights, biomeLookup, doFill, buildSurface,
          generateCarvers);
      return;
    }
    if (args[1].equals("bench")) {
      bench(Path.of(args[0]), source, registries, factory, settings, picker, heights, biomeLookup, doFill, buildSurface,
          generateCarvers, args.length > 3 ? Integer.parseInt(args[3]) : 4, args.length > 4 ? Integer.parseInt(args[4]) : 3);
      return;
    }
    var gen = new Random(20261020L);
    long[] seeds = {20261020L, -8172645723L, gen.nextLong()};
    var cases = new JsonArray();
    int startCount = 0;
    for (long seed : seeds) {
      var world = StructureOracle.World.create(seed, source, registries, factory);
      var state = world.state().randomState();
      var terrain = new DecorationOracle.Terrain(factory, seed, state, settings, picker, world.generator(), heights, biomeLookup,
          doFill, buildSurface, generateCarvers);
      var centres = new ArrayList<Map.Entry<String, ChunkPos>>();
      centres.add(Map.entry("", new ChunkPos(0, 0)));
      centres.add(Map.entry("", new ChunkPos(gen.nextInt(4001) - 2000, gen.nextInt(4001) - 2000)));
      var search = new Random(seed);
      for (var id : structures) {
        if (System.getenv("PLACEMENT_CENTRE") != null) break;
        var found = findStarts(world, id, seed == seeds[0] ? 2 : 1, search);
        for (int i = 0; i < found.size(); i++) {
          var box = found.get(i).getPieces().get(0).getBoundingBox();
          var centre = i == 0
              ? new ChunkPos(box.getCenter().getX() >> 4, box.getCenter().getZ() >> 4)
              : new ChunkPos((box.minX() >> 4) - 1, (box.minZ() >> 4) - 1);
          centres.add(Map.entry(id, centre));
        }
      }
      // `PLACEMENT_CENTRE=X,Z` (for debugging): only that area, on the first seed.
      var only = System.getenv("PLACEMENT_CENTRE");
      if (only != null) {
        if (seed != seeds[0]) continue;
        var xz = only.split(",");
        centres.clear();
        centres.add(Map.entry("", new ChunkPos(Integer.parseInt(xz[0]), Integer.parseInt(xz[1]))));
      }
      for (var entry : centres) {
        var row = decorate(world, terrain, entry.getValue(), structures, registries);
        row.addProperty("target", entry.getKey());
        startCount += row.getAsJsonArray("starts").size();
        cases.add(row);
      }
    }
    var out = new JsonObject();
    out.addProperty("dimension", DecorationOracle.DIMENSION);
    out.addProperty("noise_settings", DecorationOracle.SETTINGS.identifier().toString());
    out.addProperty("biome_source", DecorationOracle.biomeSourceId());
    out.addProperty("min_y", DecorationOracle.MIN_Y);
    out.addProperty("height", DecorationOracle.HEIGHT);
    var named = new JsonArray();
    structures.forEach(named::add);
    out.add("structures", named);
    out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla " + DecorationOracle.DIMENSION + " areas decorated with "
        + structures.size() + " structures (" + startCount + " starts) over " + seeds.length + " seeds");
  }

  /**
   * `verify FACTS.json OURS.json`: ValiMC's block entities (`check_decoration.exs` writes them: per
   * case and position the state, the type, the NBT a template gave and the loot table and seed)
   * each loaded into vanilla's block entity of that type and state and saved again, which must
   * equal the block entity vanilla's placement left there.
   */
  static void verify(Path factsPath, Path oursPath) throws Exception {
    var registries = StructureOracle.serverRegistries();
    var facts = JsonParser.parseString(Files.readString(factsPath)).getAsJsonObject();
    var ours = JsonParser.parseString(Files.readString(oursPath)).getAsJsonArray();
    var vanilla = new HashMap<String, String>();
    for (var area : facts.getAsJsonArray("cases")) {
      var seed = area.getAsJsonObject().get("seed").getAsString();
      for (var chunk : area.getAsJsonObject().getAsJsonArray("chunks")) {
        for (var entry : chunk.getAsJsonObject().getAsJsonArray("block_entity_nbt")) {
          var text = entry.getAsString();
          int split = nthComma(text, 3);
          vanilla.put(seed + ":" + area.getAsJsonObject().get("x") + ":" + area.getAsJsonObject().get("z") + ":"
              + text.substring(0, split), text.substring(split + 1));
        }
      }
    }
    int checked = 0;
    var failures = new ArrayList<String>();
    for (var element : ours) {
      var o = element.getAsJsonObject();
      var key = o.get("case").getAsString() + ":" + o.get("pos").getAsString();
      var p = o.get("pos").getAsString().split(",");
      var pos = new net.minecraft.core.BlockPos(Integer.parseInt(p[0]), Integer.parseInt(p[1]), Integer.parseInt(p[2]));
      var state = net.minecraft.world.level.block.Block.stateById(o.get("state").getAsInt());
      var tag = o.has("nbt") ? net.minecraft.nbt.TagParser.parseCompoundFully(o.get("nbt").getAsString())
          : new net.minecraft.nbt.CompoundTag();
      tag.putString("id", o.get("type").getAsString());
      if (o.has("loot_table")) {
        tag.putString("LootTable", o.get("loot_table").getAsString());
        tag.putLong("LootTableSeed", o.get("loot_seed").getAsLong());
      }
      var entity = net.minecraft.world.level.block.entity.BlockEntity.loadStatic(pos, state, tag, registries);
      var saved = entity == null ? "-" : StructureOracle.snbt(entity.saveWithoutMetadata(registries));
      var want = vanilla.remove(key);
      checked++;
      if (!saved.equals(want)) failures.add(key + "\n  ours:    " + saved + "\n  vanilla: " + want);
    }
    if (!failures.isEmpty()) {
      failures.stream().limit(8).forEach(System.out::println);
      throw new IllegalStateException(failures.size() + " block entities differ from vanilla's");
    }
    System.out.println("PASS: " + checked + " block entities save as vanilla's");
  }

  static int nthComma(String text, int n) {
    int at = -1;
    for (int i = 0; i < n; i++) at = text.indexOf(',', at + 1);
    return at;
  }

  /**
   * Up to `wanted` starts of a structure: from a seeded search over its sets' random spread
   * placement chunks within 30,000 chunks, each through vanilla's `createStructures`.
   */
  static List<StructureStart> findStarts(StructureOracle.World world, String id, int wanted, Random search) {
    var structure = world.registries().lookupOrThrow(Registries.STRUCTURE)
        .getOrThrow(net.minecraft.resources.ResourceKey.create(Registries.STRUCTURE, net.minecraft.resources.Identifier.parse(id)))
        .value();
    var found = new ArrayList<StructureStart>();
    for (var set : world.state().possibleStructureSets()) {
      if (set.value().structures().stream().noneMatch(e -> e.structure().value() == structure)) continue;
      // Concentric rings (strongholds): the ring positions in their order.
      if (set.value().placement() instanceof net.minecraft.world.level.levelgen.structure.placement.ConcentricRingsStructurePlacement rings) {
        for (var candidate : world.state().getRingPositionsFor(rings)) {
          if (found.size() >= wanted) break;
          var start = world.createStructures(candidate.x(), candidate.z()).getStartForStructure(structure);
          if (start != null && start.isValid()) found.add(start);
        }
        continue;
      }
      if (!(set.value().placement() instanceof RandomSpreadStructurePlacement placement)) continue;
      for (int draw = 0; draw < 200_000 && found.size() < wanted; draw++) {
        int x = search.nextInt(60_001) - 30_000, z = search.nextInt(60_001) - 30_000;
        var candidate = placement.getPotentialStructureChunk(world.seed(), x, z);
        if (!placement.isStructureChunk(world.state(), candidate.x(), candidate.z())) continue;
        var start = world.createStructures(candidate.x(), candidate.z()).getStartForStructure(structure);
        if (start != null && start.isValid()) found.add(start);
      }
    }
    if (found.isEmpty()) throw new IllegalStateException("no start of " + id);
    return found;
  }

  /** One case: starts, references, terrain and vanilla's decoration of the 3 × 3 around `centre`. */
  static JsonObject decorate(StructureOracle.World world, DecorationOracle.Terrain terrain, ChunkPos centre,
      Set<String> structures, RegistryAccess registries) throws ReflectiveOperationException {
    var holding = new HashMap<ChunkPos, ProtoChunk>();
    var starts = new TreeSet<String>();
    for (int dz = -10; dz <= 10; dz++) {
      for (int dx = -10; dx <= 10; dx++) {
        var chunk = world.createStructures(centre.x() + dx, centre.z() + dz);
        var kept = new HashMap<Structure, StructureStart>();
        chunk.getAllStarts().forEach((structure, start) -> {
          if (structures.contains(world.ids().get(structure))) kept.put(structure, start);
        });
        chunk.setAllStarts(kept);
        holding.put(chunk.getPos(), chunk);
      }
    }
    var startsLevel = StructureOracle.areaLevel(holding);
    for (int dz = -2; dz <= 2; dz++) {
      for (int dx = -2; dx <= 2; dx++) {
        world.generator().createReferences(startsLevel, world.manager(), holding.get(new ChunkPos(centre.x() + dx, centre.z() + dz)));
      }
    }
    // The structure manager's level: the chunks holding starts and references.
    var managerLevel = (LevelAccessor) Proxy.newProxyInstance(StructurePlacementOracle.class.getClassLoader(),
        new Class<?>[] {LevelAccessor.class}, (proxy, method, a) -> switch (method.getName()) {
          case "getChunk" -> {
            var chunk = holding.get(new ChunkPos((Integer) a[0], (Integer) a[1]));
            if (chunk == null) throw new IllegalStateException("no structure chunk " + a[0] + ", " + a[1]);
            yield chunk;
          }
          case "registryAccess" -> registries;
          default -> throw new UnsupportedOperationException("LevelAccessor." + method.getName());
        });
    var manager = new StructureManager(managerLevel, new WorldOptions(world.seed(), true, false), null);
    // Terrain with each chunk's beards, from the starts that reference it (VMC-025f3).
    var chunks = terrain.area(centre, 2, pos -> net.minecraft.world.level.levelgen.Beardifier.forStructuresInChunk(manager, pos));
    var order = new JsonArray();
    // `PLACEMENT_STOP=N` (for debugging): only the first N chunks of the order.
    int stop = System.getenv("PLACEMENT_STOP") == null ? 9 : Integer.parseInt(System.getenv("PLACEMENT_STOP"));
    for (int dz = -1; dz <= 1; dz++) {
      for (int dx = -1; dx <= 1; dx++) {
        if (order.size() >= stop) break;
        var pos = new ChunkPos(centre.x() + dx, centre.z() + dz);
        var region = new PlacementRegion(chunks, pos, world.seed(), terrain.state(), world.generator().getBiomeSource(), registries,
            manager);
        region.registries = registries;
        region.generator = world.generator();
        world.generator().applyBiomeDecoration(region, chunks.get(pos), manager);
        var p = new JsonArray();
        p.add(pos.x());
        p.add(pos.z());
        order.add(p);
      }
    }
    var rows = new JsonArray();
    chunks.forEach((pos, chunk) -> {
      var row = DecorationOracle.chunkJson(pos, chunk);
      // Each block entity as it saves (canonical SNBT), which `verify` compares.
      var saved = new TreeSet<String>();
      chunk.getBlockEntities().forEach((p, entity) -> saved.add(p.getX() + "," + p.getY() + "," + p.getZ() + ","
          + StructureOracle.snbt(entity.saveWithoutMetadata(registries))));
      row.add("block_entity_nbt", new Gson().toJsonTree(saved));
      rows.add(row);
    });
    holding.forEach((pos, chunk) -> chunk.getAllStarts().values().forEach(start ->
        starts.add(StructureOracle.snbt(start.createTag(world.context(), pos)))));
    var row = new JsonObject();
    row.addProperty("seed", Long.toString(world.seed()));
    row.addProperty("x", centre.x());
    row.addProperty("z", centre.z());
    row.add("order", order);
    row.add("chunks", rows);
    row.add("starts", new Gson().toJsonTree(starts));
    return row;
  }

  /** Structures whose first start gets live regions of its own, per dimension. */
  static final Map<String, List<String>> LIVE_TARGETS = Map.of(
      "overworld", List.of("minecraft:village_plains", "minecraft:village_desert", "minecraft:desert_pyramid",
          "minecraft:jungle_pyramid", "minecraft:swamp_hut", "minecraft:igloo", "minecraft:mineshaft", "minecraft:ruined_portal",
          "minecraft:shipwreck", "minecraft:ocean_ruin_warm", "minecraft:ocean_ruin_cold", "minecraft:buried_treasure",
          "minecraft:stronghold", "minecraft:monument", "minecraft:pillager_outpost", "minecraft:trail_ruins",
          "minecraft:trial_chambers", "minecraft:ancient_city", "minecraft:mansion"),
      "nether", List.of("minecraft:fortress", "minecraft:bastion_remnant", "minecraft:ruined_portal_nether",
          "minecraft:nether_fossil"),
      "end", List.of("minecraft:end_city"));

  /**
   * `OUT live [nether|end]` (VMC-025f5): ValiMC's live generation with structures, as
   * `DecorationOracle live` writes it for `check_live_decoration.exs` (regions finalized one after
   * the other: terrain of the 12 × 12 chunks around each, then its undecorated chunks of the
   * 10 × 10 decorated, Z outer and X inner), on seed 20261020 in a fresh world per case. Starts
   * come from vanilla's `createStructures` and references from `createReferences`, each chunk's
   * terrain has its beards, and `applyBiomeDecoration` places structures through a
   * `StructureManager` whose level serves those chunks, as `decorate` does. Before a region's
   * chunks are decorated, the temples and huts they place have their height settled as ValiMC's
   * live generation settles it (`settle`).
   *
   * Cases: the regions at the origin, then per structure of `LIVE_TARGETS` the region holding the
   * first piece of its first start (`findStarts`) and the region of the start's far corner (or
   * near corner, or the next one east), so that the structure crosses the border between them.
   * Every chunk also lists its block entities as they save (`block_entity_nbt`), for `verifyLive`.
   */
  static void live(Path out, String source, RegistryAccess registries, net.minecraft.world.level.chunk.PalettedContainerFactory factory,
      NoiseGeneratorSettings settings, Aquifer.FluidPicker picker, LevelHeightAccessor heights, HolderGetter<Biome> biomeLookup,
      Method doFill, Method buildSurface, Method generateCarvers) throws Exception {
    final int region = DecorationOracle.REGION;
    long seed = 20261020L;
    var cases = new ArrayList<List<ChunkPos>>();
    cases.add(DecorationOracle.DIMENSION.equals("end") ? List.of(new ChunkPos(0, 0))
        : List.of(new ChunkPos(0, 0), new ChunkPos(1, 0), new ChunkPos(1, 1)));
    var names = new ArrayList<String>();
    names.add("");
    // `LIVE_ONLY=ID,ID` (for debugging): only those structures' cases.
    var only = System.getenv("LIVE_ONLY");
    if (only != null) {
      cases.clear();
      names.clear();
    }
    var searchWorld = StructureOracle.World.create(seed, source, registries, factory);
    var search = new Random(seed);
    for (var id : LIVE_TARGETS.get(DecorationOracle.DIMENSION)) {
      var start = findStarts(searchWorld, id, 1, search).get(0);
      var first = start.getPieces().get(0).getBoundingBox().getCenter();
      var box = start.getBoundingBox();
      var a = new ChunkPos(Math.floorDiv(first.getX() >> 4, region), Math.floorDiv(first.getZ() >> 4, region));
      var b = new ChunkPos(Math.floorDiv(box.maxX() >> 4, region), Math.floorDiv(box.maxZ() >> 4, region));
      if (b.equals(a)) b = new ChunkPos(Math.floorDiv(box.minX() >> 4, region), Math.floorDiv(box.minZ() >> 4, region));
      if (b.equals(a)) b = new ChunkPos(a.x() + 1, a.z());
      if (only != null && !List.of(only.split(",")).contains(id)) continue;
      cases.add(List.of(a, b));
      names.add(id);
    }
    // A mineshaft (start at chunk 8, -8) whose spider corridors each cross from one region's
    // decorated chunks into the next one's: its spawner flag must carry over (VMC-025f6).
    if (DecorationOracle.DIMENSION.equals("overworld") && (only == null || List.of(only.split(",")).contains("spider"))) {
      cases.add(List.of(new ChunkPos(0, -2), new ChunkPos(1, -2), new ChunkPos(1, -1)));
      names.add("mineshaft spider corridors");
    }
    var rows = new JsonArray();
    long blocks = 0;
    int entities = 0, settled = 0;
    for (int index = 0; index < cases.size(); index++) {
      var regions = cases.get(index);
      var world = StructureOracle.World.create(seed, source, registries, factory);
      var state = world.state().randomState();
      var terrain = new DecorationOracle.Terrain(factory, seed, state, settings, picker, world.generator(), heights, biomeLookup,
          doFill, buildSurface, generateCarvers);
      // Chunks with their starts, and those also with their references, made when first asked for.
      var holding = new HashMap<ChunkPos, ProtoChunk>();
      var referenced = new HashSet<ChunkPos>();
      var startsLevel = StructureOracle.areaLevel(holding);
      java.util.function.Function<ChunkPos, ProtoChunk> withStarts =
          p -> holding.computeIfAbsent(p, q -> world.createStructures(q.x(), q.z()));
      java.util.function.Function<ChunkPos, ProtoChunk> withReferences = p -> {
        if (referenced.add(p)) {
          for (int dz = -8; dz <= 8; dz++) {
            for (int dx = -8; dx <= 8; dx++) withStarts.apply(new ChunkPos(p.x() + dx, p.z() + dz));
          }
          world.generator().createReferences(startsLevel, world.manager(), holding.get(p));
        }
        return holding.get(p);
      };
      var managerLevel = (LevelAccessor) Proxy.newProxyInstance(StructurePlacementOracle.class.getClassLoader(),
          new Class<?>[] {LevelAccessor.class}, (proxy, method, a) -> switch (method.getName()) {
            case "getChunk" -> {
              var pos = new ChunkPos((Integer) a[0], (Integer) a[1]);
              boolean startsOnly = a.length > 2 && a[2] == net.minecraft.world.level.chunk.status.ChunkStatus.STRUCTURE_STARTS;
              yield startsOnly ? withStarts.apply(pos) : withReferences.apply(pos);
            }
            case "registryAccess" -> registries;
            default -> throw new UnsupportedOperationException("LevelAccessor." + method.getName());
          });
      var manager = new StructureManager(managerLevel, new WorldOptions(seed, true, false), null);
      java.util.function.Function<ChunkPos, net.minecraft.world.level.levelgen.Beardifier> beards =
          p -> net.minecraft.world.level.levelgen.Beardifier.forStructuresInChunk(manager, p);
      var area = new LinkedHashSet<ChunkPos>();
      for (var r : regions) area.addAll(DecorationOracle.around(r, 2));
      var chunks = terrain.build(area, beards);
      // Columns past the area (a temple at its edge) from the same terrain.
      var outside = new HashMap<ChunkPos, ProtoChunk>();
      java.util.function.IntBinaryOperator height = (x, z) -> {
        var p = new ChunkPos(x >> 4, z >> 4);
        var chunk = chunks.containsKey(p) ? chunks.get(p) : outside.computeIfAbsent(p, q -> {
          try {
            return terrain.build(List.of(q), beards).get(q);
          } catch (ReflectiveOperationException e) {
            throw new IllegalStateException(e);
          }
        });
        return chunk.getHeight(net.minecraft.world.level.levelgen.Heightmap.Types.WORLD_SURFACE_WG, x & 15, z & 15) + 1;
      };
      var decorated = new HashSet<ChunkPos>();
      var order = new JsonArray();
      for (var r : regions) {
        var regionOrder = new ArrayList<ChunkPos>();
        for (var pos : DecorationOracle.around(r, 1)) if (decorated.add(pos)) regionOrder.add(pos);
        settled += settle(regionOrder, seed, withStarts, height);
        for (var pos : regionOrder) {
          var decoration = new PlacementRegion(chunks, pos, seed, state, world.generator().getBiomeSource(), registries, manager);
          decoration.registries = registries;
          decoration.generator = world.generator();
          world.generator().applyBiomeDecoration(decoration, chunks.get(pos), manager);
          var p = new JsonArray();
          p.add(pos.x());
          p.add(pos.z());
          order.add(p);
        }
      }
      var regionRows = new JsonArray();
      for (var r : regions) {
        var finalChunks = new JsonArray();
        for (var pos : DecorationOracle.around(r, 0)) {
          var chunk = chunks.get(pos);
          var row = DecorationOracle.chunkJson(pos, chunk);
          var nbt = new TreeMap<String, String>();
          for (var be : chunk.getBlockEntities().values()) nbt.put(DecorationOracle.key(be.getBlockPos()), DecorationOracle.encode(be));
          for (var bp : chunk.getBlockEntityNbts().keySet()) {
            var blockState = chunk.getBlockState(bp);
            if (blockState.getBlock() instanceof net.minecraft.world.level.block.EntityBlock eb) {
              var be = eb.newBlockEntity(bp, blockState);
              if (be != null) nbt.put(DecorationOracle.key(bp), DecorationOracle.encode(be));
            }
          }
          entities += nbt.size();
          var list = new JsonArray();
          nbt.forEach((k, v) -> list.add(k + "," + v));
          row.add("nbt", list);
          finalChunks.add(row);
          blocks += 16 * 16 * DecorationOracle.HEIGHT;
        }
        var json = new JsonObject();
        json.addProperty("x", r.x());
        json.addProperty("z", r.z());
        json.add("chunks", finalChunks);
        regionRows.add(json);
      }
      var row = new JsonObject();
      row.addProperty("seed", Long.toString(seed));
      row.addProperty("noise_settings", world.settingsId());
      row.addProperty("target", names.get(index));
      row.add("order", order);
      row.add("regions", regionRows);
      rows.add(row);
    }
    var result = new JsonObject();
    result.addProperty("region_size", region);
    result.addProperty("dimension", DecorationOracle.DIMENSION);
    result.addProperty("min_y", DecorationOracle.MIN_Y);
    result.addProperty("height", DecorationOracle.HEIGHT);
    result.addProperty("structures", true);
    result.add("defaults", new JsonArray());
    result.add("cases", rows);
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: " + DecorationOracle.DIMENSION + ": " + cases.size() + " live generation sequences with structures ("
        + blocks + " blocks of final chunks, " + entities + " block entities, " + settled + " temple heights settled)");
  }

  /**
   * `OUT bench overworld [N] [PASSES]` (VMC-025f5): vanilla's full generation with structures on
   * one thread over the area of `bench/worldgen_live.exs` (seed 20261020, N × N regions, each pass
   * on regions of its own after one warm-up pass): starts (`createStructures`) of every chunk
   * within 8 of the terrain area, references (`createReferences`) and terrain with beards of the
   * (8N + 4)² chunks around the regions, then `applyBiomeDecoration` with structures of the
   * (8N + 2)², Z outer and X inner. Written: per pass each stage's nanoseconds.
   */
  static void bench(Path out, String source, RegistryAccess registries, net.minecraft.world.level.chunk.PalettedContainerFactory factory,
      NoiseGeneratorSettings settings, Aquifer.FluidPicker picker, LevelHeightAccessor heights, HolderGetter<Biome> biomeLookup,
      Method doFill, Method buildSurface, Method generateCarvers, int n, int passes) throws Exception {
    long seed = 20261020L;
    int side = 8 * n;
    var rows = new JsonArray();
    for (int pass = 0; pass <= passes; pass++) {
      int x0 = pass * (n + 4) * 8;
      var world = StructureOracle.World.create(seed, source, registries, factory);
      var state = world.state().randomState();
      var terrain = new DecorationOracle.Terrain(factory, seed, state, settings, picker, world.generator(), heights, biomeLookup,
          doFill, buildSurface, generateCarvers);
      long t0 = System.nanoTime();
      var holding = new HashMap<ChunkPos, ProtoChunk>();
      for (int z = -2 - 8; z < side + 2 + 8; z++) {
        for (int x = x0 - 2 - 8; x < x0 + side + 2 + 8; x++) holding.put(new ChunkPos(x, z), world.createStructures(x, z));
      }
      long t1 = System.nanoTime();
      var startsLevel = StructureOracle.areaLevel(holding);
      var area = new ArrayList<ChunkPos>();
      for (int z = -2; z < side + 2; z++) {
        for (int x = x0 - 2; x < x0 + side + 2; x++) area.add(new ChunkPos(x, z));
      }
      for (var pos : area) world.generator().createReferences(startsLevel, world.manager(), holding.get(pos));
      long t2 = System.nanoTime();
      var managerLevel = (LevelAccessor) Proxy.newProxyInstance(StructurePlacementOracle.class.getClassLoader(),
          new Class<?>[] {LevelAccessor.class}, (proxy, method, a) -> switch (method.getName()) {
            case "getChunk" -> holding.get(new ChunkPos((Integer) a[0], (Integer) a[1]));
            case "registryAccess" -> registries;
            default -> throw new UnsupportedOperationException("LevelAccessor." + method.getName());
          });
      var manager = new StructureManager(managerLevel, new WorldOptions(seed, true, false), null);
      var chunks = terrain.build(area, p -> net.minecraft.world.level.levelgen.Beardifier.forStructuresInChunk(manager, p));
      long t3 = System.nanoTime();
      for (int z = -1; z < side + 1; z++) {
        for (int x = x0 - 1; x < x0 + side + 1; x++) {
          var pos = new ChunkPos(x, z);
          var decoration = new PlacementRegion(chunks, pos, seed, state, world.generator().getBiomeSource(), registries, manager);
          decoration.registries = registries;
          decoration.generator = world.generator();
          world.generator().applyBiomeDecoration(decoration, chunks.get(pos), manager);
        }
      }
      long t4 = System.nanoTime();
      double seconds = (t4 - t0) / 1e9;
      System.out.printf("pass %d: %.2f s, %d final chunks/s (starts %.2f s, references %.2f s, terrain %.2f s, decoration %.2f s)%n",
          pass, seconds, Math.round(side * side / seconds), (t1 - t0) / 1e9, (t2 - t1) / 1e9, (t3 - t2) / 1e9, (t4 - t3) / 1e9);
      if (pass == 0) continue;
      var row = new JsonObject();
      row.addProperty("starts_ns", t1 - t0);
      row.addProperty("references_ns", t2 - t1);
      row.addProperty("terrain_ns", t3 - t2);
      row.addProperty("decoration_ns", t4 - t3);
      row.addProperty("total_ns", t4 - t0);
      rows.add(row);
    }
    var result = new JsonObject();
    result.addProperty("regions", n * n);
    result.addProperty("final", side * side);
    result.addProperty("terrain", (side + 4) * (side + 4));
    result.addProperty("decorated", (side + 2) * (side + 2));
    result.add("passes", rows);
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: vanilla full generation with structures for " + n + " × " + n + " regions");
  }

  /**
   * ValiMC's live height of temples and huts (`scattered::settle_live`): every desert pyramid,
   * jungle temple and swamp hut piece a chunk of `order` places and that has no height yet settles
   * on the terrain's `WORLD_SURFACE_WG` heights over its whole box (`height`: the first free Y), at
   * the lowest for a desert pyramid (lowered by `nextInt(3)` of a legacy random seeded from the
   * world seed and the start's chunk), at the mean for the others. The count settled.
   */
  static int settle(List<ChunkPos> order, long seed, java.util.function.Function<ChunkPos, ProtoChunk> withStarts,
      java.util.function.IntBinaryOperator height) throws ReflectiveOperationException {
    var field = net.minecraft.world.level.levelgen.structure.ScatteredFeaturePiece.class.getDeclaredField("heightPosition");
    field.setAccessible(true);
    int x0 = Integer.MAX_VALUE, x1 = Integer.MIN_VALUE, z0 = Integer.MAX_VALUE, z1 = Integer.MIN_VALUE;
    for (var p : order) {
      x0 = Math.min(x0, p.x()); x1 = Math.max(x1, p.x());
      z0 = Math.min(z0, p.z()); z1 = Math.max(z1, p.z());
    }
    int count = 0;
    for (int sz = z0 - 8; sz <= z1 + 8; sz++) {
      for (int sx = x0 - 8; sx <= x1 + 8; sx++) {
        for (var start : withStarts.apply(new ChunkPos(sx, sz)).getAllStarts().values()) {
          for (var piece : start.getPieces()) {
            if (!(piece instanceof net.minecraft.world.level.levelgen.structure.ScatteredFeaturePiece scattered)) continue;
            var box = scattered.getBoundingBox();
            boolean placed = order.stream().anyMatch(p -> box.intersects(p.getMinBlockX(), p.getMinBlockZ(), p.getMaxBlockX(),
                p.getMaxBlockZ()));
            if (field.getInt(scattered) >= 0 || !placed) continue;
            int lowest = Integer.MAX_VALUE, total = 0, columns = 0;
            for (int z = box.minZ(); z <= box.maxZ(); z++) {
              for (int x = box.minX(); x <= box.maxX(); x++) {
                int h = height.applyAsInt(x, z);
                lowest = Math.min(lowest, h);
                total += h;
                columns++;
              }
            }
            int settledAt, offset = 0;
            if (scattered instanceof net.minecraft.world.level.levelgen.structure.structures.DesertPyramidPiece) {
              settledAt = lowest;
              var chunk = start.getChunkPos();
              offset = -new net.minecraft.world.level.levelgen.LegacyRandomSource(
                  seed ^ (chunk.x() * 341873128712L) ^ (chunk.z() * 132897987541L)).nextInt(3);
            } else {
              settledAt = total / columns;
            }
            field.setInt(scattered, settledAt);
            scattered.move(0, settledAt - box.minY() + offset, 0);
            count++;
          }
        }
      }
    }
    return count;
  }

  /**
   * `verify-live FACTS.json OURS.json`: ValiMC's block entities that a structure template gave
   * their NBT (`check_live_decoration.exs` writes them: per case index and position the state and
   * the compound the region stores, as binary NBT in base64), each loaded into vanilla's block
   * entity of that state and saved with full metadata again, which must equal vanilla's full chunk
   * save of the block entity at that position.
   */
  static void verifyLive(Path factsPath, Path oursPath) throws Exception {
    var registries = StructureOracle.serverRegistries();
    var facts = JsonParser.parseString(Files.readString(factsPath)).getAsJsonObject();
    var ours = JsonParser.parseString(Files.readString(oursPath)).getAsJsonArray();
    var vanilla = new HashMap<String, String>();
    var cases = facts.getAsJsonArray("cases");
    for (int i = 0; i < cases.size(); i++) {
      for (var r : cases.get(i).getAsJsonObject().getAsJsonArray("regions")) {
        for (var chunk : r.getAsJsonObject().getAsJsonArray("chunks")) {
          for (var entry : chunk.getAsJsonObject().getAsJsonArray("nbt")) {
            var text = entry.getAsString();
            int split = nthComma(text, 3);
            vanilla.put(i + ":" + text.substring(0, split), text.substring(split + 1));
          }
        }
      }
    }
    int checked = 0;
    var failures = new ArrayList<String>();
    for (var element : ours) {
      var o = element.getAsJsonObject();
      var key = o.get("case").getAsInt() + ":" + o.get("pos").getAsString();
      var p = o.get("pos").getAsString().split(",");
      var pos = new BlockPos(Integer.parseInt(p[0]), Integer.parseInt(p[1]), Integer.parseInt(p[2]));
      var state = net.minecraft.world.level.block.Block.stateById(o.get("state").getAsInt());
      var tag = read(o.get("nbt").getAsString());
      var entity = net.minecraft.world.level.block.entity.BlockEntity.loadStatic(pos, state, tag, registries);
      var saved = entity == null ? "-" : StructureOracle.snbt(entity.saveWithFullMetadata(registries));
      var encoded = vanilla.get(key);
      var want = encoded == null ? "none" : StructureOracle.snbt(read(encoded));
      checked++;
      if (!saved.equals(want)) failures.add(key + "\n  ours:    " + saved + "\n  vanilla: " + want);
    }
    if (!failures.isEmpty()) {
      failures.stream().limit(8).forEach(System.out::println);
      throw new IllegalStateException(failures.size() + " block entities differ from vanilla's");
    }
    System.out.println("PASS: " + checked + " template block entities save as vanilla's");
  }

  static net.minecraft.nbt.CompoundTag read(String base64) throws java.io.IOException {
    return net.minecraft.nbt.NbtIo.read(new java.io.DataInputStream(new java.io.ByteArrayInputStream(
        java.util.Base64.getDecoder().decode(base64))));
  }

  /**
   * `DecorationOracle`'s region, with a normal difficulty for structure pieces' mobs, and a server
   * level that also holds the structure manager and the registries.
   */
  static final class PlacementRegion extends DecorationOracle.Region {
    final StructureManager manager;

    PlacementRegion(Map<ChunkPos, ProtoChunk> chunks, ChunkPos center, long seed, RandomState state, BiomeSource biomeSource,
        HolderGetter.Provider lookup, StructureManager manager) {
      super(chunks, center, seed, state, biomeSource, lookup);
      this.manager = manager;
    }

    @Override public net.minecraft.world.DifficultyInstance getCurrentDifficultyAt(BlockPos pos) {
      return new net.minecraft.world.DifficultyInstance(net.minecraft.world.Difficulty.NORMAL, 0L, 0L, 0.0F);
    }

    // A cat's variant reads the moon phase: the attributes' defaults.
    @Override public net.minecraft.world.attribute.EnvironmentAttributeReader environmentAttributes() {
      return net.minecraft.world.attribute.EnvironmentAttributeReader.EMPTY;
    }

    @Override public net.minecraft.server.level.ServerLevel getLevel() {
      if (serverLevel == null) {
        var level = super.getLevel();
        try {
          set(level, net.minecraft.server.level.ServerLevel.class, "structureManager", manager);
          set(level, net.minecraft.world.level.Level.class, "registryAccess", registries);
          // Capped processors ask the level for the world's seed, which its server keeps.
          set(level.getServer(), net.minecraft.server.MinecraftServer.class, "worldGenSettings",
              new net.minecraft.world.level.levelgen.WorldGenSettings(new WorldOptions(seed, true, false), null));
          // A villager's brain reads its schedule from the level's environment attributes: their
          // defaults.
          ((net.minecraft.server.level.ServerLevel) level).setEnvironmentAttributes(
              net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build());
          // Creating a mob asks the level's difficulty.
          set(level, net.minecraft.world.level.Level.class, "levelData", Proxy.newProxyInstance(
              StructurePlacementOracle.class.getClassLoader(), new Class<?>[] {net.minecraft.world.level.storage.WritableLevelData.class},
              (proxy, method, a) -> switch (method.getName()) {
                case "getDifficulty" -> net.minecraft.world.Difficulty.NORMAL;
                case "getGameTime" -> 0L;
                case "isHardcore", "isDifficultyLocked" -> false;
                default -> throw new UnsupportedOperationException("LevelData." + method.getName());
              }));
        } catch (ReflectiveOperationException e) {
          throw new IllegalStateException(e);
        }
      }
      return serverLevel;
    }
  }
}
