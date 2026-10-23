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
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.goal.Goal;
import net.minecraft.world.entity.ai.goal.GoalSelector;
import net.minecraft.world.entity.ai.goal.WrappedGoal;
import net.minecraft.world.entity.ai.navigation.GroundPathNavigation;
import net.minecraft.world.entity.ai.navigation.PathNavigation;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.pathfinder.Node;
import net.minecraft.world.level.pathfinder.Path;
import net.minecraft.world.level.pathfinder.PathFinder;
import net.minecraft.world.level.pathfinder.PathType;
import net.minecraft.world.phys.*;

/**
 * Mob AI (VMC-041a). `facts OUT` writes what the AI context reads of vanilla:
 * `Mth.atan2`'s tables, every block state's path type (`WalkNodeEvaluator.
 * getPathTypeFromState`) and the path types' default malus, the items whose
 * `mob_visibility` hides their wearer, and per modelled mob its head limits,
 * ambient sound, malus overrides and registered goals. `cases OUT` ticks
 * whole vanilla mobs with their own goals over block scenes beside fake
 * players, as `ServerLevel` does (`checkDespawn`, the old position,
 * `tickCount`, `tick`), then each player's push (its connection's tick
 * follows the level's): every tick each mob's position, rotations, random
 * seed, running goals, target, path and the hits and sounds it made.
 * Navigation is vanilla's own (`GroundPathNavigation`, `PathFinder`) over
 * the scene's chunks. `paths OUT` runs single searches of the walk, swim,
 * fly and amphibious evaluators over scenes (walls, doors, fences, water,
 * chunk and section lines) with the mob as each evaluator read it.
 */
public class MobAiOracle {
  static sun.misc.Unsafe unsafe;
  static final List<String> MOBS = List.of("minecraft:zombie", "minecraft:pig", "minecraft:piglin",
      // VMC-043d's Nether mobs (cases in NetherMobOracle).
      "minecraft:blaze", "minecraft:zombified_piglin");
  // The sounds a piglin's activities play (`PiglinAi.getSoundForActivity`).
  static final List<String> SOUNDS = List.of("minecraft:entity.piglin.ambient", "minecraft:entity.piglin.admiring_item",
      "minecraft:entity.piglin.jealous", "minecraft:entity.piglin.retreat", "minecraft:entity.piglin.angry",
      "minecraft:entity.piglin.celebrate",
      // A zombified piglin's anger (VMC-043d).
      "minecraft:entity.zombified_piglin.angry");

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers subscribers;
    net.minecraft.server.ReloadableServerRegistries.Holder registries;
    private Server() { super(null,null,null,null,Optional.empty(),null,null,null,null,null); }
    public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return subscribers; }
    public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
  }

  /** A chunk that reads the scene: goals scan blocks through `getChunk`. */
  static class SceneChunk extends net.minecraft.world.level.chunk.ProtoChunk {
    Probe level;
    private SceneChunk() { super(null, null, null, null, null); }
    public BlockState getBlockState(BlockPos p) { return level.getBlockState(p); }
    public FluidState getFluidState(BlockPos p) { return level.getFluidState(p); }
  }

  /** A section holding nothing a filtered scan (a piglin's repellents) looks for. */
  static class EmptySection extends net.minecraft.world.level.chunk.LevelChunkSection {
    private EmptySection() { super(null, null); }
    public boolean maybeHas(Predicate<BlockState> predicate) { return false; }
  }

  /** The chunk a filtered block scan reads: its sections hold nothing it wants. */
  static class ScanChunk extends net.minecraft.world.level.chunk.LevelChunk {
    EmptySection section;
    private ScanChunk() { super(null, null); }
    public net.minecraft.world.level.chunk.LevelChunkSection getSection(int index) { return section; }
    public int getSectionIndexFromSectionY(int sectionY) { return 0; }
  }

  /** The chunk a path's region reads (`getChunkNow`): the scene. */
  static class PathChunk extends net.minecraft.world.level.chunk.LevelChunk {
    Probe level;
    private PathChunk() { super(null, null); }
    public BlockState getBlockState(BlockPos p) { return level.getBlockState(p); }
    public FluidState getFluidState(BlockPos p) { return level.getFluidState(p); }
    public FluidState getFluidState(int x, int y, int z) { return level.getFluidState(new BlockPos(x, y, z)); }
    public boolean isYSpaceEmpty(int from, int to) { return false; }
  }

  /** Every chunk is the scene's: navigation and its path regions read it. */
  static class NoChunks extends net.minecraft.server.level.ServerChunkCache {
    private NoChunks() { super(null, null, null, null, null, null, 0, 0, false, null); }
    PathChunk path;
    public net.minecraft.world.level.chunk.LevelChunk getChunkNow(int x, int z) {
      if (path == null) {
        try {
          path = (PathChunk)unsafe.allocateInstance(PathChunk.class);
          path.level = level;
        } catch (Exception e) { throw new RuntimeException(e); }
      }
      return path;
    }
    Probe level;
    // A swing (`ClientboundAnimatePacket`) is recorded as the entity's event.
    public void sendToTrackingPlayers(Entity e, net.minecraft.network.protocol.Packet<? super net.minecraft.network.protocol.game.ClientGamePacketListener> packet) {
      if (packet instanceof net.minecraft.network.protocol.game.ClientboundTakeItemEntityPacket t) {
        for (var m : level.entities) if (m.getId() == t.getPlayerId()) {
          var o = new JsonObject(); o.addProperty("take", t.getAmount()); level.sounds.computeIfAbsent(m, k -> new ArrayList<>()).add(o);
        }
      }
      if (packet instanceof net.minecraft.network.protocol.game.ClientboundSwingAnimationPacket a) {
        var o = new JsonObject(); o.addProperty("swing", a.hand().name().toLowerCase() + ":" + a.animation().type().getSerializedName() + ":" + a.animation().duration());
        level.sounds.computeIfAbsent(e, k -> new ArrayList<>()).add(o);
      }
    }
  }

  static class Probe extends ServerLevel {
    net.minecraft.world.attribute.EnvironmentAttributeSystem env;
    public net.minecraft.world.attribute.EnvironmentAttributeSystem environmentAttributes() { return env; }
    Server server;
    public net.minecraft.server.MinecraftServer getServer() { return server; }
    Map<BlockPos, BlockState> blocks; List<Entity> entities; List<Player> fighters; GameRules rules; DamageSources sources; WorldBorder border;
    RegistryAccess access; long time; int ids; SceneChunk chunk;
    Map<Entity, List<JsonObject>> sounds;
    // The mob ticking: what it adds to the level and its level events are its own.
    Entity current;
    private Probe() { super(null,null,null,null,null,null,false,0L,List.of(),false); }
    public RegistryAccess registryAccess() { return access; }
    public BlockState getBlockState(BlockPos p) { return blocks.getOrDefault(p, Blocks.AIR.defaultBlockState()); }
    public FluidState getFluidState(BlockPos p) { return getBlockState(p).getFluidState(); }
    public BlockGetter getChunkForCollisions(int x, int z) { return this; }
    public net.minecraft.world.level.chunk.ChunkAccess getChunk(int x, int z, net.minecraft.world.level.chunk.status.ChunkStatus s, boolean load) {
      if (chunk == null) {
        try {
          chunk = (SceneChunk)unsafe.allocateInstance(SceneChunk.class);
          chunk.level = this;
          // Every section reports fluid: fluid lookups then read the scene.
          var sections = new net.minecraft.world.level.chunk.LevelChunkSection[24];
          for (int i = 0; i < 24; i++) {
            sections[i] = (net.minecraft.world.level.chunk.LevelChunkSection)unsafe.allocateInstance(net.minecraft.world.level.chunk.LevelChunkSection.class);
            field(net.minecraft.world.level.chunk.LevelChunkSection.class, "fluidCount").setShort(sections[i], (short)1);
            field(net.minecraft.world.level.chunk.LevelChunkSection.class, "tickingFluidCount").setShort(sections[i], (short)1);
          }
          setFinal(net.minecraft.world.level.chunk.ChunkAccess.class, "sections", chunk, sections);
          setFinal(net.minecraft.world.level.chunk.ChunkAccess.class, "levelHeightAccessor", chunk, this);
        } catch (Exception e) { throw new RuntimeException(e); }
      }
      return chunk;
    }
    @SuppressWarnings({"unchecked","rawtypes"})
    public List<ServerPlayer> players() { return (List)fighters; }
    ScanChunk scan;
    public net.minecraft.world.level.chunk.LevelChunk getChunk(int x, int z) {
      if (scan == null) {
        try {
          scan = (ScanChunk)unsafe.allocateInstance(ScanChunk.class);
          scan.section = (EmptySection)unsafe.allocateInstance(EmptySection.class);
        } catch (Exception e) { throw new RuntimeException(e); }
      }
      return scan;
    }
    public int getNextEntityId() { return ++ids; }
    public boolean isLoaded(BlockPos p) { return true; }
    public boolean isRainingAt(BlockPos p) { return false; }
    public boolean isPositionEntityTicking(BlockPos p) { return true; }
    // No light: brightness reads 0 (a monster's idle time ignores it).
    public boolean hasChunk(int x, int z) { return false; }
    public float getLightLevelDependentMagicValue(BlockPos p) { return 0.0F; }
    public int getRawBrightness(BlockPos p, int darkening) { return 0; }
    // Night, and no village.
    public boolean isBrightOutside() { return false; }
    public boolean isCloseToVillage(BlockPos p, int r) { return false; }
    public boolean isVillage(BlockPos p) { return false; }
    public WorldBorder getWorldBorder() { return border; }
    public int getMinY() { return -64; }
    public int getSeaLevel() { return 63; }
    public int getHeight() { return 384; }
    public long getGameTime() { return time; }
    public GameRules getGameRules() { return rules; }
    public DamageSources damageSources() { return sources; }
    public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    public net.minecraft.world.Difficulty getDifficulty() { return net.minecraft.world.Difficulty.NORMAL; }
    public net.minecraft.world.DifficultyInstance getCurrentDifficultyAt(BlockPos pos) {
      return new net.minecraft.world.DifficultyInstance(net.minecraft.world.Difficulty.NORMAL, 0L, 0L, 0.0F);
    }
    net.minecraft.server.ServerScoreboard scoreboard;
    public net.minecraft.server.ServerScoreboard getScoreboard() {
      if (scoreboard == null) scoreboard = new net.minecraft.server.ServerScoreboard(server);
      return scoreboard;
    }
    public void gameEvent(Holder<GameEvent> e, Vec3 p, GameEvent.Context c) {}
    // An entity a mob adds (a projectile, a thrown item) is recorded, not ticked.
    public boolean addFreshEntity(Entity e) {
      if (current == null) return false;
      var o = new JsonObject(); o.addProperty("add", BuiltInRegistries.ENTITY_TYPE.getKey(e.getType()).toString());
      o.add("position", bits(e.position())); o.add("velocity", bits(e.getDeltaMovement()));
      o.addProperty("yaw", Float.floatToRawIntBits(e.getYRot())); o.addProperty("pitch", Float.floatToRawIntBits(e.getXRot()));
      if (e instanceof net.minecraft.world.entity.item.ItemEntity item) {
        o.addProperty("item", BuiltInRegistries.ITEM.getKey(item.getItem().getItem()).toString()); o.addProperty("count", item.getItem().getCount());
      }
      sounds.computeIfAbsent(current, k -> new ArrayList<>()).add(o);
      return true;
    }
    public void levelEvent(Entity source, int type, BlockPos pos, int data) {
      if (current == null) return;
      var o = new JsonObject(); o.addProperty("event", type);
      var p = new JsonArray(); p.add(pos.getX()); p.add(pos.getY()); p.add(pos.getZ()); o.add("at", p); o.addProperty("data", data);
      sounds.computeIfAbsent(current, k -> new ArrayList<>()).add(o);
    }
    public void broadcastEntityEvent(Entity e, byte b) {}
    public void broadcastDamageEvent(Entity e, DamageSource s) {}
    public <T extends ParticleOptions> int sendParticles(T o, double x, double y, double z, int n, double a, double b, double c, double s) { return 0; }
    void sound(Entity e, Holder<SoundEvent> s, float volume, float pitch) {
      if (e == null) return;
      var o = new JsonObject(); o.addProperty("sound", s.value().location().toString());
      o.addProperty("volume", Float.floatToRawIntBits(volume)); o.addProperty("pitch", Float.floatToRawIntBits(pitch));
      sounds.computeIfAbsent(e, k -> new ArrayList<>()).add(o);
    }
    // `Entity.playSound` plays at the entity for everyone (no except): the
    // sound is the nearest ticking mob's.
    public void playSeededSound(Entity e, double x, double y, double z, Holder<SoundEvent> s, SoundSource c, float v, float p, long seed) {
      Entity at = null;
      for (var m : entities) if (m.getX() == x && m.getY() == y && m.getZ() == z) at = m;
      sound(at, s, v, p);
    }
    public void playSeededSound(Entity e, Entity t, Holder<SoundEvent> s, SoundSource c, float v, float p, long seed) { sound(t, s, v, p); }
    public List<Entity> getEntities(Entity except, AABB box, Predicate<? super Entity> test) {
      var out = new ArrayList<Entity>();
      for (var e : entities) if (!e.isRemoved() && e != except && e.getBoundingBox().intersects(box) && test.test(e)) out.add(e);
      return out;
    }
    public <T extends Entity> List<T> getEntitiesOfClass(Class<T> type, AABB box, Predicate<? super T> test) {
      var out = new ArrayList<T>();
      for (var e : entities) if (!e.isRemoved() && type.isInstance(e) && e.getBoundingBox().intersects(box) && test.test(type.cast(e))) out.add(type.cast(e));
      return out;
    }
  }

  /** A player standing still: hits on it are recorded, not applied. */
  static class Fighter extends Player {
    net.minecraft.world.level.GameType mode;
    final List<JsonObject> hits = new ArrayList<>();
    Fighter(net.minecraft.world.level.Level level, int n, net.minecraft.world.level.GameType mode) {
      super(level, new com.mojang.authlib.GameProfile(new UUID(1, n), "Fighter" + n));
      this.mode = mode;
      getAbilities().invulnerable = mode == net.minecraft.world.level.GameType.CREATIVE;
    }
    public net.minecraft.world.level.GameType gameMode() { return mode; }
    public boolean hurtServer(ServerLevel level, DamageSource source, float amount) {
      var o = new JsonObject(); o.addProperty("player", getUUID().getLeastSignificantBits());
      o.addProperty("amount", Float.floatToRawIntBits(amount)); o.addProperty("type", source.typeHolder().unwrapKey().orElseThrow().identifier().toString());
      o.addProperty("by", source.getEntity() == null ? -1 : source.getEntity().getId());
      hits.add(o);
      return true;
    }
  }

  static class Zombie extends net.minecraft.world.entity.monster.zombie.Zombie {
    Zombie(Probe level) { super(EntityTypes.ZOMBIE, level); }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
    protected boolean convertsInWater() { return false; }
  }

  static class Pig extends net.minecraft.world.entity.animal.pig.Pig {
    Pig(Probe level) { super(EntityTypes.PIG, level); }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
  }

  static class Piglin extends net.minecraft.world.entity.monster.piglin.Piglin {
    Piglin(Probe level) { super(EntityTypes.PIGLIN, level); }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
    // A piglin-safe level (the Nether's): it does not zombify.
    public boolean isConverting() { return false; }
  }

  static net.minecraft.world.entity.Mob mob(String type, Probe level) {
    return switch (type) {
      case "minecraft:zombie" -> new Zombie(level);
      case "minecraft:pig" -> new Pig(level);
      case "minecraft:piglin" -> new Piglin(level);
      // Any other type as its own factory makes it (no `finalizeSpawn`).
      default -> (net.minecraft.world.entity.Mob)BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(type)).create(level, EntitySpawnReason.COMMAND);
    };
  }

  static void setFinal(Class<?> c, String n, Object o, Object v) throws Exception {
    var f = c.getDeclaredField(n); unsafe.putObject(o, unsafe.objectFieldOffset(f), v);
  }
  static Field field(Class<?> c, String n) throws Exception { var f=c.getDeclaredField(n); f.setAccessible(true); return f; }
  static String bits(double d) { return HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d)); }
  static JsonArray bits(Vec3 v) { var a=new JsonArray(); a.add(bits(v.x)); a.add(bits(v.y)); a.add(bits(v.z)); return a; }

  // The vanilla data pack's tags of `registry`, bound to its holders.
  @SuppressWarnings({"unchecked","rawtypes"})
  static void bind(net.minecraft.server.packs.resources.ResourceManager resources, net.minecraft.core.Registry registry) throws Exception {
    Map<Object, Collection<Object>> tags = (Map)net.minecraft.tags.TagLoader.loadTagsForRegistry(resources, registry.key(), (id, required) -> registry.get((Identifier)id));
    var memberships = new HashMap<Object, List<Object>>();
    for (var entry : tags.entrySet()) for (var h : entry.getValue()) memberships.computeIfAbsent(h, k -> new ArrayList<>()).add(entry.getKey());
    var bindTags = Holder.Reference.class.getDeclaredMethod("bindTags", Collection.class); bindTags.setAccessible(true);
    for (Object holder : (List)registry.listElements().toList()) bindTags.invoke(holder, memberships.getOrDefault(holder, List.of()));
  }

  static <T> MappedRegistry<T> registry(ResourceKey<Registry<T>> key, HolderLookup.Provider lookup) {
    var source = lookup.lookupOrThrow(key);
    var result = new MappedRegistry<T>(key, com.mojang.serialization.Lifecycle.stable());
    for (var id : source.listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString())).toList())
      result.register(id, source.getOrThrow(id).value(), RegistrationInfo.BUILT_IN);
    result.freeze();
    return result;
  }

  static Probe probe(HolderLookup.Provider lookup, RegistryAccess access, DamageSources sources) throws Exception {
    var level = (Probe)unsafe.allocateInstance(Probe.class);
    level.blocks = new HashMap<>(); level.entities = new ArrayList<>(); level.fighters = new ArrayList<>();
    level.sounds = new HashMap<>();
    level.rules = new GameRules(FeatureFlagSet.of());
    level.border = new WorldBorder();
    level.env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    level.server = (Server)unsafe.allocateInstance(Server.class);
    level.server.subscribers = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    level.server.registries = new net.minecraft.server.ReloadableServerRegistries.Holder(lookup);
    level.access = access;
    level.sources = sources;
    level.time = 1000L;
    var chunks = (NoChunks)unsafe.allocateInstance(NoChunks.class);
    chunks.level = level;
    setFinal(ServerLevel.class, "chunkSource", level, chunks);
    for (var f : List.of("random", "threadSafeRandom", "soundSeedGenerator")) {
      try {
        var field = net.minecraft.world.level.Level.class.getDeclaredField(f);
        unsafe.putObject(level, unsafe.objectFieldOffset(field), net.minecraft.util.RandomSource.create(7L));
      } catch (NoSuchFieldException e) {}
    }
    return level;
  }

  // ---- facts ----

  static String goalName(Goal g) {
    Class<?> c = g.getClass();
    while (c.isAnonymousClass() || c.getName().startsWith("MobAiOracle")) c = c.getSuperclass();
    return c.getSimpleName();
  }

  static JsonArray goals(GoalSelector selector) {
    var out = new JsonArray();
    for (WrappedGoal w : selector.getAvailableGoals()) {
      var row = new JsonArray(); row.add(w.getPriority()); row.add(goalName(w.getGoal()));
      var flags = new JsonArray(); for (var f : w.getFlags()) flags.add(f.name().toLowerCase()); row.add(flags);
      out.add(row);
    }
    return out;
  }

  static JsonObject facts(Probe level) throws Exception {
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var asin = new JsonArray(); var cos = new JsonArray();
    for (var d : (double[])field(net.minecraft.util.Mth.class, "ASIN_TAB").get(null)) asin.add(bits(d));
    for (var d : (double[])field(net.minecraft.util.Mth.class, "COS_TAB").get(null)) cos.add(bits(d));
    var atan = new JsonObject(); atan.add("asin", asin); atan.add("cos", cos); out.add("atan2", atan);
    var types = new JsonArray();
    for (var t : PathType.values()) { var o = new JsonObject(); o.addProperty("name", t.name().toLowerCase()); o.addProperty("malus", t.getMalus()); types.add(o); }
    out.add("path_types", types);
    // Every state's path type, one byte per state id.
    var fromState = net.minecraft.world.level.pathfinder.WalkNodeEvaluator.class.getDeclaredMethod("getPathTypeFromState", BlockGetter.class, BlockPos.class);
    fromState.setAccessible(true);
    var states = new StringBuilder();
    var origin = BlockPos.ZERO;
    for (int id = 0; id < net.minecraft.world.level.block.Block.BLOCK_STATE_REGISTRY.size(); id++) {
      var state = net.minecraft.world.level.block.Block.BLOCK_STATE_REGISTRY.byId(id);
      level.blocks.put(origin, state);
      states.append(String.format("%02x", ((PathType)fromState.invoke(null, level, origin)).ordinal()));
    }
    level.blocks.clear();
    out.addProperty("path_type_states", states.toString());
    // Per state what the node evaluators ask of it beyond its path type:
    // bit 0..2 `isPathfindable` for land, water and air, bit 3 the water block.
    var flags = new StringBuilder();
    var kinds = net.minecraft.world.level.pathfinder.PathComputationType.values();
    for (int id = 0; id < net.minecraft.world.level.block.Block.BLOCK_STATE_REGISTRY.size(); id++) {
      var state = net.minecraft.world.level.block.Block.BLOCK_STATE_REGISTRY.byId(id);
      int bits = 0;
      for (var kind : kinds) if (state.isPathfindable(kind)) bits |= 1 << kind.ordinal();
      if (state.is(Blocks.WATER)) bits |= 8;
      flags.append(String.format("%02x", bits));
    }
    out.addProperty("path_flags", flags.toString());
    var hidden = new JsonObject();
    BuiltInRegistries.ITEM.keySet().stream().sorted(Comparator.comparing(Identifier::toString)).forEach(id -> {
      var item = BuiltInRegistries.ITEM.getValue(id);
      var v = item.components().get(net.minecraft.core.component.DataComponents.MOB_VISIBILITY);
      var e = item.components().get(net.minecraft.core.component.DataComponents.EQUIPPABLE);
      if (v == null || e == null) return;
      var o = new JsonObject(); o.addProperty("visibility", v.visibility()); o.addProperty("slot", e.slot().getName());
      var t = new JsonArray(); v.targetingEntityTypes().forEach(h -> t.add(h.unwrapKey().orElseThrow().identifier().toString()));
      o.add("types", t); hidden.add(id.toString(), o);
    });
    out.add("mob_visibility", hidden);
    var mobs = new JsonObject();
    var ambient = net.minecraft.world.entity.Mob.class.getDeclaredMethod("getAmbientSound"); ambient.setAccessible(true);
    var volume = LivingEntity.class.getDeclaredMethod("getSoundVolume"); volume.setAccessible(true);
    var goalSelector = field(net.minecraft.world.entity.Mob.class, "goalSelector");
    var targetSelector = field(net.minecraft.world.entity.Mob.class, "targetSelector");
    for (var name : MOBS) {
      net.minecraft.world.entity.Mob mob = mob(name, level);
      var row = new JsonObject();
      row.addProperty("max_head_y_rot", mob.getMaxHeadYRot());
      row.addProperty("max_head_x_rot", mob.getMaxHeadXRot());
      row.addProperty("head_rot_speed", mob.getHeadRotSpeed());
      var sound = (SoundEvent)ambient.invoke(mob);
      row.addProperty("ambient_sound", sound == null ? null : sound.location().toString());
      row.addProperty("ambient_sound_interval", mob.getAmbientSoundInterval());
      row.addProperty("sound_volume", (float)volume.invoke(mob));
      var malus = new JsonObject();
      for (var t : PathType.values()) if (mob.getPathfindingMalus(t) != t.getMalus()) malus.addProperty(t.name().toLowerCase(), mob.getPathfindingMalus(t));
      row.add("malus", malus);
      row.add("goals", goals((GoalSelector)goalSelector.get(mob)));
      row.add("targets", goals((GoalSelector)targetSelector.get(mob)));
      mobs.add(name, row);
    }
    out.add("mobs", mobs);
    var sounds = new JsonObject();
    var names = new ArrayList<String>(SOUNDS);
    for (var m : mobs.entrySet()) {
      var s = m.getValue().getAsJsonObject().get("ambient_sound");
      if (!s.isJsonNull()) names.add(s.getAsString());
    }
    for (var n : names) sounds.addProperty(n, BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(n))));
    out.add("sounds", sounds);
    // A main-hand swing of the default animation (an empty hand's), after
    // its entity id: `ClientboundSwingAnimationPacket`'s fields.
    var buf = io.netty.buffer.Unpooled.buffer();
    net.minecraft.network.protocol.game.ClientboundSwingAnimationPacket.STREAM_CODEC.encode(buf,
        new net.minecraft.network.protocol.game.ClientboundSwingAnimationPacket(0, net.minecraft.world.InteractionHand.MAIN_HAND,
            net.minecraft.world.item.component.SwingAnimation.DEFAULT));
    var bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes);
    out.addProperty("swing_fields", HexFormat.of().formatHex(bytes, 1, bytes.length));
    return out;
  }

  // ---- cases ----

  record Block(int x, int y, int z, BlockState state) {}
  record Spawn(String type, Vec3 position, float yaw, long seed) {}
  record Stand(Vec3 position, String mode, String mainhand, String head) {
    Stand(Vec3 position, String mode, String mainhand) { this(position, mode, mainhand, null); }
  }
  /** An item lying still, its pickup delay over. */
  record Drop(Vec3 position, String item, int count) {}
  /** At tick `tick`, player `player` hits mob `mob` for `amount` (a player attack). */
  record Hit(int tick, int player, int mob, float amount) {}

  static String running(GoalSelector selector) {
    var out = new StringBuilder();
    for (WrappedGoal w : selector.getAvailableGoals()) if (w.isRunning()) out.append(out.length() > 0 ? "," : "").append(goalName(w.getGoal()));
    return out.toString();
  }

  static JsonObject run(Probe level, String name, List<Block> blocks, List<Spawn> spawns, List<Stand> stands, List<Hit> hits, int ticks) throws Exception {
    return run(level, name, blocks, spawns, stands, hits, List.of(), ticks);
  }

  // The brain's behaviours as `priority:activity` while they run.
  @SuppressWarnings("unchecked")
  static JsonArray behaviors(net.minecraft.world.entity.ai.Brain<?> brain) throws Exception {
    var out = new JsonArray();
    var byPriority = (Map<Integer, Map<net.minecraft.world.entity.schedule.Activity, Set<net.minecraft.world.entity.ai.behavior.BehaviorControl<?>>>>)
        field(net.minecraft.world.entity.ai.Brain.class, "availableBehaviorsByPriority").get(brain);
    for (var e : byPriority.entrySet())
      for (var a : e.getValue().entrySet())
        for (var b : a.getValue())
          if (b.getStatus() == net.minecraft.world.entity.ai.behavior.Behavior.Status.RUNNING) out.add(e.getKey() + ":" + a.getKey().getName());
    return out;
  }

  static JsonObject run(Probe level, String name, List<Block> blocks, List<Spawn> spawns, List<Stand> stands, List<Hit> hits, List<Drop> drops, int ticks) throws Exception {
    level.blocks.clear(); level.entities.clear(); level.fighters.clear(); level.sounds.clear(); level.time = 1000L; level.ids = 0;
    var levelRandom = net.minecraft.util.RandomSource.create(7L);
    unsafe.putObject(level, unsafe.objectFieldOffset(net.minecraft.world.level.Level.class.getDeclaredField("random")), levelRandom);
    for (var b : blocks) level.blocks.put(new BlockPos(b.x, b.y, b.z), b.state);
    var fighters = new ArrayList<Fighter>();
    int n = 0;
    for (var s : stands) {
      var f = new Fighter(level, ++n, net.minecraft.world.level.GameType.byName(s.mode));
      f.snapTo(s.position.x, s.position.y, s.position.z, 0, 0);
      if (s.mainhand != null) f.setItemSlot(EquipmentSlot.MAINHAND, new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(s.mainhand))));
      if (s.head != null) f.setItemSlot(EquipmentSlot.HEAD, new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(s.head))));
      fighters.add(f); level.fighters.add(f); level.entities.add(f);
    }
    var mobs = new ArrayList<net.minecraft.world.entity.Mob>();
    var seedField = field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var items = new ArrayList<net.minecraft.world.entity.item.ItemEntity>();
    for (var d : drops) {
      var stack = new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(d.item)), d.count);
      var item = new net.minecraft.world.entity.item.ItemEntity(level, d.position.x, d.position.y, d.position.z, stack, 0, 0, 0);
      item.setPickUpDelay(0);
      items.add(item); level.entities.add(item);
    }
    var gates = new JsonArray(); var sensorTimes = new JsonArray();
    var timeToTick = field(net.minecraft.world.entity.ai.sensing.Sensor.class, "timeToTick");
    var sensorsField = field(net.minecraft.world.entity.ai.Brain.class, "sensors");
    for (var s : spawns) {
      net.minecraft.world.entity.Mob m = mob(s.type, level);
      m.getRandom().setSeed(s.seed);
      if (m instanceof Piglin) {
        // The idle RunOnes' own randoms (`ShufflingList`), seeded from the mob's.
        var byPriority = (Map<?, ?>)field(net.minecraft.world.entity.ai.Brain.class, "availableBehaviorsByPriority").get(m.getBrain());
        var g = new JsonArray();
        long k = 0;
        for (int priority : new int[]{15, 16}) {
          var gate = ((Set<?>)((Map<?, ?>)byPriority.get(priority)).values().iterator().next()).iterator().next();
          var list = field(net.minecraft.world.entity.ai.behavior.GateBehavior.class, "behaviors").get(gate);
          var random = (net.minecraft.util.RandomSource)field(net.minecraft.world.entity.ai.behavior.ShufflingList.class, "random").get(list);
          random.setSeed(s.seed + 101 * ++k);
          g.add(s.seed + 101 * k);
        }
        gates.add(g);
        var times = new JsonArray();
        for (var sensor : ((Map<?, ?>)sensorsField.get(m.getBrain())).values()) times.add(timeToTick.getLong(sensor));
        sensorTimes.add(times);
      } else {
        gates.add(JsonNull.INSTANCE); sensorTimes.add(JsonNull.INSTANCE);
      }
      m.setSilent(false);
      m.snapTo(s.position.x, s.position.y, s.position.z, s.yaw, 0);
      m.setYHeadRot(s.yaw); m.setYBodyRot(s.yaw);
      mobs.add(m); level.entities.add(m);
    }
    var goalSelector = field(net.minecraft.world.entity.Mob.class, "goalSelector");
    var targetSelector = field(net.minecraft.world.entity.Mob.class, "targetSelector");
    var moveControl = net.minecraft.world.entity.ai.control.MoveControl.class;
    var wanted = new Field[]{field(moveControl, "wantedX"), field(moveControl, "wantedY"), field(moveControl, "wantedZ"), field(moveControl, "speedModifier"), field(moveControl, "operation")};
    var ambient = field(net.minecraft.world.entity.Mob.class, "ambientSoundTime");
    var push = LivingEntity.class.getDeclaredMethod("pushEntities"); push.setAccessible(true);
    var noAction = field(LivingEntity.class, "noActionTime");
    var trace = new JsonArray();
    for (int t = 0; t < ticks; t++) {
      level.time++;
      for (var h : hits) if (h.tick == t)
        mobs.get(h.mob).hurtServer(level, level.damageSources().playerAttack(fighters.get(h.player)), h.amount);
      for (var m : mobs) {
        level.current = m;
        m.checkDespawn();
        m.setOldPosAndRot();
        m.tickCount++;
        m.tick();
      }
      level.current = null;
      // The players' own ticks come after the level's (their connections):
      // each pushes the mobs it touches.
      for (var f : fighters) push.invoke(f);
      var row = new JsonArray();
      for (var m : mobs) {
        var r = new JsonObject();
        r.add("position", bits(m.position())); r.add("velocity", bits(m.getDeltaMovement()));
        r.addProperty("on_ground", m.onGround());
        r.addProperty("yaw", Float.floatToRawIntBits(m.getYRot()));
        r.addProperty("head", Float.floatToRawIntBits(m.getYHeadRot()));
        r.addProperty("body", Float.floatToRawIntBits(m.yBodyRot));
        r.addProperty("pitch", Float.floatToRawIntBits(m.getXRot()));
        r.addProperty("seed", ((java.util.concurrent.atomic.AtomicLong)seedField.get(m.getRandom())).get());
        r.addProperty("goals", running((GoalSelector)goalSelector.get(m)));
        r.addProperty("targets", running((GoalSelector)targetSelector.get(m)));
        var target = m.getTarget();
        r.addProperty("target", target == null ? null : target.getUUID().getLeastSignificantBits());
        r.addProperty("aggressive", m.isAggressive());
        r.addProperty("ambient", ambient.getInt(m));
        r.addProperty("level_seed", ((java.util.concurrent.atomic.AtomicLong)seedField.get(levelRandom)).get());
        if (m instanceof Piglin) {
          var brain = m.getBrain();
          r.add("behaviors", behaviors(brain));
          r.addProperty("activity", brain.getActiveNonCoreActivity().map(a -> a.getName()).orElse(null));
          var off = m.getOffhandItem();
          r.addProperty("offhand", off.isEmpty() ? null : BuiltInRegistries.ITEM.getKey(off.getItem()).toString());
          r.addProperty("admiring", brain.hasMemoryValue(net.minecraft.world.entity.ai.memory.MemoryModuleType.ADMIRING_ITEM)
              ? brain.getTimeUntilExpiry(net.minecraft.world.entity.ai.memory.MemoryModuleType.ADMIRING_ITEM) : -1L);
        }
        r.addProperty("no_action", noAction.getInt(m));
        var path = m.getNavigation().getPath();
        if (path == null || path.isDone()) r.add("path", JsonNull.INSTANCE);
        else {
          var p = new JsonArray(); var node = path.getNextNodePos();
          p.add(node.getX()); p.add(node.getY()); p.add(node.getZ()); p.add(bits(m.getNavigation().getPath() == null ? 0 : speed(m.getNavigation())));
          r.add("path", p);
        }
        var mc = m.getMoveControl();
        var w = new JsonArray(); for (int i = 0; i < 4; i++) w.add(bits(wanted[i].getDouble(mc))); w.add(wanted[4].get(mc).toString());
        r.add("move", w);
        var hitsOut = new JsonArray();
        for (var f : fighters) for (var h : f.hits) if (h.get("by").getAsInt() == m.getId()) hitsOut.add(h);
        r.add("hits", hitsOut);
        var sounds = new JsonArray(); level.sounds.getOrDefault(m, List.of()).forEach(sounds::add);
        r.add("sounds", sounds);
        row.add(r);
      }
      for (var f : fighters) f.hits.clear();
      level.sounds.clear();
      trace.add(row);
    }
    var out = new JsonObject(); out.addProperty("name", name);
    var bs = new JsonArray();
    for (var b : blocks) { var a=new JsonArray(); a.add(b.x); a.add(b.y); a.add(b.z); a.add(net.minecraft.world.level.block.Block.getId(b.state)); bs.add(a); }
    out.add("blocks", bs);
    var ms = new JsonArray();
    for (var s : spawns) {
      var o = new JsonObject(); o.addProperty("type", s.type); o.add("position", bits(s.position)); o.addProperty("yaw", Float.floatToRawIntBits(s.yaw));
      o.addProperty("seed", s.seed); o.addProperty("id", mobs.get(ms.size()).getId()); ms.add(o);
    }
    out.add("mobs", ms);
    var ps = new JsonArray();
    int i = 0;
    for (var s : stands) {
      var o = new JsonObject(); o.addProperty("uuid", ++i); o.addProperty("id", fighters.get(i - 1).getId()); o.add("position", bits(s.position)); o.addProperty("mode", s.mode);
      o.addProperty("mainhand", s.mainhand); ps.add(o);
    }
    out.add("players", ps);
    var hs = new JsonArray();
    for (var h : hits) { var o = new JsonObject(); o.addProperty("tick", h.tick); o.addProperty("player", h.player); o.addProperty("mob", h.mob); o.addProperty("amount", Float.floatToRawIntBits(h.amount)); hs.add(o); }
    out.add("hurts", hs);
    var ds = new JsonArray();
    for (var d : drops) { var o = new JsonObject(); o.add("position", bits(d.position)); o.addProperty("item", d.item); o.addProperty("count", d.count); ds.add(o); }
    out.add("items", ds);
    out.add("gates", gates);
    out.add("sensors", sensorTimes);
    out.add("ticks", trace);
    return out;
  }

  static double speed(PathNavigation nav) throws Exception {
    return field(PathNavigation.class, "speedModifier").getDouble(nav);
  }

  static List<Block> floor(int y, int radius, BlockState state) {
    var out = new ArrayList<Block>();
    for (int x = -radius; x <= radius; x++) for (int z = -radius; z <= radius; z++) out.add(new Block(x, y, z, state));
    return out;
  }

  static JsonObject cases(Probe level) throws Exception {
    var stone = Blocks.STONE.defaultBlockState();
    var grass = Blocks.GRASS_BLOCK.defaultBlockState();
    var cases = new JsonArray();
    // A zombie targets a survival player, chases it in a straight line and hits it.
    cases.add(run(level, "zombie_chase", floor(63, 12, stone), List.of(new Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 0, 41L)),
      List.of(new Stand(new Vec3(7.5, 64, 2.5), "survival", null)), List.of(), 240));
    // Behind a wall it cannot see the player: it wanders and looks around.
    var wall = new ArrayList<>(floor(63, 12, stone));
    for (int y = 64; y < 68; y++) for (int z = -12; z <= 12; z++) wall.add(new Block(4, y, z, stone));
    cases.add(run(level, "zombie_wall", wall, List.of(new Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 90, 7L)),
      List.of(new Stand(new Vec3(8.5, 64, .5), "survival", null)), List.of(), 400));
    // A creative player is looked at, never targeted.
    cases.add(run(level, "zombie_creative", floor(63, 12, stone), List.of(new Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 180, 3L)),
      List.of(new Stand(new Vec3(3.5, 64, .5), "creative", null)), List.of(), 400));
    // Hit by the player, a zombie targets it and alerts the other.
    cases.add(run(level, "zombie_alert", floor(63, 12, stone), List.of(new Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 0, 11L),
      new Spawn("minecraft:zombie", new Vec3(-3.5, 64, 4.5), 45, 12L)),
      List.of(new Stand(new Vec3(1.5, 64, -9.5), "survival", null)), List.of(new Hit(3, 0, 0, 1.0F)), 120));
    // A pig wanders over grass and looks at the player now and then.
    cases.add(run(level, "pig_wander", floor(63, 12, grass), List.of(new Spawn("minecraft:pig", new Vec3(.5, 64, .5), 0, 5L)),
      List.of(new Stand(new Vec3(4.5, 64, 4.5), "creative", null)), List.of(), 600));
    // Hit, it panics.
    cases.add(run(level, "pig_panic", floor(63, 12, grass), List.of(new Spawn("minecraft:pig", new Vec3(.5, 64, .5), 0, 9L)),
      List.of(new Stand(new Vec3(1.5, 64, 1.5), "survival", null)), List.of(new Hit(20, 0, 0, 1.0F)), 200));
    // A player holding a carrot tempts it; it stops close by.
    cases.add(run(level, "pig_tempt", floor(63, 12, grass), List.of(new Spawn("minecraft:pig", new Vec3(.5, 64, .5), 0, 13L)),
      List.of(new Stand(new Vec3(6.5, 64, -3.5), "survival", "minecraft:carrot")), List.of(), 200));
    // A piglin idles over stone; one walks to a gold ingot, picks it up and
    // admires it. (A piglin's player sensor reads server players, which the
    // probe cannot make.)
    cases.add(run(level, "piglin_idle", floor(63, 12, stone), List.of(new Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 17L)),
      List.of(), List.of(), List.of(), 400));
    cases.add(run(level, "piglin_admire", floor(63, 12, stone), List.of(new Spawn("minecraft:piglin", new Vec3(.5, 64, .5), 0, 23L)),
      List.of(), List.of(), List.of(new Drop(new Vec3(4.5, 64, 2.5), "minecraft:gold_ingot", 1)), 300));
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    return out;
  }

  // ---- paths (VMC-041b) ----

  static List<Block> box(int x0, int y0, int z0, int x1, int y1, int z1, BlockState state) {
    var out = new ArrayList<Block>();
    for (int x = x0; x <= x1; x++) for (int y = y0; y <= y1; y++) for (int z = z0; z <= z1; z++) out.add(new Block(x, y, z, state));
    return out;
  }

  @SafeVarargs
  static List<Block> scene(List<Block>... parts) {
    var at = new LinkedHashMap<BlockPos, Block>();
    for (var part : parts) for (var b : part) at.put(new BlockPos(b.x, b.y, b.z), b);
    return new ArrayList<>(at.values());
  }

  /**
   * One search as `PathNavigation.createPath(targets, 8, false, reach)` runs
   * it (or with `evaluator` in place of the navigation's): the mob as the
   * evaluator reads it, the limits and region, and the path.
   */
  static JsonObject search(Probe level, String name, List<Block> blocks, String type, Vec3 at, boolean ground,
      BlockPos target, int reach, String kind, net.minecraft.world.level.pathfinder.NodeEvaluator evaluator, long seed) throws Exception {
    level.blocks.clear(); level.entities.clear();
    for (var b : blocks) level.blocks.put(new BlockPos(b.x, b.y, b.z), b.state);
    var entityType = BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(type));
    var m = (net.minecraft.world.entity.Mob)entityType.create(level, EntitySpawnReason.COMMAND);
    m.snapTo(at.x, at.y, at.z, 0, 0);
    m.setOnGround(ground);
    var fluid = Entity.class.getDeclaredMethod("updateFluidInteraction"); fluid.setAccessible(true);
    fluid.invoke(m);
    m.getRandom().setSeed(seed);
    var nav = m.getNavigation();
    var own = (net.minecraft.world.level.pathfinder.NodeEvaluator)field(PathNavigation.class, "nodeEvaluator").get(nav);
    var finder = (PathFinder)field(PathNavigation.class, "pathFinder").get(nav);
    int maxVisited = field(PathFinder.class, "maxVisitedNodes").getInt(finder);
    var lengthMethod = PathNavigation.class.getDeclaredMethod("getMaxPathLength"); lengthMethod.setAccessible(true);
    float length = (float)lengthMethod.invoke(nav);
    var mob = new JsonObject();
    mob.addProperty("type", type); mob.add("position", bits(m.position()));
    mob.addProperty("width", Float.floatToRawIntBits(m.getBbWidth())); mob.addProperty("height", Float.floatToRawIntBits(m.getBbHeight()));
    mob.addProperty("on_ground", m.onGround()); mob.addProperty("in_water", m.isInWater());
    mob.addProperty("step", Float.floatToRawIntBits(m.maxUpStep())); mob.addProperty("max_fall", m.getMaxFallDistance());
    var malus = new JsonArray(); for (var t : PathType.values()) malus.add(Float.floatToRawIntBits(m.getPathfindingMalus(t)));
    mob.add("malus", malus);
    mob.addProperty("can_pass_doors", own.canPassDoors()); mob.addProperty("can_open_doors", own.canOpenDoors());
    mob.addProperty("can_float", own.canFloat()); mob.addProperty("can_walk_over_fences", own.canWalkOverFences());
    var seedField = field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    mob.addProperty("random", ((java.util.concurrent.atomic.AtomicLong)seedField.get(m.getRandom())).get());
    Path path;
    var from = m.blockPosition();
    int radius = (int)(length + 8);
    if (evaluator == null) {
      var create = PathNavigation.class.getDeclaredMethod("createPath", Set.class, int.class, boolean.class, int.class);
      create.setAccessible(true);
      path = (Path)create.invoke(nav, Set.of(target), 8, false, reach);
    } else {
      evaluator.setCanPassDoors(own.canPassDoors()); evaluator.setCanOpenDoors(own.canOpenDoors());
      evaluator.setCanFloat(own.canFloat()); evaluator.setCanWalkOverFences(own.canWalkOverFences());
      var region = new net.minecraft.world.level.PathNavigationRegion(level, from.offset(-radius, -radius, -radius), from.offset(radius, radius, radius));
      path = new PathFinder(evaluator, maxVisited).findPath(region, m, Set.of(target), length, reach, 1.0F);
    }
    var out = new JsonObject(); out.addProperty("name", name); out.addProperty("evaluator", kind);
    var bs = new JsonArray();
    for (var b : blocks) { var a=new JsonArray(); a.add(b.x); a.add(b.y); a.add(b.z); a.add(net.minecraft.world.level.block.Block.getId(b.state)); bs.add(a); }
    out.add("blocks", bs); out.add("mob", mob);
    var t = new JsonArray(); t.add(target.getX()); t.add(target.getY()); t.add(target.getZ()); out.add("target", t);
    out.addProperty("reach", reach); out.addProperty("max_path_length", Float.floatToRawIntBits(length));
    out.addProperty("max_visited", maxVisited);
    var region = new JsonArray(); for (int v : new int[]{from.getX() - radius, from.getY() - radius, from.getZ() - radius, from.getX() + radius, from.getY() + radius, from.getZ() + radius}) region.add(v);
    out.add("region", region);
    out.addProperty("random_after", ((java.util.concurrent.atomic.AtomicLong)seedField.get(m.getRandom())).get());
    if (path == null) out.add("path", JsonNull.INSTANCE);
    else {
      var o = new JsonObject(); var nodes = new JsonArray();
      for (int i = 0; i < path.getNodeCount(); i++) {
        var n = path.getNode(i); var a = new JsonArray(); a.add(n.x); a.add(n.y); a.add(n.z); a.add(n.type.ordinal()); nodes.add(a);
      }
      o.add("nodes", nodes); var pt = new JsonArray(); pt.add(path.getTarget().getX()); pt.add(path.getTarget().getY()); pt.add(path.getTarget().getZ());
      o.add("target", pt); o.addProperty("reached", path.canReach()); out.add("path", o);
    }
    return out;
  }

  static JsonObject paths(Probe level) throws Exception {
    var stone = Blocks.STONE.defaultBlockState();
    var air = Blocks.AIR.defaultBlockState();
    var water = Blocks.WATER.defaultBlockState();
    var floor = box(-12, 63, -12, 12, 63, 12, stone);
    var wall = box(4, 64, -12, 4, 66, 12, stone);
    var gap = box(4, 64, 6, 4, 65, 6, air);
    var door = Blocks.OAK_DOOR.defaultBlockState().setValue(net.minecraft.world.level.block.DoorBlock.FACING, Direction.EAST);
    var doorway = List.of(new Block(4, 64, 0, door),
        new Block(4, 65, 0, door.setValue(net.minecraft.world.level.block.DoorBlock.HALF, net.minecraft.world.level.block.state.properties.DoubleBlockHalf.UPPER)));
    var open = List.of(new Block(4, 64, 0, door.setValue(net.minecraft.world.level.block.DoorBlock.OPEN, true)),
        new Block(4, 65, 0, door.setValue(net.minecraft.world.level.block.DoorBlock.OPEN, true).setValue(net.minecraft.world.level.block.DoorBlock.HALF, net.minecraft.world.level.block.state.properties.DoubleBlockHalf.UPPER)));
    var iron = Blocks.IRON_DOOR.defaultBlockState().setValue(net.minecraft.world.level.block.DoorBlock.FACING, Direction.EAST);
    var ironway = List.of(new Block(4, 64, 0, iron),
        new Block(4, 65, 0, iron.setValue(net.minecraft.world.level.block.DoorBlock.HALF, net.minecraft.world.level.block.state.properties.DoubleBlockHalf.UPPER)));
    var fence = box(4, 64, -12, 4, 64, 12, Blocks.OAK_FENCE.defaultBlockState());
    var gate = List.of(new Block(4, 64, -3, Blocks.OAK_FENCE_GATE.defaultBlockState().setValue(net.minecraft.world.level.block.FenceGateBlock.FACING, Direction.EAST)));
    var openGate = List.of(new Block(4, 64, -3, Blocks.OAK_FENCE_GATE.defaultBlockState()
        .setValue(net.minecraft.world.level.block.FenceGateBlock.FACING, Direction.EAST).setValue(net.minecraft.world.level.block.FenceGateBlock.OPEN, true)));
    var channel = box(3, 61, -12, 5, 63, 12, water);
    var pool = scene(box(-8, 55, -8, 8, 55, 8, stone), box(-8, 56, -8, 8, 62, 8, water), box(-1, 56, -1, 1, 62, 1, stone));
    var start = new Vec3(.5, 64, .5);
    var cases = new JsonArray();
    // Walkers: around a wall, a wall with no way through, doors, fences and gates, water, steps and drops.
    cases.add(search(level, "zombie_wall_gap", scene(floor, wall, gap), "minecraft:zombie", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "zombie_wall_closed", scene(floor, wall), "minecraft:zombie", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "zombie_door", scene(floor, wall, doorway), "minecraft:zombie", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "piglin_door", scene(floor, wall, doorway), "minecraft:piglin", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "piglin_iron_door", scene(floor, wall, ironway), "minecraft:piglin", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "zombie_open_door", scene(floor, wall, open), "minecraft:zombie", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "pig_fence", scene(floor, fence), "minecraft:pig", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "pig_fence_gate", scene(floor, fence, gate), "minecraft:pig", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "pig_open_gate", scene(floor, fence, openGate), "minecraft:pig", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "zombie_channel", scene(floor, channel), "minecraft:zombie", start, true, new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    cases.add(search(level, "zombie_into_water", scene(floor, channel), "minecraft:zombie", start, true, new BlockPos(4, 63, 2), 1, "walk", null, 1L));
    cases.add(search(level, "zombie_steps", scene(floor, box(3, 64, -12, 12, 64, 12, stone), box(6, 65, -12, 12, 65, 12, stone)),
        "minecraft:zombie", start, true, new BlockPos(9, 66, 0), 0, "walk", null, 1L));
    cases.add(search(level, "zombie_drop", scene(floor, box(-3, 64, -3, 3, 66, 3, stone)), "minecraft:zombie", new Vec3(.5, 67, .5), true,
        new BlockPos(8, 64, 0), 0, "walk", null, 1L));
    // Across a chunk, section (8 chunks) and region line, at x 128 and z 0, and on negative coordinates.
    cases.add(search(level, "zombie_section_line", scene(box(116, 63, -12, 140, 63, 12, stone), box(128, 64, -12, 128, 66, 12, stone), box(128, 64, -5, 128, 65, -5, air)),
        "minecraft:zombie", new Vec3(124.5, 64, 3.5), true, new BlockPos(133, 64, 2), 0, "walk", null, 1L));
    cases.add(search(level, "pig_negative", scene(box(-30, 63, -30, -10, 63, -10, stone), box(-17, 64, -30, -17, 65, -12, stone)),
        "minecraft:pig", new Vec3(-20.5, 64, -20.5), true, new BlockPos(-13, 64, -20), 0, "walk", null, 1L));
    // Swimmers: a fish around a pillar; a dolphin may breach the surface.
    cases.add(search(level, "cod_pool", pool, "minecraft:cod", new Vec3(-4.5, 58, .5), false, new BlockPos(5, 59, 0), 0, "swim", null, 1L));
    cases.add(search(level, "dolphin_breach", pool, "minecraft:dolphin", new Vec3(-4.5, 60, .5), false, new BlockPos(5, 63, 0), 0, "swim_breaching", null, 1L));
    cases.add(search(level, "dolphin_surface", pool, "minecraft:dolphin", new Vec3(-4.5, 60, .5), false, new BlockPos(-2, 63, 0), 0, "swim_breaching", null, 1L));
    // A flier over a wall; one starting in leaves draws its start from its random.
    cases.add(search(level, "parrot_fence", scene(floor, fence), "minecraft:parrot", new Vec3(.5, 64, .5), true, new BlockPos(8, 64, 0), 0, "fly", null, 1L));
    cases.add(search(level, "parrot_wall", scene(floor, wall), "minecraft:parrot", new Vec3(.5, 64, .5), true, new BlockPos(8, 64, 0), 0, "fly", null, 1L));
    cases.add(search(level, "parrot_leaves", scene(floor, box(-1, 64, -1, 1, 66, 1, Blocks.OAK_LEAVES.defaultBlockState())),
        "minecraft:parrot", new Vec3(.5, 64.4, .5), false, new BlockPos(6, 65, 3), 0, "fly", null, 99L));
    // Amphibians: from land into the pool and out of it.
    var shore = scene(box(-12, 62, -12, 12, 62, 12, stone), box(-12, 63, -12, -9, 63, 12, stone), box(-8, 63, -8, 8, 63, 8, water));
    cases.add(search(level, "axolotl_into_water", scene(shore, box(-4, 58, -4, 4, 62, 4, water)), "minecraft:axolotl", new Vec3(-10.5, 64, .5), true,
        new BlockPos(2, 60, 1), 0, "amphibious", null, 1L));
    cases.add(search(level, "axolotl_to_pool", scene(shore, box(-4, 58, -4, 4, 62, 4, water)), "minecraft:axolotl", new Vec3(-10.5, 64, .5), true,
        new BlockPos(-6, 63, 0), 0, "amphibious", null, 1L));
    cases.add(search(level, "axolotl_out_of_water", scene(shore, box(-4, 58, -4, 4, 62, 4, water)), "minecraft:axolotl", new Vec3(.5, 59, .5), false,
        new BlockPos(-10, 64, 3), 0, "amphibious", null, 1L));
    cases.add(search(level, "shallow_swimmer", scene(shore, box(-4, 40, -4, 4, 62, 4, water)), "minecraft:axolotl", new Vec3(.5, 45, .5), false,
        new BlockPos(3, 60, 3), 0, "amphibious_shallow", new net.minecraft.world.level.pathfinder.AmphibiousNodeEvaluator(true), 1L));
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    return out;
  }

  /** The probe level every case runs in, its registries and tags bound (also NetherMobOracle's). */
  static Probe setup() throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    unsafe = (sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    var damage = registry(Registries.DAMAGE_TYPE, lookup);
    registries.add(damage);
    for (var key : List.of(Registries.ENCHANTMENT, Registries.PIG_VARIANT, Registries.PIG_SOUND_VARIANT))
      registries.add(registry((ResourceKey)key, lookup));
    BuiltInRegistries.REGISTRY.forEach(r -> registries.add(r));
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      bind(resources, BuiltInRegistries.BLOCK);
      bind(resources, BuiltInRegistries.FLUID);
      bind(resources, BuiltInRegistries.ENTITY_TYPE);
      bind(resources, BuiltInRegistries.ITEM);
      bind(resources, damage);
    }
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = probe(lookup, access, null);
    level.sources = new DamageSources(access);
    return level;
  }

  public static void main(String[] args) throws Exception {
    var level = setup();
    var json = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    if (args[0].equals("facts")) {
      Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().serializeNulls().create().toJson(facts(level)) + "\n");
      System.out.println("PASS: mob AI facts written");
      return;
    }
    if (args[0].equals("cases")) {
      var out = cases(level);
      Files.writeString(java.nio.file.Path.of(args[1]), json.toJson(out));
      System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla mob AI traces (zombie chase, wall, creative, alert; pig wander, panic, tempt; piglin idle, admire).");
      return;
    }
    if (args[0].equals("paths")) {
      var out = paths(level);
      Files.writeString(java.nio.file.Path.of(args[1]), json.toJson(out));
      System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla path searches (walk, swim, fly, amphibious).");
      return;
    }
    throw new IllegalArgumentException("usage: MobAiOracle facts|cases|paths OUT.json");
  }
}
