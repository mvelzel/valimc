import com.google.gson.*;
import com.mojang.datafixers.util.Pair;
import it.unimi.dsi.fastutil.objects.Object2ObjectArrayMap;
import it.unimi.dsi.fastutil.objects.ObjectArraySet;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.CompletableFuture;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.core.HolderSet;
import net.minecraft.core.BlockPos.MutableBlockPos;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.SectionPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LevelReader;
import net.minecraft.world.level.StructureManager;
import net.minecraft.world.level.chunk.ChunkGenerator;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.chunk.storage.ChunkScanAccess;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.levelgen.structure.StructureCheck;
import net.minecraft.world.level.levelgen.structure.placement.ConcentricRingsStructurePlacement;
import net.minecraft.world.level.levelgen.structure.placement.RandomSpreadStructurePlacement;
import net.minecraft.world.level.levelgen.structure.placement.StructurePlacement;

/**
 * `/locate structure` (VMC-053o): vanilla's nearest structure for seeds, positions and every
 * structure and structure tag of the overworld, as `findNearestMapStructure(level, target, pos,
 * 100, false)` finds it.
 *
 * That method needs a server level only for the generator state and structure manager, so its
 * driver is restated here and the searches are vanilla's own: the private static random spread
 * ring search and `getStructureGeneratingAt`, called reflectively, with a real `StructureCheck`
 * over empty chunk storage and fresh proto chunks for the chunks it loads (`StructureOracle`).
 *
 * `cases OUT.json`: rows of seed, position, target (`minecraft:x` or `#minecraft:tag`) and the
 * result `[x, y, z, structure]` or null. `facts`: the structure identifiers and each structure
 * tag's members in holder set order, for `priv/commands/facts.json`.
 */
public class LocateOracle {
  static final int RADIUS = 100;
  static final Method SPIRAL, GENERATING_AT;

  static {
    try {
      SPIRAL = ChunkGenerator.class.getDeclaredMethod("getNearestGeneratedStructure", Set.class, LevelReader.class,
          StructureManager.class, int.class, int.class, int.class, boolean.class, long.class,
          RandomSpreadStructurePlacement.class);
      SPIRAL.setAccessible(true);
      GENERATING_AT = ChunkGenerator.class.getDeclaredMethod("getStructureGeneratingAt", Set.class, LevelReader.class,
          StructureManager.class, boolean.class, StructurePlacement.class, ChunkPos.class);
      GENERATING_AT.setAccessible(true);
    } catch (ReflectiveOperationException e) {
      throw new ExceptionInInitializerError(e);
    }
  }

  public static void main(String[] args) throws Exception {
    switch (args[0]) {
      case "cases" -> cases(Path.of(args[1]));
      default -> throw new IllegalArgumentException(args[0]);
    }
  }

  /** Structure identifiers (sorted) and tags with their members in holder set order. */
  static JsonObject facts(RegistryAccess registries) {
    var out = new JsonObject();
    var registry = registries.lookupOrThrow(Registries.STRUCTURE);
    var ids = new JsonArray();
    registry.listElementIds().map(k -> k.identifier().toString()).sorted().forEach(ids::add);
    out.add("structures", ids);
    var tags = new TreeMap<String, JsonArray>();
    registry.listTags().forEach(tag -> {
      var members = new JsonArray();
      tag.forEach(h -> members.add(h.unwrapKey().orElseThrow().identifier().toString()));
      tags.put(tag.key().location().toString(), members);
    });
    var tagJson = new JsonObject();
    tags.forEach(tagJson::add);
    out.add("structure_tags", tagJson);
    return out;
  }

  /** One seed's overworld: the generator state and a structure manager over fresh chunks. */
  record Level(StructureOracle.World world, StructureManager manager, LevelReader reader) {
    static Level create(StructureOracle.World world) {
      ChunkScanAccess storage = (pos, visitor) -> CompletableFuture.completedFuture(null);
      var check = new StructureCheck(storage, world.registries(), world.templates(), world.level(), world.generator(),
          world.state().randomState(), world.heights(), world.generator().getBiomeSource(), world.seed(), null);
      var chunks = new HashMap<ChunkPos, ProtoChunk>();
      var reader = (LevelReader) Proxy.newProxyInstance(LocateOracle.class.getClassLoader(), new Class<?>[] {LevelReader.class},
          (proxy, method, args) -> switch (method.getName()) {
            case "getChunk" -> {
              if (args.length < 2 || !(args[0] instanceof Integer x) || !(args[1] instanceof Integer z)) {
                throw new UnsupportedOperationException("getChunk" + Arrays.toString(args));
              }
              yield chunks.computeIfAbsent(new ChunkPos(x, z), p -> world.createStructures(x, z));
            }
            default -> throw new UnsupportedOperationException("LevelReader." + method.getName());
          });
      return new Level(world, new StructureManager(null, new WorldOptions(world.seed(), true, false), check), reader);
    }

    /** `ChunkGenerator.findNearestMapStructure` with `createReference` false. */
    @SuppressWarnings("unchecked")
    Pair<BlockPos, Holder<Structure>> locate(HolderSet<Structure> wanted, BlockPos pos) throws Exception {
      var state = world.state();
      Map<StructurePlacement, Set<Holder<Structure>>> scans = new Object2ObjectArrayMap<>();
      for (var structure : wanted) {
        for (var placement : state.getPlacementsForStructure(structure)) {
          scans.computeIfAbsent(placement, p -> new ObjectArraySet<>()).add(structure);
        }
      }
      if (scans.isEmpty()) return null;
      Pair<BlockPos, Holder<Structure>> nearest = null;
      double nearestDist = Double.MAX_VALUE;
      var spread = new ArrayList<Map.Entry<StructurePlacement, Set<Holder<Structure>>>>();
      for (var entry : scans.entrySet()) {
        if (entry.getKey() instanceof ConcentricRingsStructurePlacement rings) {
          Pair<BlockPos, Holder<Structure>> closest = null;
          double closestDist = Double.MAX_VALUE;
          var structurePos = new MutableBlockPos();
          for (ChunkPos chunk : state.getRingPositionsFor(rings)) {
            structurePos.set(SectionPos.sectionToBlockCoord(chunk.x(), 8), 32, SectionPos.sectionToBlockCoord(chunk.z(), 8));
            double d = structurePos.distSqr(pos);
            if (closest == null || d < closestDist) {
              var found = (Pair<BlockPos, Holder<Structure>>) GENERATING_AT.invoke(null, entry.getValue(), reader, manager,
                  false, rings, chunk);
              if (found != null) {
                closest = found;
                closestDist = d;
              }
            }
          }
          if (closest != null && pos.distSqr(closest.getFirst()) < nearestDist) {
            nearestDist = pos.distSqr(closest.getFirst());
            nearest = closest;
          }
        } else if (entry.getKey() instanceof RandomSpreadStructurePlacement) {
          spread.add(entry);
        }
      }
      if (!spread.isEmpty()) {
        int originX = SectionPos.blockToSectionCoord(pos.getX());
        int originZ = SectionPos.blockToSectionCoord(pos.getZ());
        for (int radius = 0; radius <= RADIUS; radius++) {
          boolean foundSomething = false;
          for (var entry : spread) {
            var found = (Pair<BlockPos, Holder<Structure>>) SPIRAL.invoke(null, entry.getValue(), reader, manager, originX,
                originZ, radius, false, state.getLevelSeed(), entry.getKey());
            if (found != null) {
              foundSomething = true;
              double d = pos.distSqr(found.getFirst());
              if (d < nearestDist) {
                nearestDist = d;
                nearest = found;
              }
            }
          }
          if (foundSomething) return nearest;
        }
      }
      return nearest;
    }
  }

  static void cases(Path out) throws Exception {
    var registries = StructureOracle.serverRegistries();
    var factory = ChunkOracle.factory();
    var structures = registries.lookupOrThrow(Registries.STRUCTURE);
    var targets = new ArrayList<String>();
    structures.listElementIds().map(k -> k.identifier().toString()).sorted().forEach(targets::add);
    structures.listTagIds().map(t -> "#" + t.location()).sorted().forEach(targets::add);
    var gen = new Random(53053L);
    long[] seeds = {20261020L, -8172645723L, gen.nextLong()};
    var rows = new JsonArray();
    int found = 0;
    for (long seed : seeds) {
      var level = Level.create(StructureOracle.World.create(seed, "minecraft:overworld", registries, factory));
      var positions = List.of(new BlockPos(0, 64, 0),
          new BlockPos(gen.nextInt(60001) - 30000, gen.nextInt(200) - 32, gen.nextInt(60001) - 30000),
          new BlockPos(gen.nextInt(2_000_001) - 1_000_000, 70, gen.nextInt(2_000_001) - 1_000_000));
      for (var pos : positions) {
        for (var target : targets) {
          HolderSet<Structure> wanted = target.startsWith("#")
              ? structures.getOrThrow(net.minecraft.tags.TagKey.create(Registries.STRUCTURE,
                  net.minecraft.resources.Identifier.parse(target.substring(1))))
              : HolderSet.direct(structures.getOrThrow(net.minecraft.resources.ResourceKey.create(Registries.STRUCTURE,
                  net.minecraft.resources.Identifier.parse(target))));
          var result = level.locate(wanted, pos);
          var row = new JsonObject();
          row.addProperty("seed", Long.toString(seed));
          row.add("pos", StructureOracle.intArray(new int[] {pos.getX(), pos.getY(), pos.getZ()}));
          row.addProperty("target", target);
          if (result == null) {
            row.add("found", JsonNull.INSTANCE);
          } else {
            found++;
            var hit = new JsonArray();
            hit.add(result.getFirst().getX());
            hit.add(result.getFirst().getY());
            hit.add(result.getFirst().getZ());
            hit.add(result.getSecond().unwrapKey().orElseThrow().identifier().toString());
            row.add("found", hit);
          }
          rows.add(row);
        }
      }
    }
    Files.writeString(out, new Gson().toJson(rows));
    System.out.println("PASS: vanilla located " + found + " of " + rows.size() + " structure targets");
  }
}
