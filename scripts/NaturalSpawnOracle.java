import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.particles.ParticleOptions;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.tags.BlockTags;
import net.minecraft.util.RandomSource;
import net.minecraft.util.random.Weighted;
import net.minecraft.util.valueproviders.ConstantInt;
import net.minecraft.util.valueproviders.IntProvider;
import net.minecraft.util.valueproviders.UniformInt;
import net.minecraft.world.Difficulty;
import net.minecraft.world.DifficultyInstance;
import net.minecraft.world.attribute.EnvironmentAttributeSystem;
import net.minecraft.world.attribute.EnvironmentAttributes;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.fish.AbstractSchoolingFish;
import net.minecraft.world.entity.animal.fish.TropicalFish;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.level.*;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.biome.MobSpawnSettings;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.InfestedBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.LevelChunk;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.levelgen.LegacyRandomSource;
import net.minecraft.world.level.levelgen.WorldgenRandom;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.levelgen.structure.StructureStart;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.pathfinder.NodeEvaluator;
import net.minecraft.world.level.pathfinder.PathComputationType;
import net.minecraft.world.level.storage.LevelData;
import net.minecraft.world.phys.*;

/**
 * Vanilla's natural spawner (VMC-042a).
 *
 * `facts OUT`: what the spawner reads beyond the block and entity facts, as
 * one table: every biome's natural spawns (each spawner's type, weight and
 * count provider) with its spawn costs and its creature spawn probability at
 * generation, each dimension's monster light test, block light limit, ambient
 * light and its timeline tracks of the sky light level and the surface slime
 * chance, each spawning type's spawn box, the blocks it is immune to and its
 * pack limits (`getMaxSpawnClusterSize`, a school's size), whether it is a
 * `PathfinderMob` (its walk target decides `checkSpawnRules`) and breathes
 * under water (`canBreatheUnderwater`), and per block
 * state one byte of `isValidSpawn` (what kinds of type it admits) and one
 * word of the spawn rules' block tests (tags and blocks, `isPathfindable`,
 * `isBurningBlock`, light dampening).
 *
 * `fixtures OUT`: `NaturalSpawner.spawnForChunk` with vanilla's own spawn
 * state (charges, counts) over scenes of a probe level (blocks in boxes, a
 * light rule, players, one biome), `spawnMobsForChunkGeneration` with the
 * decoration-seeded random, `Mob.checkDespawn` at distances, and the sky
 * darkening from the day timeline and the weather. The level random of a
 * scene is seeded; `finalizeSpawn` draws from a random of its own (vanilla
 * shares the level's), so the spawner's draws compare alone. Scenes may hold
 * structure starts (VMC-042b), each referenced by the chunks its box reaches,
 * for the structures' spawn overrides.
 *
 * The fixtures also tick spawner blocks (VMC-042b, `BaseSpawner.serverTick`) in dungeon,
 * fortress, mineshaft and stronghold scenes.
 */
public class NaturalSpawnOracle {
  static sun.misc.Unsafe unsafe;
  static final Gson JSON = new Gson();
  static RegistryAccess registries;

  static void setFinal(Class<?> c, String n, Object o, Object v) throws Exception {
    var f = c.getDeclaredField(n); unsafe.putObject(o, unsafe.objectFieldOffset(f), v);
  }
  static Field field(Class<?> c, String n) throws Exception { var f = c.getDeclaredField(n); f.setAccessible(true); return f; }
  static String id(EntityType<?> t) { return BuiltInRegistries.ENTITY_TYPE.getKey(t).toString(); }

  // ---------------------------------------------------------------- facts

  static JsonArray count(IntProvider p) {
    var a = new JsonArray();
    if (p instanceof ConstantInt c) { a.add("constant"); a.add(c.value()); a.add(c.value()); }
    else if (p instanceof UniformInt u) { a.add("uniform"); a.add(u.minInclusive()); a.add(u.maxInclusive()); }
    else throw new IllegalStateException("count provider " + p);
    return a;
  }

  static JsonArray spawners(net.minecraft.util.random.WeightedList<MobSpawnSettings.SpawnerData> list) {
    var out = new JsonArray();
    for (Weighted<MobSpawnSettings.SpawnerData> w : list.unwrap()) {
      var a = new JsonArray(); a.add(id(w.value().type())); a.add(w.weight());
      for (var e : count(w.value().count())) a.add(e);
      out.add(a);
    }
    return out;
  }

  static JsonObject settings(MobSpawnSettings s) {
    var spawns = new JsonObject();
    for (var c : MobCategory.values())
      if (s.definedCategories().contains(c)) spawns.add(c.getSerializedName(), spawners(s.getMobsInCategory(c)));
    var costs = new JsonObject();
    new TreeMap<String, MobSpawnSettings.MobSpawnCost>(
        s.allSpawnCosts().entrySet().stream().collect(java.util.stream.Collectors.toMap(e -> id(e.getKey()), Map.Entry::getValue)))
      .forEach((k, v) -> { var a = new JsonArray(); a.add(v.energyBudget()); a.add(v.charge()); costs.add(k, a); });
    var out = new JsonObject(); out.add("spawns", spawns); out.add("costs", costs);
    return out;
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  static JsonObject track(Object attributeTrack) throws Exception {
    var t = (net.minecraft.world.timeline.AttributeTrack) attributeTrack;
    var k = t.argumentTrack();
    var frames = new JsonArray();
    for (Object o : k.keyframes()) {
      var f = (net.minecraft.util.Keyframe) o; var a = new JsonArray(); a.add(f.ticks());
      a.add(((Number) f.value()).doubleValue()); frames.add(a);
    }
    var out = new JsonObject();
    out.add("ease", net.minecraft.util.EasingType.CODEC.encodeStart(com.mojang.serialization.JsonOps.INSTANCE, k.easingType()).getOrThrow());
    out.add("keyframes", frames);
    return out;
  }

  static Probe factsLevel() throws Exception { return probe(new Scene("facts", "minecraft:overworld", "minecraft:plains")); }

  static void facts(Path out) throws Exception {
    var biomes = new TreeMap<String, JsonElement>();
    var biomeRegistry = registries.lookupOrThrow(Registries.BIOME);
    biomeRegistry.listElements().forEach(h -> {
      var b = h.value();
      var s = b.getAttributes().applyModifier(EnvironmentAttributes.NATURAL_MOB_SPAWNS, MobSpawnSettings.EMPTY);
      var o = settings(s);
      o.addProperty("creature_probability",
          (double) b.getAttributes().applyModifier(EnvironmentAttributes.CREATURE_WORLD_GEN_SPAWN_PROBABILITY,
              EnvironmentAttributes.CREATURE_WORLD_GEN_SPAWN_PROBABILITY.defaultValue()));
      biomes.put(h.key().identifier().toString(), o);
    });

    var dimensions = new TreeMap<String, JsonElement>();
    for (var h : registries.lookupOrThrow(Registries.DIMENSION_TYPE).listElements().toList()) {
      DimensionType d = h.value();
      var o = new JsonObject();
      o.add("monster_light", count(d.monsterSpawnLightTest()));
      o.addProperty("block_light_limit", d.monsterSpawnBlockLightLimit());
      o.addProperty("ambient_light", (double) d.ambientLight());
      o.addProperty("ceiling", d.hasCeiling());
      o.addProperty("sky_light_level", (double) d.attributes().applyModifier(EnvironmentAttributes.SKY_LIGHT_LEVEL,
          EnvironmentAttributes.SKY_LIGHT_LEVEL.defaultValue()));
      var tracks = new JsonObject();
      for (var timeline : d.timelines()) {
        Map<?, ?> map = (Map<?, ?>) field(net.minecraft.world.timeline.Timeline.class, "tracks").get(timeline.value());
        var period = timeline.value().periodTicks().orElse(0);
        for (var e : map.entrySet()) {
          var name = BuiltInRegistries.ENVIRONMENT_ATTRIBUTE.getKey((net.minecraft.world.attribute.EnvironmentAttribute<?>) e.getKey()).toString();
          if (!name.equals("minecraft:gameplay/sky_light_level") && !name.equals("minecraft:gameplay/surface_slime_spawn_chance")) continue;
          var t = track(e.getValue()); t.addProperty("period", period);
          tracks.add(name.substring("minecraft:gameplay/".length()), t);
        }
      }
      o.add("tracks", tracks);
      dimensions.put(h.key().identifier().toString(), o);
    }

    var level = factsLevel();
    var types = new TreeMap<String, JsonElement>();
    var immuneTags = new ArrayList<net.minecraft.tags.TagKey<Block>>();
    for (EntityType<?> type : BuiltInRegistries.ENTITY_TYPE) {
      if (type.getCategory() == MobCategory.MISC) continue;
      var o = new JsonObject();
      var box = type.getSpawnAABB(0, 0, 0);
      var b = new JsonArray(); b.add(box.maxX); b.add(box.maxY); o.add("box", b);
      @SuppressWarnings("unchecked")
      var immune = (net.minecraft.tags.TagKey<Block>) field(EntityType.class, "immuneTo").get(type);
      if (!immuneTags.contains(immune)) immuneTags.add(immune);
      o.addProperty("immune", immune.location().getPath());
      // Bosses need a server; they spawn by no natural spawner.
      Entity e = null;
      try { e = type.create(level, EntitySpawnReason.NATURAL); } catch (RuntimeException ignored) {}
      if (e instanceof Mob mob) {
        o.addProperty("cluster", mob.getMaxSpawnClusterSize());
        if (mob instanceof AbstractSchoolingFish fish) o.addProperty("school", fish.getMaxSchoolSize());
        o.addProperty("pathfinder", mob instanceof PathfinderMob);
        o.addProperty("water_breather", mob.canBreatheUnderwater());
      }
      types.put(id(type), o);
    }

    // Per state: isValidSpawn by the type kinds its predicates tell apart.
    var probes = List.of(EntityTypes.ZOMBIE, EntityTypes.OCELOT, EntityTypes.PARROT, EntityTypes.POLAR_BEAR, EntityTypes.BLAZE);
    int n = Block.BLOCK_STATE_REGISTRY.size();
    var valid = new byte[n]; var bits = new long[n];
    var tags = new ArrayList<>(List.of(BlockTags.PREVENT_MOB_SPAWNING_INSIDE, BlockTags.ANIMALS_SPAWNABLE_ON, BlockTags.MOOSHROOMS_SPAWNABLE_ON,
        BlockTags.PARROTS_SPAWNABLE_ON, BlockTags.FOXES_SPAWNABLE_ON, BlockTags.WOLVES_SPAWNABLE_ON, BlockTags.GOATS_SPAWNABLE_ON,
        BlockTags.RABBITS_SPAWNABLE_ON, BlockTags.FROGS_SPAWNABLE_ON, BlockTags.AXOLOTLS_SPAWNABLE_ON, BlockTags.ARMADILLO_SPAWNABLE_ON,
        BlockTags.CAMELS_SPAWNABLE_ON, BlockTags.POLAR_BEARS_SPAWNABLE_ON_ALTERNATE, BlockTags.BATS_SPAWNABLE_ON, BlockTags.LEAVES,
        BlockTags.SAND));
    for (var t : immuneTags) if (!tags.contains(t)) tags.add(t);
    var blocks = List.of(Blocks.GRASS_BLOCK, Blocks.MYCELIUM, Blocks.NETHER_WART_BLOCK, Blocks.NETHER_BRICKS, Blocks.WATER,
        Blocks.POWDER_SNOW, Blocks.CRIMSON_NYLIUM);
    var names = new JsonArray();
    for (var t : List.of("pathfindable_land", "burning", "dangerous", "light_blocks_sky")) names.add(t);
    for (var t : tags) names.add(t.location().getPath());
    for (var blk : blocks) names.add(BuiltInRegistries.BLOCK.getKey(blk).getPath());
    names.add("infested_host");
    for (int s = 0; s < n; s++) {
      BlockState state = Block.BLOCK_STATE_REGISTRY.byId(s);
      int kinds = 0;
      for (int i = 0; i < probes.size(); i++)
        if (state.isValidSpawn(EmptyBlockGetter.INSTANCE, BlockPos.ZERO, probes.get(i))) kinds |= 1 << i;
      valid[s] = switch (kinds) {
        case 0 -> 0; case 0b11111 -> 1; case 0b00110 -> 2; case 0b01000 -> 3; case 0b10000 -> 4;
        default -> throw new IllegalStateException("isValidSpawn kinds " + kinds + " of " + state);
      };
      long w = 0; int i = 0;
      if (state.isPathfindable(PathComputationType.LAND)) w |= 1L << i; i++;
      if (NodeEvaluator.isBurningBlock(state)) w |= 1L << i; i++;
      if (state.is(Blocks.WITHER_ROSE) || state.is(Blocks.SWEET_BERRY_BUSH) || state.is(Blocks.CACTUS) || state.is(Blocks.POWDER_SNOW)) w |= 1L << i; i++;
      if (state.getLightDampening() > 0 && !state.liquid()) w |= 1L << i; i++;
      for (var t : tags) { if (state.is(t)) w |= 1L << i; i++; }
      for (var blk : blocks) { if (state.is(blk)) w |= 1L << i; i++; }
      if (InfestedBlock.isCompatibleHostBlock(state)) w |= 1L << i; i++;
      bits[s] = w;
    }
    var hexValid = new StringBuilder(); for (byte v : valid) hexValid.append(String.format("%02x", v));
    // The words as a palette and one index byte per state.
    var palette = new ArrayList<Long>(); var hexBits = new StringBuilder();
    for (long v : bits) {
      int at = palette.indexOf(v);
      if (at < 0) { at = palette.size(); palette.add(v); }
      if (at > 255) throw new IllegalStateException("more than 256 spawn words");
      hexBits.append(String.format("%02x", at));
    }
    var states = new JsonObject();
    states.addProperty("valid_spawn", hexValid.toString());
    states.add("bit_names", names);
    states.add("palette", JSON.toJsonTree(palette));
    states.addProperty("bits", hexBits.toString());

    var root = new JsonObject();
    root.addProperty("version", "26.3");
    root.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    root.addProperty("state_count", n);
    root.add("biomes", JSON.toJsonTree(biomes));
    root.add("dimensions", JSON.toJsonTree(dimensions));
    root.add("types", JSON.toJsonTree(types));
    root.add("states", states);
    Files.writeString(out, new GsonBuilder().setPrettyPrinting().create().toJson(root) + "\n");
    System.out.println("PASS: spawn facts for " + biomes.size() + " biomes, " + dimensions.size() + " dimensions, "
        + types.size() + " spawning types, " + n + " states.");
  }

  // ---------------------------------------------------------------- scenes

  /** A box of one state. */
  record Fill(int x1, int y1, int z1, int x2, int y2, int z2, BlockState state) {}

  static class Scene {
    final String name, dimension, biome;
    final List<Fill> fills = new ArrayList<>();
    final List<int[]> lights = new ArrayList<>();
    final List<double[]> players = new ArrayList<>();
    final List<Object[]> entities = new ArrayList<>();
    int sky = 15, darken = 0, difficulty = 2, seaLevel = 63;
    float slimeChance = 0;
    boolean thundering = false;
    long seed = 1234567L;
    int[] spawn = {0, -200, 0};
    /** Structure starts (VMC-042b): the structure and its pieces' boxes, the start in the chunk of its first piece. */
    final List<Object[]> starts = new ArrayList<>();
    List<StructureStart> built;
    Scene start(String structure, int[]... pieces) { starts.add(new Object[]{structure, pieces}); built = null; return this; }
    /** The scene's starts, each referenced by every chunk its box reaches. */
    List<StructureStart> structureStarts() {
      if (built != null) return built;
      built = new ArrayList<>();
      for (var s : starts) {
        var structure = registries.lookupOrThrow(Registries.STRUCTURE).getValue(Identifier.parse((String) s[0]));
        var pieces = new ArrayList<net.minecraft.world.level.levelgen.structure.StructurePiece>();
        for (int[] b : (int[][]) s[1]) {
          var box = new net.minecraft.world.level.levelgen.structure.BoundingBox(b[0], b[1], b[2], b[3], b[4], b[5]);
          pieces.add(new net.minecraft.world.level.levelgen.structure.StructurePiece(
              net.minecraft.world.level.levelgen.structure.pieces.StructurePieceType.SWAMPLAND_HUT, 0, box) {
            protected void addAdditionalSaveData(net.minecraft.world.level.levelgen.structure.pieces.StructurePieceSerializationContext c,
                net.minecraft.nbt.CompoundTag t) {}
            public void postProcess(WorldGenLevel l, StructureManager m, net.minecraft.world.level.chunk.ChunkGenerator g, RandomSource r,
                net.minecraft.world.level.levelgen.structure.BoundingBox b, ChunkPos c, BlockPos p) {}
          });
        }
        var first = pieces.get(0).getBoundingBox();
        built.add(new StructureStart(structure, new ChunkPos(first.minX() >> 4, first.minZ() >> 4), 0,
            new net.minecraft.world.level.levelgen.structure.pieces.PiecesContainer(pieces)));
      }
      return built;
    }
    static boolean reaches(StructureStart start, int cx, int cz) {
      return start.getBoundingBox().intersects(cx * 16, cz * 16, cx * 16 + 15, cz * 16 + 15);
    }
    Scene(String name, String dimension, String biome) {
      this.name = name; this.dimension = dimension; this.biome = biome;
      if (dimension.equals("minecraft:the_nether")) { seaLevel = 32; sky = 0; }
      if (dimension.equals("minecraft:the_end")) { seaLevel = 0; sky = 0; }
    }
    Scene fill(int x1, int y1, int z1, int x2, int y2, int z2, Block b) { return fill(x1, y1, z1, x2, y2, z2, b.defaultBlockState()); }
    Scene fill(int x1, int y1, int z1, int x2, int y2, int z2, BlockState s) {
      fills.add(new Fill(Math.min(x1, x2), Math.min(y1, y2), Math.min(z1, z2), Math.max(x1, x2), Math.max(y1, y2), Math.max(z1, z2), s));
      cache.clear(); sections.clear(); return this;
    }
    /** A floor over the scene: `top` of `surface` over `depth` of `under`. */
    Scene ground(int top, Block surface, Block under) {
      fill(-64, top - 8, -64, 79, top - 1, 79, under);
      return fill(-64, top, -64, 79, top, 79, surface);
    }
    Scene light(int x, int y, int z, int level) { lights.add(new int[]{x, y, z, level}); return this; }
    Scene player(double x, double y, double z) { players.add(new double[]{x, y, z, 0}); return this; }
    Scene spectator(double x, double y, double z) { players.add(new double[]{x, y, z, 1}); return this; }
    Scene entity(EntityType<?> t, double x, double y, double z) { entities.add(new Object[]{t, x, y, z}); return this; }

    final Map<Long, BlockState> cache = new HashMap<>();
    final Map<Long, net.minecraft.world.level.chunk.LevelChunkSection> sections = new HashMap<>();
    /** The scene's blocks in a section, for vanilla's section scans. */
    net.minecraft.world.level.chunk.LevelChunkSection section(int sx, int sy, int sz) {
      return sections.computeIfAbsent(SectionPos.asLong(sx, sy, sz), k -> {
        var section = new net.minecraft.world.level.chunk.LevelChunkSection(net.minecraft.world.level.chunk.PalettedContainerFactory.create(registries));
        for (int x = 0; x < 16; x++) for (int y = 0; y < 16; y++) for (int z = 0; z < 16; z++)
          section.setBlockState(x, y, z, state(sx * 16 + x, sy * 16 + y, sz * 16 + z), false);
        section.recalcBlockCounts();
        return section;
      });
    }
    BlockState state(int x, int y, int z) {
      long key = BlockPos.asLong(x, y, z);
      var hit = cache.get(key);
      if (hit != null) return hit;
      BlockState s = Blocks.AIR.defaultBlockState();
      for (int i = fills.size() - 1; i >= 0; i--) {
        var f = fills.get(i);
        if (x >= f.x1 && x <= f.x2 && y >= f.y1 && y <= f.y2 && z >= f.z1 && z <= f.z2) { s = f.state; break; }
      }
      cache.put(key, s);
      return s;
    }
    int height(Heightmap.Types type, int x, int z) {
      int top = Integer.MIN_VALUE;
      for (var f : fills) if (x >= f.x1 && x <= f.x2 && z >= f.z1 && z <= f.z2) top = Math.max(top, f.y2);
      for (int y = Math.min(top, 319); y >= -64; y--) if (type.isOpaque().test(state(x, y, z))) return y + 1;
      return -64;
    }
    /** Sky light at and above the motion-blocking surface, none below; block light falls off by distance. */
    int skyLight(int x, int y, int z) { return y >= height(Heightmap.Types.MOTION_BLOCKING, x, z) ? sky : 0; }
    int blockLight(int x, int y, int z) {
      int best = 0;
      for (var l : lights) best = Math.max(best, l[3] - Math.abs(x - l[0]) - Math.abs(y - l[1]) - Math.abs(z - l[2]));
      return best;
    }

    JsonObject json() {
      var o = new JsonObject();
      o.addProperty("name", name); o.addProperty("dimension", dimension); o.addProperty("biome", biome);
      var fs = new JsonArray();
      for (var f : fills) { var a = new JsonArray(); for (int v : new int[]{f.x1, f.y1, f.z1, f.x2, f.y2, f.z2}) a.add(v); a.add(Block.getId(f.state)); fs.add(a); }
      o.add("fills", fs);
      o.add("lights", JSON.toJsonTree(lights));
      o.add("players", JSON.toJsonTree(players));
      var es = new JsonArray();
      for (var e : entities) { var a = new JsonArray(); a.add(id((EntityType<?>) e[0])); a.add((double) e[1]); a.add((double) e[2]); a.add((double) e[3]); es.add(a); }
      o.add("entities", es);
      o.addProperty("sky", sky); o.addProperty("darken", darken); o.addProperty("difficulty", difficulty);
      o.addProperty("sea_level", seaLevel); o.addProperty("thundering", thundering); o.addProperty("seed", seed);
      o.addProperty("slime_chance", slimeChance);
      o.add("spawn", JSON.toJsonTree(spawn));
      // The starts as the kernel keeps them: the start's box and its pieces.
      var structures = new JsonArray();
      for (var start : structureStarts()) {
        var row = new JsonObject();
        row.addProperty("id", registries.lookupOrThrow(Registries.STRUCTURE).getKey(start.getStructure()).toString());
        row.add("box", corners(start.getBoundingBox()));
        var pieces = new JsonArray();
        for (var piece : start.getPieces()) pieces.add(corners(piece.getBoundingBox()));
        row.add("pieces", pieces);
        structures.add(row);
      }
      o.add("structures", structures);
      return o;
    }
  }

  // ---------------------------------------------------------------- probe level

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers subscribers;
    private Server() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return subscribers; }
  }

  static class Player extends ServerPlayer {
    boolean spectator;
    private Player() { super(null, null, null, null); }
    public boolean isSpectator() { return spectator; }
    public boolean isCreative() { return false; }
  }

  static class Chunk extends LevelChunk {
    Probe probe; ChunkPos at;
    private Chunk() { super(null, (ChunkPos) null); }
    public ChunkPos getPos() { return at; }
    public BlockState getBlockState(BlockPos p) { return probe.getBlockState(p); }
    public FluidState getFluidState(BlockPos p) { return probe.getFluidState(p); }
    public int getHeight(Heightmap.Types t, int x, int z) { return probe.scene.height(t, x, z) - 1; }
    public int getMinY() { return -64; }
    public int getHeight() { return 384; }
    public net.minecraft.world.level.chunk.LevelChunkSection getSection(int index) { return probe.scene.section(at.x(), index - 4, at.z()); }
  }

  static JsonArray corners(net.minecraft.world.level.levelgen.structure.BoundingBox b) {
    var a = new JsonArray();
    for (int v : new int[]{b.minX(), b.minY(), b.minZ(), b.maxX(), b.maxY(), b.maxZ()}) a.add(v);
    return a;
  }

  /** The scene's structure starts (VMC-042b), each referenced by the chunks its box reaches. */
  static class Structures extends StructureManager {
    Scene scene;
    private Structures() { super(null, null, null); }
    public Map<Structure, it.unimi.dsi.fastutil.longs.LongSet> getAllStructuresAt(BlockPos p) {
      var out = new LinkedHashMap<Structure, it.unimi.dsi.fastutil.longs.LongSet>();
      for (var start : scene.structureStarts())
        if (Scene.reaches(start, p.getX() >> 4, p.getZ() >> 4))
          out.computeIfAbsent(start.getStructure(), k -> new it.unimi.dsi.fastutil.longs.LongOpenHashSet()).add(start.getChunkPos().pack());
      return out;
    }
    public void fillStartsForStructure(Structure s, it.unimi.dsi.fastutil.longs.LongSet refs, java.util.function.Consumer<StructureStart> c) {
      for (var start : scene.structureStarts())
        if (start.getStructure() == s && refs.contains(start.getChunkPos().pack())) c.accept(start);
    }
    public StructureStart getStructureAt(BlockPos p, Structure s) {
      for (var start : scene.structureStarts())
        if (start.getStructure() == s && Scene.reaches(start, p.getX() >> 4, p.getZ() >> 4) && start.getBoundingBox().isInside(p)) return start;
      return StructureStart.INVALID_START;
    }
    public RegistryAccess registryAccess() { return registries; }
  }

  static class Cache extends net.minecraft.server.level.ServerChunkCache {
    net.minecraft.world.level.chunk.ChunkGenerator generator;
    private Cache() { super(null, null, null, null, null, null, 0, 0, false, null); }
    public net.minecraft.world.level.chunk.ChunkGenerator getGenerator() { return generator; }
  }

  static class Probe extends ServerLevel {
    Scene scene; EnvironmentAttributeSystem env; Server server; GameRules rules; DamageSources sources; WorldBorder border;
    // Unsafe allocation skips initializers: `probe` sets these.
    List<Entity> entities, spawned; List<Player> players;
    boolean generation; RandomSource finalizeRandom; Holder<Biome> biome; Holder<DimensionType> dimensionType;
    ResourceKey<Level> dimensionKey; Structures structures; Cache cache;
    int ids;
    private Probe() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    public BlockState getBlockState(BlockPos p) { return scene.state(p.getX(), p.getY(), p.getZ()); }
    public FluidState getFluidState(BlockPos p) { return getBlockState(p).getFluidState(); }
    public BlockGetter getChunkForCollisions(int x, int z) { return this; }
    public net.minecraft.world.level.chunk.ChunkAccess getChunk(int x, int z, net.minecraft.world.level.chunk.status.ChunkStatus s, boolean load) { return chunk(x, z); }
    Chunk chunk(int x, int z) {
      try {
        var c = (Chunk) unsafe.allocateInstance(Chunk.class); c.probe = this; c.at = new ChunkPos(x, z); return c;
      } catch (Exception e) { throw new RuntimeException(e); }
    }
    public int getHeight(Heightmap.Types t, int x, int z) { return scene.height(t, x, z); }
    public int getBrightness(LightLayer layer, BlockPos p) {
      return layer == LightLayer.SKY ? scene.skyLight(p.getX(), p.getY(), p.getZ()) : scene.blockLight(p.getX(), p.getY(), p.getZ());
    }
    public int getRawBrightness(BlockPos p, int darken) {
      return Math.max(scene.skyLight(p.getX(), p.getY(), p.getZ()) - darken, scene.blockLight(p.getX(), p.getY(), p.getZ()));
    }
    public int getSkyDarken() { return generation ? 0 : scene.darken; }
    public boolean isThundering() { return scene.thundering; }
    public int getSeaLevel() { return scene.seaLevel; }
    public int getMinY() { return -64; }
    public int getHeight() { return 384; }
    public Holder<Biome> getBiome(BlockPos p) { return biome; }
    public EnvironmentAttributeSystem environmentAttributes() { return env; }
    public List<ServerPlayer> players() { return List.copyOf(players); }
    public Iterable<Entity> getAllEntities() { return List.copyOf(entities); }
    public int getNextEntityId() { return ++ids; }
    public boolean isLoaded(BlockPos p) { return true; }
    public boolean hasChunk(int x, int z) { return true; }
    public boolean canSpawnEntitiesInChunk(ChunkPos p) { return true; }
    public WorldBorder getWorldBorder() { return border; }
    public GameRules getGameRules() { return rules; }
    public Difficulty getDifficulty() { return Difficulty.byId(scene.difficulty); }
    public DifficultyInstance getCurrentDifficultyAt(BlockPos p) { return new DifficultyInstance(getDifficulty(), 0, 0, 0); }
    public RandomSource getRandom() { return finalizeRandom; }
    public RegistryAccess registryAccess() { return registries; }
    public FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.REGISTRY.allFlags(); }
    public StructureManager structureManager() { return structures; }
    public net.minecraft.server.level.ServerChunkCache getChunkSource() { return cache; }
    public DimensionType dimensionType() { return dimensionType.value(); }
    public Holder<DimensionType> dimensionTypeRegistration() { return dimensionType; }
    public ResourceKey<Level> dimension() { return dimensionKey; }
    public LevelData.RespawnData getRespawnData() {
      return LevelData.RespawnData.of(Level.OVERWORLD, new BlockPos(scene.spawn[0], scene.spawn[1], scene.spawn[2]), 0, 0);
    }
    public long getSeed() { return scene.seed; }
    public long getGameTime() { return 0; }
    net.minecraft.server.waypoints.ServerWaypointManager waypoints;
    public net.minecraft.server.waypoints.ServerWaypointManager getWaypointManager() {
      if (waypoints == null) waypoints = new net.minecraft.server.waypoints.ServerWaypointManager();
      return waypoints;
    }
    public ServerLevel getLevel() { return this; }
    public net.minecraft.server.MinecraftServer getServer() { return server; }
    public DamageSources damageSources() { return sources; }
    // A new mob blocks later spawns with its type's own box: what
    // finalizeSpawn changes (a slime's size) is the families' part.
    Runnable afterSpawn;
    public boolean addFreshEntity(Entity e) {
      afterSpawn.run();
      spawned.add(e);
      e.setBoundingBox(e.getType().getDimensions().makeBoundingBox(e.position()));
      if (!generation) entities.add(e);
      return true;
    }
    // Jockeys' riders (finalizeSpawn's, the families') are left out.
    public void addFreshEntityWithPassengers(Entity e) { e.ejectPassengers(); addFreshEntity(e); }
    public void gameEvent(Holder<GameEvent> e, Vec3 p, GameEvent.Context c) {}
    public void broadcastEntityEvent(Entity e, byte b) {}
    public <T extends ParticleOptions> int sendParticles(T o, double x, double y, double z, int n, double a, double b, double c, double s) { return 0; }
    public void playSeededSound(Entity e, double x, double y, double z, Holder<SoundEvent> s, SoundSource c, float v, float p, long seed) {}
    // A spawner block's tick (VMC-042b): its type's mobs around it, players in
    // range (all alive), and its events, counted.
    int levelEvents;
    public <T extends Entity> List<T> getEntities(net.minecraft.world.level.entity.EntityTypeTest<Entity, T> type, AABB box, Predicate<? super T> test) {
      var out = new ArrayList<T>();
      for (var e : entities) { T t = type.tryCast(e); if (t != null && t.getBoundingBox().intersects(box) && test.test(t)) out.add(t); }
      return out;
    }
    public boolean hasNearbyAlivePlayer(double x, double y, double z, double range) {
      for (var p : players) if (!p.isSpectator() && p.distanceToSqr(x, y, z) < range * range) return true;
      return false;
    }
    public void levelEvent(Entity source, int type, BlockPos pos, int data) { levelEvents++; }
    public boolean tryAddFreshEntityWithPassengers(Entity e) { addFreshEntityWithPassengers(e); return true; }
    public List<Entity> getEntities(Entity except, AABB box, Predicate<? super Entity> test) {
      var out = new ArrayList<Entity>();
      if (generation) return out;
      for (var e : entities) if (e != except && e.getBoundingBox().intersects(box) && test.test(e)) out.add(e);
      for (var e : players) if (e != except && e.getBoundingBox().intersects(box) && test.test(e)) out.add(e);
      return out;
    }
  }

  static ResourceKey<Level> levelKey(String dimension) {
    return ResourceKey.create(Registries.DIMENSION, Identifier.parse(dimension));
  }

  static Probe probe(Scene scene) throws Exception {
    var level = (Probe) unsafe.allocateInstance(Probe.class);
    level.scene = scene;
    level.entities = new ArrayList<>(); level.spawned = new ArrayList<>(); level.players = new ArrayList<>();
    level.afterSpawn = () -> {};
    level.rules = new GameRules(FeatureFlagSet.of());
    level.sources = (DamageSources) unsafe.allocateInstance(DamageSources.class);
    level.border = new WorldBorder();
    level.server = (Server) unsafe.allocateInstance(Server.class);
    level.server.subscribers = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    level.biome = registries.lookupOrThrow(Registries.BIOME).getOrThrow(ResourceKey.create(Registries.BIOME, Identifier.parse(scene.biome)));
    var typeName = scene.dimension;
    level.dimensionType = registries.lookupOrThrow(Registries.DIMENSION_TYPE).getOrThrow(ResourceKey.create(Registries.DIMENSION_TYPE, Identifier.parse(typeName)));
    level.dimensionKey = levelKey(scene.dimension);
    level.finalizeRandom = new LegacyRandomSource(42L);
    level.structures = (Structures) unsafe.allocateInstance(Structures.class);
    level.structures.scene = scene;
    level.cache = (Cache) unsafe.allocateInstance(Cache.class);
    level.cache.generator = (net.minecraft.world.level.chunk.ChunkGenerator) unsafe.allocateInstance(net.minecraft.world.level.levelgen.FlatLevelSource.class);
    var biome = level.biome;
    var builder = EnvironmentAttributeSystem.builder().addConstantLayer(level.dimensionType.value().attributes());
    for (var attribute : List.of(EnvironmentAttributes.NATURAL_MOB_SPAWNS, EnvironmentAttributes.CREATURE_WORLD_GEN_SPAWN_PROBABILITY))
      addBiome(builder, attribute, biome);
    builder.addConstantLayer(EnvironmentAttributes.SURFACE_SLIME_SPAWN_CHANCE, base -> scene.slimeChance);
    level.env = builder.build();
    setFinal(Level.class, "random", level, new LegacyRandomSource(0L));
    for (var p : scene.players) {
      var player = (Player) unsafe.allocateInstance(Player.class);
      player.spectator = p[3] != 0;
      place(player, EntityTypes.PLAYER, p[0], p[1], p[2]);
      level.players.add(player);
    }
    for (var e : scene.entities) {
      var entity = ((EntityType<?>) e[0]).create(level, EntitySpawnReason.NATURAL);
      entity.snapTo((double) e[1], (double) e[2], (double) e[3], 0, 0);
      level.entities.add(entity);
    }
    return level;
  }

  static <V> void addBiome(EnvironmentAttributeSystem.Builder builder, net.minecraft.world.attribute.EnvironmentAttribute<V> attribute, Holder<Biome> biome) {
    builder.addPositionalLayer(attribute, (base, pos, weights) -> biome.value().getAttributes().applyModifier(attribute, base));
  }

  static void place(Entity e, EntityType<?> type, double x, double y, double z) throws Exception {
    setFinal(Entity.class, "levelCallback", e, net.minecraft.world.level.entity.EntityInLevelCallback.NULL);
    field(Entity.class, "position").set(e, new Vec3(x, y, z));
    field(Entity.class, "blockPosition").set(e, BlockPos.containing(x, y, z));
    field(Entity.class, "bb").set(e, type.getDimensions().makeBoundingBox(x, y, z));
  }

  static long seedOf(RandomSource r) throws Exception {
    return ((java.util.concurrent.atomic.AtomicLong) field(LegacyRandomSource.class, "seed").get(r)).get();
  }

  static String bits(double d) { return HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d)); }

  static JsonArray record(Entity e) throws Exception {
    var a = new JsonArray();
    a.add(id(e.getType())); a.add(bits(e.getX())); a.add(bits(e.getY())); a.add(bits(e.getZ()));
    // The yaw the spawner drew (`snapTo` sets the old rotation too; a slime's
    // size turns it to its head in finalizeSpawn, the families' part).
    a.add(Float.floatToRawIntBits(e.yRotO));
    a.add(e instanceof TropicalFish fish ? field(TropicalFish.class, "isSchool").getBoolean(fish) : true);
    return a;
  }

  // ---------------------------------------------------------------- spawn fixtures

  /** A cap calculator that admits every category: caps are ValiMC's own tests. */
  static class Caps extends LocalMobCapCalculator {
    private Caps() { super(null); }
    public void addMob(ChunkPos p, MobCategory c) {}
    public boolean canSpawn(MobCategory c, ChunkPos p) { return true; }
  }

  /** `spawnForChunk` for chunk `(cx, cz)` once per seed, each from the scene's first state. */
  static JsonObject ticks(Scene scene, int cx, int cz, boolean persistent, int seeds) throws Exception {
    var runs = new JsonArray();
    JsonArray first = null;
    int total = 0;
    for (int seed = 1; seed <= seeds; seed++) {
      var level = probe(scene);
      var random = new LegacyRandomSource(seed * 7919L + scene.name.hashCode());
      setFinal(Level.class, "random", level, random);
      long start = seedOf(random);
      var caps = (Caps) unsafe.allocateInstance(Caps.class);
      var state = NaturalSpawner.createState(289, level, (key, out) -> out.accept(level.chunk(ChunkPos.getX(key), ChunkPos.getZ(key))), caps);
      var categories = NaturalSpawner.getFilteredSpawningCategories(state, scene.difficulty != 0, persistent);
      NaturalSpawner.spawnForChunk(level, level.chunk(cx, cz), state, categories);
      var spawns = new JsonArray();
      for (var e : level.spawned) spawns.add(record(e));
      total += level.spawned.size();
      var cats = new JsonArray(); for (var c : categories) cats.add(c.getSerializedName());
      if (seed == 1) first = cats;
      else if (!first.equals(cats)) throw new IllegalStateException("categories differ between runs");
      var run = new JsonArray(); run.add(start); run.add(seedOf(random)); run.add(spawns);
      runs.add(run);
    }
    var o = scene.json();
    o.addProperty("kind", "tick"); o.addProperty("chunk_x", cx); o.addProperty("chunk_z", cz);
    o.addProperty("persistent", persistent); o.add("categories", first); o.add("runs", runs);
    System.err.println(scene.name + ": " + total + " spawns in " + seeds + " ticks");
    return o;
  }

  /** `spawnMobsForChunkGeneration` for chunk `(cx, cz)` with its decoration seed. */
  static JsonObject generation(Scene scene, int cx, int cz) throws Exception {
    var level = probe(scene);
    level.generation = true;
    var random = new WorldgenRandom(new LegacyRandomSource(0L));
    random.setDecorationSeed(scene.seed, cx * 16, cz * 16);
    NaturalSpawner.spawnMobsForChunkGeneration(level, new BlockPos(cx * 16, 319, cz * 16), new ChunkPos(cx, cz), random);
    var spawns = new JsonArray();
    for (var e : level.spawned) spawns.add(record(e));
    var o = scene.json();
    o.addProperty("kind", "generation"); o.addProperty("chunk_x", cx); o.addProperty("chunk_z", cz);
    o.add("spawns", spawns);
    return o;
  }

  /**
   * A spawner block of `type` at `(x, y, z)` (VMC-042b): `BaseSpawner.serverTick` for `ticks`
   * ticks from its generated state (`BaseSpawner.load` of the compound decoration saves), per
   * seed. The level's random is the spawner's and its mobs' `finalizeSpawn`'s, as vanilla's;
   * each spawn records the random's state after it (its family's draws done), from which the
   * kernel goes on. Per tick: its spawns and the delay after. Its mobs leave every `CLEAR` ticks.
   */
  static final int CLEAR = 250;

  static JsonObject spawner(Scene scene, int x, int y, int z, EntityType<?> type, int ticks, int seeds) throws Exception {
    scene.fill(x, y, z, x, y, z, Blocks.SPAWNER);
    var nbt = new net.minecraft.nbt.CompoundTag();
    var entity = new net.minecraft.nbt.CompoundTag(); entity.putString("id", id(type));
    var data = new net.minecraft.nbt.CompoundTag(); data.put("entity", entity);
    nbt.put("SpawnData", data);
    nbt.putShort("Delay", (short) 20); nbt.putShort("MinSpawnDelay", (short) 200); nbt.putShort("MaxSpawnDelay", (short) 800);
    nbt.putShort("SpawnCount", (short) 4); nbt.putShort("MaxNearbyEntities", (short) 6);
    nbt.putShort("RequiredPlayerRange", (short) 16); nbt.putShort("SpawnRange", (short) 4);
    nbt.put("SpawnPotentials", new net.minecraft.nbt.ListTag());
    var runs = new JsonArray();
    int total = 0;
    var pos = new BlockPos(x, y, z);
    for (int seed = 1; seed <= seeds; seed++) {
      var level = probe(scene);
      var random = new LegacyRandomSource(seed * 104729L + scene.name.hashCode());
      setFinal(Level.class, "random", level, random);
      level.finalizeRandom = random;
      long start = seedOf(random);
      var spawner = new BaseSpawner() { public void broadcastEvent(Level l, BlockPos p, int id) {} };
      try (var reporter = new net.minecraft.util.ProblemReporter.ScopedCollector(() -> "spawner", com.mojang.logging.LogUtils.getLogger())) {
        spawner.load(level, pos, net.minecraft.world.level.storage.TagValueInput.create(reporter, registries, nbt));
      }
      var delay = field(BaseSpawner.class, "spawnDelay");
      var perTick = new JsonArray();
      for (int t = 0; t < ticks; t++) {
        int before = level.spawned.size();
        var states = new ArrayList<Long>();
        level.afterSpawn = () -> { try { states.add(seedOf(random)); } catch (Exception e) { throw new RuntimeException(e); } };
        spawner.serverTick(level, pos);
        var spawns = new JsonArray();
        // A baby zombie's chicken (its family's finalizeSpawn) is left out.
        for (int i = before; i < level.spawned.size(); i++) {
          if (level.spawned.get(i).getType() != type) continue;
          var r = record(level.spawned.get(i)); r.add(states.get(i - before)); spawns.add(r);
        }
        if (level.levelEvents != spawns.size()) throw new IllegalStateException("spawner events " + level.levelEvents + " for " + spawns.size() + " spawns");
        level.levelEvents = 0;
        total += spawns.size();
        var row = new JsonArray(); row.add(delay.getInt(spawner)); row.add(spawns);
        perTick.add(row);
        // Its mobs leave every CLEAR ticks (killed), so it spawns again.
        if ((t + 1) % CLEAR == 0) level.entities.clear();
      }
      var run = new JsonArray(); run.add(start); run.add(seedOf(random)); run.add(perTick);
      runs.add(run);
    }
    var o = scene.json();
    o.addProperty("kind", "spawner"); o.addProperty("type", id(type));
    var at = new JsonArray(); at.add(x); at.add(y); at.add(z); o.add("spawner", at);
    o.addProperty("clear", CLEAR); o.add("runs", runs);
    System.err.println(scene.name + ": " + total + " spawner spawns in " + seeds + " x " + ticks + " ticks");
    return o;
  }

  /** `checkDespawn` of a fresh mob of each type at distances from one player. */
  static JsonObject despawn() throws Exception {
    var cases = new JsonArray();
    var types = List.of(EntityTypes.ZOMBIE, EntityTypes.COW, EntityTypes.BAT, EntityTypes.COD, EntityTypes.SQUID, EntityTypes.SPIDER,
        EntityTypes.CHICKEN, EntityTypes.ZOMBIE_HORSE, EntityTypes.HOGLIN, EntityTypes.TROPICAL_FISH, EntityTypes.AXOLOTL,
        EntityTypes.GLOW_SQUID, EntityTypes.OCELOT, EntityTypes.ZOMBIE_VILLAGER, EntityTypes.PIGLIN, EntityTypes.SLIME);
    for (int difficulty : new int[]{0, 2}) for (var type : types)
      for (double d : new double[]{10, 31.9, 32.1, 63.9, 64.1, 127.9, 128.1, 200})
        for (boolean persistent : new boolean[]{false, true}) {
          var scene = new Scene("despawn", "minecraft:overworld", "minecraft:plains").player(0.5, 64, 0.5);
          var level = probe(scene);
          var mob = (Mob) type.create(level, EntitySpawnReason.NATURAL);
          scene.difficulty = difficulty;
          mob.snapTo(0.5 + d, 64, 0.5, 0, 0);
          if (persistent) mob.setPersistenceRequired();
          field(LivingEntity.class, "noActionTime").setInt(mob, 100);
          mob.checkDespawn();
          var a = new JsonArray();
          a.add(id(type)); a.add(difficulty); a.add(d); a.add(persistent); a.add(mob.isRemoved());
          a.add(field(LivingEntity.class, "noActionTime").getInt(mob));
          cases.add(a);
        }
    var o = new JsonObject(); o.addProperty("kind", "despawn"); o.add("cases", cases);
    return o;
  }

  /** `updateSkyBrightness` over a day: the dimension's layer, the day timeline, rain and thunder. */
  static JsonObject sky() throws Exception {
    var dim = registries.lookupOrThrow(Registries.DIMENSION_TYPE).getOrThrow(ResourceKey.create(Registries.DIMENSION_TYPE, Identifier.parse("minecraft:overworld")));
    var rows = new JsonArray();
    float[][] weathers = {{0, 0}, {0.3f, 0}, {1, 0}, {1, 0.5f}, {1, 1}};
    for (var w : weathers) {
      long[] ticks = {0};
      net.minecraft.world.clock.ClockManager clocks = clock -> new net.minecraft.world.clock.ClockInstance() {
        public long totalTicks() { return ticks[0]; }
        public float partialTick() { return 0; }
        public float rate() { return 1; }
        public boolean isPaused() { return false; }
      };
      var builder = EnvironmentAttributeSystem.builder().addConstantLayer(dim.value().attributes());
      for (var t : dim.value().timelines()) builder.addTimelineLayer(t, clocks);
      net.minecraft.world.attribute.WeatherAttributes.addBuiltinLayers(builder, new net.minecraft.world.attribute.WeatherAttributes.WeatherAccess() {
        public float rainLevel() { return w[0]; }
        public float thunderLevel() { return w[1]; }
      });
      var system = builder.build();
      var darken = new StringBuilder();
      for (long t = 0; t < 24000; t++) {
        ticks[0] = t + 24000L * 3;
        system.invalidateTickCache();
        darken.append(Integer.toHexString((int) (15.0F - system.getDimensionValue(EnvironmentAttributes.SKY_LIGHT_LEVEL))));
      }
      var row = new JsonObject(); row.addProperty("rain", w[0]); row.addProperty("thunder", w[1]);
      row.addProperty("darken", darken.toString()); rows.add(row);
    }
    var o = new JsonObject(); o.addProperty("kind", "sky"); o.add("rows", rows);
    return o;
  }

  /** A dungeon room in stone: cobblestone walls and floor, 7 × 4 × 7 of air around (8, 20, 8). */
  static Scene dungeon(String name) {
    return new Scene(name, "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE)
        .fill(-64, -10, -64, 79, 55, 79, Blocks.STONE).fill(4, 19, 4, 12, 24, 12, Blocks.MOSSY_COBBLESTONE)
        .fill(5, 20, 5, 11, 23, 11, Blocks.AIR);
  }

  static Scene plains(String name, int darken) {
    var s = new Scene(name, "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.DIRT);
    s.darken = darken;
    return s.player(-30.5, 64, 8.5);
  }

  static void fixtures(Path out) throws Exception {
    var cases = new JsonArray();
    // A plains night: monsters on the surface, packs, a spectator ignored and
    // the world spawn's 24-block ring.
    var night = plains("plains_night", 11).spectator(8, 64, 8);
    night.fill(20, 64, -10, 22, 70, 30, Blocks.STONE).light(4, 64, 4, 14);
    cases.add(ticks(night, 0, 0, false, 1600));
    var ring = plains("spawn_ring", 11); ring.spawn = new int[]{8, 64, 8};
    cases.add(ticks(ring, 0, 0, false, 400));
    // The players' 24-block ring and the despawn distance: one near, one far.
    cases.add(ticks(plains("near_player", 11).player(8.5, 64, 40.5), 0, 0, false, 400));
    cases.add(ticks(new Scene("far_player", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.DIRT)
        .player(-140, 64, 8), 0, 0, false, 400));
    // A plains day: creatures on the 400th tick, monsters barred by light.
    cases.add(ticks(plains("plains_day", 0), 0, 0, true, 1200));
    // Existing mobs block a spawn box (isUnobstructed) and count globally.
    var crowd = plains("crowd", 11);
    for (int i = 0; i < 12; i++) crowd.entity(EntityTypes.ZOMBIE, 2.5 + i, 64, 6.5);
    cases.add(ticks(crowd, 0, 0, false, 600));
    // A cave under stone: monsters in the dark and by a torch, bats, cave
    // lakes for glow squid and axolotls (on clay) in lush caves.
    var cave = new Scene("cave", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE);
    cave.fill(-64, -10, -64, 79, 55, 79, Blocks.STONE).fill(-20, 10, -20, 36, 16, 36, Blocks.AIR)
        .fill(-20, 9, -20, 36, 9, 36, Blocks.STONE).light(0, 11, 0, 14).player(-30.5, 11, 8.5);
    cases.add(ticks(cave, 0, 0, false, 1600));
    var lush = new Scene("lush", "minecraft:overworld", "minecraft:lush_caves").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE);
    lush.fill(-64, -10, -64, 79, 55, 79, Blocks.STONE).fill(-20, 10, -20, 36, 20, 36, Blocks.WATER)
        .fill(-20, 9, -20, 36, 9, 36, Blocks.CLAY).fill(-20, 17, -20, 36, 20, 36, Blocks.AIR).player(-30.5, 17, 8.5);
    cases.add(ticks(lush, 0, 0, false, 1600));
    var dripstone = new Scene("deep_lake", "minecraft:overworld", "minecraft:dripstone_caves").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE);
    dripstone.fill(-64, -40, -64, 79, 55, 79, Blocks.STONE).fill(-20, -20, -20, 36, 20, 36, Blocks.WATER)
        .fill(-20, -21, -20, 36, -21, 36, Blocks.GRAVEL).player(-30.5, 21, 8.5);
    cases.add(ticks(dripstone, 0, 0, false, 1200));
    // Oceans: squid, fish (reduced in a plain ocean), drowned at night, and
    // warm oceans' tropical fish schools and pufferfish.
    for (var biome : List.of("minecraft:ocean", "minecraft:warm_ocean", "minecraft:lukewarm_ocean", "minecraft:cold_ocean")) {
      var ocean = new Scene(biome.substring(10), "minecraft:overworld", biome).ground(40, Blocks.SAND, Blocks.STONE);
      ocean.fill(-64, 41, -64, 79, 62, 79, Blocks.WATER).player(-30.5, 63, 8.5);
      ocean.darken = 11;
      cases.add(ticks(ocean, 0, 0, false, 1600));
    }
    // Deserts: husks under the sky, rabbits and camels on sand by day.
    var desert = new Scene("desert", "minecraft:overworld", "minecraft:desert").ground(63, Blocks.SAND, Blocks.SANDSTONE)
        .fill(-4, 64, -4, 6, 70, 6, Blocks.SANDSTONE).fill(-3, 64, -3, 5, 66, 5, Blocks.AIR).player(-30.5, 64, 8.5);
    desert.darken = 11;
    cases.add(ticks(desert, 0, 0, false, 1200));
    var desertDay = new Scene("desert_day", "minecraft:overworld", "minecraft:desert").ground(63, Blocks.SAND, Blocks.SANDSTONE).player(-30.5, 64, 8.5);
    cases.add(ticks(desertDay, 0, 0, true, 1200));
    // Snow: strays under powder snow and open sky, polar bears and rabbits.
    var snow = new Scene("snowy_plains", "minecraft:overworld", "minecraft:snowy_plains").ground(63, Blocks.SNOW_BLOCK, Blocks.DIRT)
        .fill(0, 64, 0, 8, 64, 8, Blocks.POWDER_SNOW).player(-30.5, 64, 8.5);
    snow.darken = 11;
    cases.add(ticks(snow, 0, 0, false, 1200));
    var ice = new Scene("ice_spikes", "minecraft:overworld", "minecraft:ice_spikes").ground(63, Blocks.ICE, Blocks.PACKED_ICE).player(-30.5, 64, 8.5);
    cases.add(ticks(ice, 0, 0, true, 1200));
    // Swamps: surface slimes (the moon's chance), witches, frogs, bogged.
    var swamp = new Scene("swamp", "minecraft:overworld", "minecraft:swamp").ground(63, Blocks.GRASS_BLOCK, Blocks.DIRT)
        .fill(-64, 60, -64, 79, 62, 79, Blocks.DIRT).player(-30.5, 64, 8.5);
    swamp.darken = 11; swamp.slimeChance = 0.5f;
    cases.add(ticks(swamp, 0, 0, false, 1600));
    cases.add(ticks(new Scene("mangrove", "minecraft:overworld", "minecraft:mangrove_swamp").ground(63, Blocks.MUD, Blocks.DIRT)
        .player(-30.5, 64, 8.5), 0, 0, true, 800));
    // Slime chunks underground (the world seed's).
    var slime = new Scene("slime_chunk", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE);
    slime.fill(-64, 0, -64, 79, 55, 79, Blocks.STONE).fill(-20, 20, -20, 36, 30, 36, Blocks.AIR).player(-30.5, 21, 8.5);
    slime.seed = 42L;
    for (int cx = 0; cx < 4; cx++) cases.add(ticks(slime, cx, 0, false, 400));
    // Jungles: ocelots (two in three, on grass or leaves above the sea),
    // parrots on leaves, pandas.
    var jungle = new Scene("jungle", "minecraft:overworld", "minecraft:jungle").ground(63, Blocks.GRASS_BLOCK, Blocks.DIRT)
        .fill(0, 64, 0, 12, 68, 12, Blocks.OAK_LOG).fill(-2, 69, -2, 14, 70, 14, Blocks.JUNGLE_LEAVES).player(-30.5, 64, 8.5);
    cases.add(ticks(jungle, 0, 0, true, 1200));
    jungle.darken = 11;
    cases.add(ticks(jungle, 0, 0, false, 1200));
    // Mushroom fields: mooshrooms on mycelium, no monsters.
    var mushroom = new Scene("mushroom_fields", "minecraft:overworld", "minecraft:mushroom_fields").ground(63, Blocks.MYCELIUM, Blocks.DIRT).player(-30.5, 64, 8.5);
    cases.add(ticks(mushroom, 0, 0, true, 800));
    // Forests and mountains: wolves (packs of up to eight), foxes, goats,
    // llamas; savanna horses (clusters of six) and armadillos.
    for (var b : List.of(new Object[]{"minecraft:taiga", Blocks.PODZOL}, new Object[]{"minecraft:snowy_slopes", Blocks.SNOW_BLOCK},
        new Object[]{"minecraft:savanna", Blocks.GRASS_BLOCK}, new Object[]{"minecraft:badlands", Blocks.RED_SAND},
        new Object[]{"minecraft:forest", Blocks.GRASS_BLOCK}, new Object[]{"minecraft:windswept_hills", Blocks.STONE},
        new Object[]{"minecraft:meadow", Blocks.GRASS_BLOCK}, new Object[]{"minecraft:beach", Blocks.SAND})) {
      var name = (String) b[0];
      cases.add(ticks(new Scene(name.substring(10), "minecraft:overworld", name).ground(63, (Block) b[1], Blocks.DIRT).player(-30.5, 64, 8.5), 0, 0, true, 800));
    }
    // The Nether: its light test, spawn costs (soul sand valley, basalt
    // deltas), striders in lava, ghasts one in twenty, piglins and hoglins.
    for (var b : List.of(new Object[]{"minecraft:nether_wastes", Blocks.NETHERRACK}, new Object[]{"minecraft:crimson_forest", Blocks.CRIMSON_NYLIUM},
        new Object[]{"minecraft:warped_forest", Blocks.WARPED_NYLIUM}, new Object[]{"minecraft:soul_sand_valley", Blocks.SOUL_SOIL},
        new Object[]{"minecraft:basalt_deltas", Blocks.BASALT})) {
      var name = (String) b[0];
      var nether = new Scene(name.substring(10), "minecraft:the_nether", name).ground(31, (Block) b[1], Blocks.NETHERRACK)
          .fill(-64, 100, -64, 79, 127, 79, Blocks.NETHERRACK).fill(20, 32, 20, 40, 33, 40, Blocks.LAVA).player(-30.5, 32, 8.5);
      nether.entity(EntityTypes.SKELETON, 4.5, 32, 4.5).entity(EntityTypes.MAGMA_CUBE, 10.5, 32, 4.5).entity(EntityTypes.GHAST, 8.5, 40, 12.5);
      cases.add(ticks(nether, 0, 0, false, 1600));
    }
    // The End: endermen on end stone.
    cases.add(ticks(new Scene("end_highlands", "minecraft:the_end", "minecraft:end_highlands").ground(60, Blocks.END_STONE, Blocks.END_STONE)
        .player(-30.5, 61, 8.5), 0, 0, false, 800));
    // Peaceful: only friendly categories, no monsters by their rules.
    var peaceful = plains("peaceful", 11); peaceful.difficulty = 0;
    cases.add(ticks(peaceful, 0, 0, true, 600));
    // Thunder lowers the brightness monsters need (`getMaxLocalRawBrightness(pos, 10)`).
    var thunder = plains("thunder", 0); thunder.thundering = true;
    cases.add(ticks(thunder, 0, 0, false, 800));

    // Spawns with a generated chunk: creatures of the biome, a ceiling's scan.
    for (var b : List.of(new Object[]{"minecraft:plains", Blocks.GRASS_BLOCK}, new Object[]{"minecraft:savanna", Blocks.GRASS_BLOCK},
        new Object[]{"minecraft:snowy_plains", Blocks.SNOW_BLOCK}, new Object[]{"minecraft:desert", Blocks.SAND},
        new Object[]{"minecraft:taiga", Blocks.GRASS_BLOCK}, new Object[]{"minecraft:jungle", Blocks.GRASS_BLOCK},
        new Object[]{"minecraft:mushroom_fields", Blocks.MYCELIUM})) {
      var name = (String) b[0];
      var scene = new Scene("generated_" + name.substring(10), "minecraft:overworld", name).ground(70, (Block) b[1], Blocks.DIRT)
          .fill(3, 71, 3, 5, 74, 5, Blocks.OAK_LOG).fill(10, 71, 2, 10, 71, 12, Blocks.WATER);
      for (int c = 0; c < 160; c++) cases.add(generation(scene, c % 20 - 10, c / 20 - 4));
    }
    var crimson = new Scene("generated_crimson_forest", "minecraft:the_nether", "minecraft:crimson_forest").ground(31, Blocks.CRIMSON_NYLIUM, Blocks.NETHERRACK)
        .fill(-64, 100, -64, 79, 127, 79, Blocks.NETHERRACK).fill(-64, 32, -64, 79, 33, 79, Blocks.LAVA);
    for (int c = 0; c < 160; c++) cases.add(generation(crimson, c % 20 - 10, c / 20 - 4));

    // Structure spawn overrides (VMC-042b): a swamp hut's witches and cats in
    // its piece, a monument's guardians, an outpost's pillagers, a fortress's
    // enemies on its nether bricks and in its pieces, nothing in an ancient
    // city or in a trial chamber's pieces.
    var hut = new Scene("swamp_hut", "minecraft:overworld", "minecraft:swamp").ground(63, Blocks.GRASS_BLOCK, Blocks.DIRT)
        .fill(1, 64, 1, 9, 64, 11, Blocks.SPRUCE_PLANKS).start("minecraft:swamp_hut", new int[]{1, 64, 1, 9, 70, 11}).player(-30.5, 64, 8.5);
    hut.darken = 11;
    cases.add(ticks(hut, 0, 0, false, 1600));
    cases.add(ticks(hut, 0, 0, true, 800));
    var monument = new Scene("monument", "minecraft:overworld", "minecraft:deep_ocean").ground(30, Blocks.GRAVEL, Blocks.STONE);
    monument.fill(-64, 31, -64, 79, 62, 79, Blocks.WATER).fill(0, 31, 0, 30, 33, 30, Blocks.PRISMARINE_BRICKS)
        .start("minecraft:monument", new int[]{0, 31, 0, 57, 61, 57}).player(-30.5, 63, 8.5);
    monument.darken = 11;
    cases.add(ticks(monument, 0, 0, false, 1600));
    var outpost = plains("pillager_outpost", 11).start("minecraft:pillager_outpost", new int[]{2, 64, 2, 13, 86, 13}, new int[]{20, 64, 4, 26, 70, 10});
    cases.add(ticks(outpost, 0, 0, false, 1600));
    var bricks = new Scene("fortress", "minecraft:the_nether", "minecraft:nether_wastes").ground(31, Blocks.NETHERRACK, Blocks.NETHERRACK)
        .fill(-64, 100, -64, 79, 127, 79, Blocks.NETHERRACK).fill(0, 31, 0, 15, 31, 7, Blocks.NETHER_BRICKS)
        .start("minecraft:fortress", new int[]{0, 32, 0, 7, 40, 15}, new int[]{-20, 32, 20, 40, 34, 30}).player(-30.5, 32, 8.5);
    cases.add(ticks(bricks, 0, 0, false, 4800));
    var city = new Scene("ancient_city", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE);
    city.fill(-64, -10, -64, 79, 55, 79, Blocks.DEEPSLATE).fill(-20, 10, -20, 36, 16, 36, Blocks.AIR).fill(-20, 9, -20, 36, 9, 36, Blocks.DEEPSLATE_TILES)
        .start("minecraft:ancient_city", new int[]{0, 9, 0, 15, 20, 15}).player(-30.5, 11, 8.5);
    cases.add(ticks(city, 0, 0, false, 1200));
    var chambers = new Scene("trial_chambers", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE);
    chambers.fill(-64, -10, -64, 79, 55, 79, Blocks.STONE).fill(-20, 10, -20, 36, 16, 36, Blocks.AIR).fill(-20, 9, -20, 36, 9, 36, Blocks.TUFF_BRICKS)
        .start("minecraft:trial_chambers", new int[]{0, 9, 0, 7, 16, 15}, new int[]{8, 9, 0, 15, 12, 7}).player(-30.5, 11, 8.5);
    cases.add(ticks(chambers, 0, 0, false, 1200));

    // Spawner blocks (VMC-042b): a dungeon's zombies, skeletons and spiders in
    // the dark, lit (no zombies), at peace (none) and with the player out of
    // range; a fortress's blazes (any light); a mineshaft corridor's cave
    // spiders; a stronghold's silverfish.
    for (var type : List.of(EntityTypes.ZOMBIE, EntityTypes.SKELETON, EntityTypes.SPIDER)) {
      cases.add(spawner(dungeon("dungeon_" + id(type).substring(10)).player(5.5, 20, 5.5), 8, 20, 8, type, 4000, 3));
    }
    cases.add(spawner(dungeon("dungeon_lit").light(8, 21, 6, 14).player(5.5, 20, 5.5), 8, 20, 8, EntityTypes.ZOMBIE, 400, 2));
    var peace = dungeon("dungeon_peaceful").player(5.5, 20, 5.5); peace.difficulty = 0;
    cases.add(spawner(peace, 8, 20, 8, EntityTypes.ZOMBIE, 200, 1));
    cases.add(spawner(dungeon("dungeon_far").player(8.5, 20, 24.5), 8, 20, 8, EntityTypes.ZOMBIE, 200, 1));
    var fortress = new Scene("fortress_blaze", "minecraft:the_nether", "minecraft:nether_wastes").ground(47, Blocks.NETHER_BRICKS, Blocks.NETHERRACK)
        .fill(-64, 56, -64, 79, 127, 79, Blocks.NETHERRACK).fill(0, 48, 0, 16, 49, 16, Blocks.NETHER_BRICK_FENCE).fill(1, 48, 1, 15, 49, 15, Blocks.AIR)
        .fill(10, 48, 10, 11, 48, 11, Blocks.LAVA).player(3.5, 48, 3.5);
    cases.add(spawner(fortress, 8, 48, 8, EntityTypes.BLAZE, 4000, 3));
    var corridor = new Scene("mineshaft_cave_spider", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE)
        .fill(-64, -10, -64, 79, 55, 79, Blocks.STONE).fill(7, 20, -10, 9, 22, 26, Blocks.AIR).fill(7, 22, 4, 9, 22, 12, Blocks.COBWEB)
        .player(8.5, 20, -4.5);
    cases.add(spawner(corridor, 8, 20, 8, EntityTypes.CAVE_SPIDER, 4000, 3));
    var stronghold = new Scene("stronghold_silverfish", "minecraft:overworld", "minecraft:plains").ground(63, Blocks.GRASS_BLOCK, Blocks.STONE)
        .fill(-64, -10, -64, 79, 55, 79, Blocks.STONE_BRICKS).fill(2, 20, 2, 14, 26, 14, Blocks.AIR).fill(6, 20, 6, 10, 22, 10, Blocks.END_PORTAL_FRAME)
        .fill(7, 23, 7, 9, 23, 9, Blocks.AIR).light(3, 21, 3, 14).player(4.5, 20, 4.5);
    cases.add(spawner(stronghold, 8, 23, 3, EntityTypes.SILVERFISH, 4000, 3));

    cases.add(despawn());
    cases.add(sky());
    var root = new JsonObject();
    root.addProperty("version", "26.3");
    root.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    root.add("cases", cases);
    Files.writeString(out, JSON.toJson(root));
    System.out.println("PASS: " + cases.size() + " natural spawning cases (spawn ticks, chunk generation, despawn, sky).");
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    unsafe = (sun.misc.Unsafe) field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    registries = WorldgenFactsOracle.loadRegistries(List.of());
    switch (args[0]) {
      case "facts" -> facts(Path.of(args[1]));
      case "fixtures" -> fixtures(Path.of(args[1]));
      default -> throw new IllegalArgumentException(args[0]);
    }
  }
}
