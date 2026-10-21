import com.google.gson.*;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.core.SectionPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.biome.BiomeManager;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Mirror;
import net.minecraft.world.level.block.Rotation;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.structure.BoundingBox;
import net.minecraft.world.level.levelgen.structure.pools.JigsawPlacement;
import net.minecraft.world.level.levelgen.structure.pools.alias.PoolAliasLookup;
import net.minecraft.world.level.levelgen.structure.templatesystem.BlockRotProcessor;
import net.minecraft.world.level.levelgen.structure.templatesystem.LiquidSettings;
import net.minecraft.world.level.levelgen.structure.templatesystem.StructurePlaceSettings;
import net.minecraft.world.level.levelgen.Aquifer;

/**
 * `/place` (VMC-053): what vanilla's `PlaceCommand` placements change, for seeded randoms.
 *
 * `cases OUT.json`: overworld terrain of seed 20261020 (`DecorationOracle.Terrain`), and per case a
 * square of chunks, a position and a level random seed (`RandomSource.create(seed)`); the
 * placement runs as `PlaceCommand` runs it (configured feature `place`, template `placeInWorld`
 * with its settings, structure `generate` with every biome valid then `placeInChunk` per chunk of
 * its box, jigsaw `addPieces` then each piece's `place` with an infinite box) through a
 * world-generation region that writes every chunk it holds, as the level would. Recorded: whether
 * it placed, and every block that changed (`x y z state-id`). A live level also updates the
 * neighbours' shapes, which ValiMC's command writes do not (as `/setblock` and `/fill`).
 */
public class PlaceOracle {
  record Case(String kind, List<String> names, int depth, float integrity, boolean strict, BlockPos pos, long seed,
      int x0, int z0, int size) {}

  /** A region writing every chunk it holds (`/place` writes the level). */
  static class PlaceRegion extends DecorationOracle.Region {
    PlaceRegion(Map<ChunkPos, ProtoChunk> chunks, ChunkPos center, long seed, RandomState state,
        net.minecraft.world.level.biome.BiomeSource biomeSource, net.minecraft.core.HolderGetter.Provider lookup) {
      super(chunks, center, seed, state, biomeSource, lookup);
    }

    // Template mobs are finalized at a difficulty; ValiMC leaves them out, and blocks do not depend on it.
    @Override public net.minecraft.world.DifficultyInstance getCurrentDifficultyAt(BlockPos pos) {
      return new net.minecraft.world.DifficultyInstance(net.minecraft.world.Difficulty.NORMAL, 0L, 0L, 0f);
    }

    // The level: every chunk it holds is loaded.
    @Override public net.minecraft.world.level.chunk.ChunkAccess getChunk(int x, int z,
        net.minecraft.world.level.chunk.status.ChunkStatus status, boolean loadOrGenerate) {
      return chunk(x, z);
    }

    @Override public boolean ensureCanWrite(BlockPos pos) {
      return chunks.containsKey(new ChunkPos(SectionPos.blockToSectionCoord(pos.getX()), SectionPos.blockToSectionCoord(pos.getZ())));
    }
  }

  public static void main(String[] args) throws Exception {
    var factory = ChunkOracle.factory();
    DecorationOracle.selectDimension("overworld");
    SupportOracle.bindFluidTags();
    var registries = StructureOracle.serverRegistries();
    DecorationOracle.REGISTRIES = registries;
    var noises = registries.lookupOrThrow(Registries.NOISE);
    var biomeLookup = registries.lookupOrThrow(Registries.BIOME);
    var holder = registries.lookupOrThrow(Registries.NOISE_SETTINGS).getOrThrow(NoiseGeneratorSettings.OVERWORLD);
    var settings = holder.value();
    DecorationOracle.SEA_LEVEL = settings.seaLevel();
    Method doFill = NoiseBasedChunkGenerator.class.getDeclaredMethod("doFill", NoiseChunk.class, ChunkAccess.class);
    doFill.setAccessible(true);
    Method buildSurface = NoiseBasedChunkGenerator.class.getDeclaredMethod("buildSurface", ChunkAccess.class, NoiseChunk.class,
        RandomState.class, BiomeManager.class, Set.class, net.minecraft.world.level.levelgen.material.rule.MaterialRule.class);
    buildSurface.setAccessible(true);
    Method generateCarvers = NoiseBasedChunkGenerator.class.getDeclaredMethod("generateCarvers", ChunkAccess.class, Blender.class,
        NoiseChunk.class, RandomState.class, BiomeManager.class, net.minecraft.server.level.WorldGenRegion.class,
        net.minecraft.world.level.levelgen.material.rule.MaterialRule.class);
    generateCarvers.setAccessible(true);
    Method createFluidPicker = NoiseBasedChunkGenerator.class.getDeclaredMethod("createFluidPicker", NoiseGeneratorSettings.class);
    createFluidPicker.setAccessible(true);
    var picker = (Aquifer.FluidPicker) createFluidPicker.invoke(null, settings);
    var heights = LevelHeightAccessor.create(DecorationOracle.MIN_Y, DecorationOracle.HEIGHT);
    long seed = 20261020L;
    var state = RandomState.create(noises, seed, settings);
    var biomeSource = DecorationOracle.biomeSource(biomeLookup);
    var generator = new NoiseBasedChunkGenerator(biomeSource, holder);
    var terrain = new DecorationOracle.Terrain(factory, seed, state, settings, picker, generator, heights, biomeLookup, doFill,
        buildSurface, generateCarvers);
    var templates = DecorationOracle.Region.templateServer().getStructureTemplateManager();

    var cases = new ArrayList<Case>();
    // Positions on the surface of chunk (cx, cz)'s centre, found from the terrain.
    int[][] spots = {{0, 0}, {5, -3}, {-7, 4}, {12, 9}, {-20, -15}};
    long next = 1;
    for (int[] spot : spots) {
      var chunks = terrain.area(new ChunkPos(spot[0], spot[1]), 0);
      var chunk = chunks.values().iterator().next();
      int bx = spot[0] * 16 + 8, bz = spot[1] * 16 + 8;
      int y = chunk.getHeight(Heightmap.Types.WORLD_SURFACE_WG, bx & 15, bz & 15) + 1;
      var pos = new BlockPos(bx, y, bz);
      for (String feature : List.of("minecraft:oak", "minecraft:fancy_oak", "minecraft:birch", "minecraft:flower_default",
          "minecraft:grass", "minecraft:spruce", "minecraft:desert_well", "minecraft:pile_pumpkin", "minecraft:fallen_oak_tree")) {
        cases.add(new Case("feature", List.of(feature), 0, 1f, false, pos, next++, spot[0] - 2, spot[1] - 2, 5));
      }
      cases.add(new Case("feature", List.of("minecraft:ore_iron"), 0, 1f, false, pos.below(30), next++, spot[0] - 2, spot[1] - 2, 5));
      cases.add(new Case("feature", List.of("minecraft:monster_room"), 0, 1f, false, pos.below(25), next++, spot[0] - 2, spot[1] - 2, 5));
      cases.add(new Case("template", List.of("minecraft:igloo/top", "none", "none"), 0, 1f, false, pos, next++, spot[0] - 1,
          spot[1] - 1, 3));
      cases.add(new Case("template", List.of("minecraft:shipwreck/rightsideup_full", "clockwise_90", "left_right"), 0, 1f, false,
          pos, next++, spot[0] - 2, spot[1] - 2, 5));
      cases.add(new Case("template", List.of("minecraft:village/plains/houses/plains_small_house_1", "180", "front_back"), 0, 0.6f,
          false, pos, 42, spot[0] - 2, spot[1] - 2, 5));
      cases.add(new Case("template", List.of("minecraft:ruined_portal/portal_3", "counterclockwise_90", "none"), 0, 1f, true, pos,
          next++, spot[0] - 2, spot[1] - 2, 5));
      for (String structure : List.of("minecraft:igloo", "minecraft:desert_pyramid", "minecraft:jungle_pyramid",
          "minecraft:shipwreck", "minecraft:pillager_outpost",
          "minecraft:village_plains")) {
        cases.add(new Case("structure", List.of(structure), 0, 1f, false, pos, next++, spot[0] - 7, spot[1] - 7, 15));
      }
      cases.add(new Case("jigsaw", List.of("minecraft:village/plains/town_centers", "minecraft:bottom"), 2, 1f, false, pos, next++,
          spot[0] - 7, spot[1] - 7, 15));
      cases.add(new Case("jigsaw", List.of("minecraft:pillager_outpost/base_plates", "minecraft:entrance"), 1, 1f, false, pos,
          next++, spot[0] - 7, spot[1] - 7, 15));
    }

    var out = new JsonArray();
    int placed = 0, failed = 0;
    for (var c : cases) {
      var area = new LinkedHashMap<ChunkPos, ProtoChunk>();
      var positions = new ArrayList<ChunkPos>();
      for (int dz = 0; dz < c.size(); dz++) {
        for (int dx = 0; dx < c.size(); dx++) positions.add(new ChunkPos(c.x0() + dx, c.z0() + dz));
      }
      area.putAll(terrain.build(positions));
      var before = new HashMap<ChunkPos, int[]>();
      for (var e : area.entrySet()) before.put(e.getKey(), states(e.getValue()));
      var center = new ChunkPos(c.x0() + c.size() / 2, c.z0() + c.size() / 2);
      var region = new PlaceRegion(area, center, seed, state, biomeSource, registries);
      region.registries = registries;
      region.generator = generator;
      var random = RandomSource.create(c.seed());
      boolean ok;
      try {
        ok = place(c, region, generator, state, registries, templates, random, seed, biomeSource);
      } catch (RuntimeException e) {
        throw new IllegalStateException(c + ": " + e, e);
      }
      var row = new JsonObject();
      row.addProperty("kind", c.kind());
      var names = new JsonArray();
      c.names().forEach(names::add);
      row.add("names", names);
      row.addProperty("depth", c.depth());
      row.addProperty("integrity", c.integrity());
      row.addProperty("strict", c.strict());
      row.add("pos", StructureOracle.intArray(new int[] {c.pos().getX(), c.pos().getY(), c.pos().getZ()}));
      row.addProperty("seed", Long.toString(c.seed()));
      row.add("area", StructureOracle.intArray(new int[] {c.x0(), c.z0(), c.size()}));
      row.addProperty("placed", ok);
      var changed = new JsonArray();
      if (ok) {
        placed++;
        for (var e : area.entrySet()) {
          int[] old = before.get(e.getKey());
          int[] now = states(e.getValue());
          for (int i = 0; i < now.length; i++) {
            if (old[i] != now[i]) {
              int column = i / DecorationOracle.HEIGHT;
              int bx = e.getKey().getMinBlockX() + (column & 15);
              int bz = e.getKey().getMinBlockZ() + (column >> 4);
              int by = DecorationOracle.MIN_Y + i % DecorationOracle.HEIGHT;
              changed.add(bx + " " + by + " " + bz + " " + now[i]);
            }
          }
        }
      } else {
        failed++;
      }
      row.add("changed", changed);
      out.add(row);
    }
    Files.writeString(Path.of(args[1]), new Gson().toJson(out));
    System.out.println("PASS: vanilla placed " + placed + " of " + cases.size() + " /place cases (" + failed + " placed nothing)");
  }

  /** A chunk's states, Y fastest from the bottom, then X, then Z. */
  static int[] states(ProtoChunk chunk) {
    int h = DecorationOracle.HEIGHT;
    var out = new int[256 * h];
    var pos = new BlockPos.MutableBlockPos();
    for (int z = 0; z < 16; z++) {
      for (int x = 0; x < 16; x++) {
        for (int y = 0; y < h; y++) {
          pos.set(chunk.getPos().getMinBlockX() + x, DecorationOracle.MIN_Y + y, chunk.getPos().getMinBlockZ() + z);
          out[(x + z * 16) * h + y] = Block.getId(chunk.getBlockState(pos));
        }
      }
    }
    return out;
  }

  static boolean place(Case c, PlaceRegion level, NoiseBasedChunkGenerator generator, RandomState state,
      net.minecraft.core.RegistryAccess registries,
      net.minecraft.world.level.levelgen.structure.templatesystem.StructureTemplateManager templates, RandomSource random,
      long seed, net.minecraft.world.level.biome.BiomeSource biomeSource) {
    var pos = c.pos();
    switch (c.kind()) {
      case "feature" -> {
        var feature = registries.lookupOrThrow(Registries.FEATURE)
            .getOrThrow(ResourceKey.create(Registries.FEATURE, Identifier.parse(c.names().get(0))));
        return feature.value().place(level, generator, random, pos);
      }
      case "template" -> {
        var template = templates.get(Identifier.parse(c.names().get(0))).orElseThrow();
        var settings = new StructurePlaceSettings().setMirror(mirror(c.names().get(2))).setRotation(rotation(c.names().get(1)))
            .setKnownShape(c.strict());
        if (c.integrity() < 1.0F) {
          settings.clearProcessors().addProcessor(new BlockRotProcessor(c.integrity())).setRandom(RandomSource.create(c.seed()));
        }
        return template.placeInWorld(level, pos, pos, settings, random, 2 | (c.strict() ? 816 : 0));
      }
      case "structure" -> {
        var holder = registries.lookupOrThrow(Registries.STRUCTURE)
            .getOrThrow(ResourceKey.create(Registries.STRUCTURE, Identifier.parse(c.names().get(0))));
        var start = holder.value().generate(holder, net.minecraft.world.level.Level.OVERWORLD, registries, generator,
            biomeSource, state.createClimateSampler(net.minecraft.world.level.levelgen.densityfunction.SamplerContext.EMPTY_UNCACHED),
            state, templates, seed, ChunkPos.containing(pos), 0, level, b -> true);
        if (!start.isValid()) return false;
        var box = start.getBoundingBox();
        var min = new ChunkPos(SectionPos.blockToSectionCoord(box.minX()), SectionPos.blockToSectionCoord(box.minZ()));
        var max = new ChunkPos(SectionPos.blockToSectionCoord(box.maxX()), SectionPos.blockToSectionCoord(box.maxZ()));
        var manager = new net.minecraft.world.level.StructureManager(level, new WorldOptions(seed, true, false), null);
        ChunkPos.rangeClosed(min, max).forEach(ch -> start.placeInChunk(level, manager, generator, random,
            new BoundingBox(ch.getMinBlockX(), level.getMinY(), ch.getMinBlockZ(), ch.getMaxBlockX(), level.getMaxY() + 1,
                ch.getMaxBlockZ()), ch));
        return true;
      }
      case "jigsaw" -> {
        var pool = registries.lookupOrThrow(Registries.TEMPLATE_POOL)
            .getOrThrow(ResourceKey.create(Registries.TEMPLATE_POOL, Identifier.parse(c.names().get(0))));
        var context = new net.minecraft.world.level.levelgen.structure.Structure.GenerationContext(registries, generator,
            biomeSource, state.createClimateSampler(net.minecraft.world.level.levelgen.densityfunction.SamplerContext.EMPTY_UNCACHED), state,
            templates, seed, ChunkPos.containing(pos), level, b -> true);
        var stub = JigsawPlacement.addPieces(context, pool, Optional.of(Identifier.parse(c.names().get(1))), c.depth(), pos, false,
            Optional.empty(), new net.minecraft.world.level.levelgen.structure.structures.JigsawStructure.MaxDistance(128),
            PoolAliasLookup.EMPTY, net.minecraft.world.level.levelgen.structure.structures.JigsawStructure.DEFAULT_DIMENSION_PADDING,
            net.minecraft.world.level.levelgen.structure.structures.JigsawStructure.DEFAULT_LIQUID_SETTINGS);
        if (stub.isEmpty()) return false;
        var manager = new net.minecraft.world.level.StructureManager(level, new WorldOptions(seed, true, false), null);
        for (var piece : stub.get().getPiecesBuilder().build().pieces()) {
          if (piece instanceof net.minecraft.world.level.levelgen.structure.PoolElementStructurePiece poolPiece) {
            poolPiece.place(level, manager, generator, random, BoundingBox.infinite(), pos, false);
          }
        }
        return true;
      }
      default -> throw new IllegalArgumentException(c.kind());
    }
  }

  static Rotation rotation(String name) {
    return switch (name) {
      case "clockwise_90" -> Rotation.CLOCKWISE_90;
      case "180" -> Rotation.CLOCKWISE_180;
      case "counterclockwise_90" -> Rotation.COUNTERCLOCKWISE_90;
      default -> Rotation.NONE;
    };
  }

  static Mirror mirror(String name) {
    return switch (name) {
      case "left_right" -> Mirror.LEFT_RIGHT;
      case "front_back" -> Mirror.FRONT_BACK;
      default -> Mirror.NONE;
    };
  }
}
