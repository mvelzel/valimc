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
 * For each case (seed, centre chunk) the starts of the 19 × 19 chunks around the centre come from
 * vanilla's `createStructures` (as `StructureOracle` makes them, kept only for the structures
 * named), each chunk of the 3 × 3 around the centre gets its references from vanilla's
 * `createReferences`, and the 5 × 5 chunks around the centre get their terrain as
 * `DecorationOracle` builds it. The 3 × 3 chunks are then decorated in order (Z outer, X inner)
 * by vanilla's own `applyBiomeDecoration` with every placed feature, through `DecorationOracle`'s
 * region and a `StructureManager` (structures on) whose level serves the chunks holding the starts
 * and references. Structure pieces that ask the region for the current difficulty get a normal
 * one, and for environment attributes their defaults; the server level the region hands out holds
 * that structure manager (a swamp hut's cat asks whether it stands in a structure).
 *
 * Cases: per seed (`DecorationOracle`'s seeds) an area at the origin and one within 2,000 chunks,
 * and per structure named, areas whose centre holds that structure's first piece (a start found
 * through its set's placement from a seeded search), on the first seed two of them (the second
 * with the centre one chunk short of the piece's lowest corner, so that the structure reaches past
 * the decorated chunks), on the others one.
 *
 * Usage: StructurePlacementOracle OUT STRUCTURE,STRUCTURE,... [nether|end]. Output: as
 * `DecorationOracle`'s (dimension, settings, every placed feature, per case the chunks), with the
 * structures named and per case the structure it targets (or none) and every start of the 19 × 19
 * as placement left it (`StructureStart.createTag`, canonical SNBT, sorted).
 */
public class StructurePlacementOracle {
  public static void main(String[] args) throws Exception {
    var factory = ChunkOracle.factory();
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
        var found = findStarts(world, id, seed == seeds[0] ? 2 : 1, search);
        for (int i = 0; i < found.size(); i++) {
          var box = found.get(i).getPieces().get(0).getBoundingBox();
          var centre = i == 0
              ? new ChunkPos(box.getCenter().getX() >> 4, box.getCenter().getZ() >> 4)
              : new ChunkPos((box.minX() >> 4) - 1, (box.minZ() >> 4) - 1);
          centres.add(Map.entry(id, centre));
        }
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
    for (int dz = -9; dz <= 9; dz++) {
      for (int dx = -9; dx <= 9; dx++) {
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
    for (int dz = -1; dz <= 1; dz++) {
      for (int dx = -1; dx <= 1; dx++) {
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
    var chunks = terrain.area(centre, 2);
    var order = new JsonArray();
    for (int dz = -1; dz <= 1; dz++) {
      for (int dx = -1; dx <= 1; dx++) {
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
    chunks.forEach((pos, chunk) -> rows.add(DecorationOracle.chunkJson(pos, chunk)));
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
