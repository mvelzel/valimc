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
 *
 * Paths are straight until VMC-041b: the path finder answers one node, the
 * target, and everything after it (`PathNavigation` following, stuck
 * detection, `MoveControl`) is vanilla's.
 */
public class MobAiOracle {
  static sun.misc.Unsafe unsafe;
  static final List<String> MOBS = List.of("minecraft:zombie", "minecraft:pig");

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

  /** No chunks: a path's region reads none (the straight finder needs none). */
  static class NoChunks extends net.minecraft.server.level.ServerChunkCache {
    private NoChunks() { super(null, null, null, null, null, null, 0, 0, false, null); }
    public net.minecraft.world.level.chunk.LevelChunk getChunkNow(int x, int z) { return null; }
    Probe level;
    // A swing (`ClientboundAnimatePacket`) is recorded as the entity's event.
    public void sendToTrackingPlayers(Entity e, net.minecraft.network.protocol.Packet<? super net.minecraft.network.protocol.game.ClientGamePacketListener> packet) {
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
      for (var e : entities) if (e != except && e.getBoundingBox().intersects(box) && test.test(e)) out.add(e);
      return out;
    }
    public <T extends Entity> List<T> getEntitiesOfClass(Class<T> type, AABB box, Predicate<? super T> test) {
      var out = new ArrayList<T>();
      for (var e : entities) if (type.isInstance(e) && e.getBoundingBox().intersects(box) && test.test(type.cast(e))) out.add(type.cast(e));
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

  // Paths are one node, the target: VMC-041b's search replaces this.
  static class StraightFinder extends PathFinder {
    StraightFinder() { super(new net.minecraft.world.level.pathfinder.WalkNodeEvaluator(), 1); }
    public Path findPath(net.minecraft.world.level.PathNavigationRegion region, net.minecraft.world.entity.Mob mob, Set<BlockPos> targets,
        float maxPathLength, int reachRange, float multiplier) {
      var t = targets.iterator().next();
      return new Path(new ArrayList<>(List.of(new Node(t.getX(), t.getY(), t.getZ()))), t, true);
    }
  }

  static class Straight extends GroundPathNavigation {
    Straight(net.minecraft.world.entity.Mob mob, net.minecraft.world.level.Level level) { super(mob, level); }
    protected PathFinder createPathFinder(int maxVisitedNodes) {
      this.nodeEvaluator = new net.minecraft.world.level.pathfinder.WalkNodeEvaluator();
      return new StraightFinder();
    }
    // `GroundPathNavigation.createPath` over the scene (no chunk source).
    public Path createPath(BlockPos pos, int reach) {
      if (level.getBlockState(pos).isAir()) {
        var column = pos.mutable().move(Direction.DOWN);
        while (column.getY() >= level.getMinY() && level.getBlockState(column).isAir()) column.move(Direction.DOWN);
        if (column.getY() >= level.getMinY()) return createPath(Set.of(column.above()), 8, false, reach);
        column.setY(pos.getY() + 1);
        while (column.getY() <= level.getMaxY() && level.getBlockState(column).isAir()) column.move(Direction.UP);
        pos = column.immutable();
      }
      if (level.getBlockState(pos).isSolid()) {
        var column = pos.mutable().move(Direction.UP);
        while (column.getY() <= level.getMaxY() && level.getBlockState(column).isSolid()) column.move(Direction.UP);
        pos = column.immutable();
      }
      return createPath(Set.of(pos), 8, false, reach);
    }
    public Path createPath(Entity target, int reach) { return createPath(target.blockPosition(), reach); }
  }

  static class Zombie extends net.minecraft.world.entity.monster.zombie.Zombie {
    Zombie(Probe level) { super(EntityTypes.ZOMBIE, level); }
    protected PathNavigation createNavigation(net.minecraft.world.level.Level level) { return new Straight(this, level); }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
    protected boolean convertsInWater() { return false; }
  }

  static class Pig extends net.minecraft.world.entity.animal.pig.Pig {
    Pig(Probe level) { super(EntityTypes.PIG, level); }
    protected PathNavigation createNavigation(net.minecraft.world.level.Level level) { return new Straight(this, level); }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
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

  static JsonObject facts(HolderLookup.Provider lookup, Probe level) throws Exception {
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
      net.minecraft.world.entity.Mob mob = name.equals("minecraft:zombie") ? new Zombie(level) : new Pig(level);
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
    for (var m : mobs.entrySet()) {
      var s = m.getValue().getAsJsonObject().get("ambient_sound");
      if (!s.isJsonNull()) sounds.addProperty(s.getAsString(), BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(s.getAsString()))));
    }
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
  record Stand(Vec3 position, String mode, String mainhand) {}
  /** At tick `tick`, player `player` hits mob `mob` for `amount` (a player attack). */
  record Hit(int tick, int player, int mob, float amount) {}

  static String running(GoalSelector selector) {
    var out = new StringBuilder();
    for (WrappedGoal w : selector.getAvailableGoals()) if (w.isRunning()) out.append(out.length() > 0 ? "," : "").append(goalName(w.getGoal()));
    return out.toString();
  }

  static JsonObject run(Probe level, String name, List<Block> blocks, List<Spawn> spawns, List<Stand> stands, List<Hit> hits, int ticks) throws Exception {
    level.blocks.clear(); level.entities.clear(); level.fighters.clear(); level.sounds.clear(); level.time = 1000L; level.ids = 0;
    for (var b : blocks) level.blocks.put(new BlockPos(b.x, b.y, b.z), b.state);
    var fighters = new ArrayList<Fighter>();
    int n = 0;
    for (var s : stands) {
      var f = new Fighter(level, ++n, net.minecraft.world.level.GameType.byName(s.mode));
      f.snapTo(s.position.x, s.position.y, s.position.z, 0, 0);
      if (s.mainhand != null) f.setItemSlot(EquipmentSlot.MAINHAND, new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(s.mainhand))));
      fighters.add(f); level.fighters.add(f); level.entities.add(f);
    }
    var mobs = new ArrayList<net.minecraft.world.entity.Mob>();
    var seedField = field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    for (var s : spawns) {
      net.minecraft.world.entity.Mob m = s.type.equals("minecraft:zombie") ? new Zombie(level) : new Pig(level);
      m.getRandom().setSeed(s.seed);
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
        m.checkDespawn();
        m.setOldPosAndRot();
        m.tickCount++;
        m.tick();
      }
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
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    return out;
  }

  public static void main(String[] args) throws Exception {
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
    var json = new GsonBuilder().disableHtmlEscaping().serializeNulls().create();
    if (args[0].equals("facts")) {
      Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().serializeNulls().create().toJson(facts(lookup, level)) + "\n");
      System.out.println("PASS: mob AI facts written");
      return;
    }
    if (args[0].equals("cases")) {
      var out = cases(level);
      Files.writeString(java.nio.file.Path.of(args[1]), json.toJson(out));
      System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla mob AI traces (zombie chase, wall, creative, alert; pig wander, panic, tempt).");
      return;
    }
    throw new IllegalArgumentException("usage: MobAiOracle facts|cases OUT.json");
  }
}
