import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.particles.ParticleOptions;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.monster.zombie.Zombie;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.*;

/**
 * Whole vanilla zombie ticks (VMC-015i): `Mob.tick` with `MoveControl` driven
 * to a target, over a probe level holding a small block scene. Goals,
 * sounds, particles and game events are left out; fall damage and other
 * hurts are recorded, not applied.
 */
public class MobTravelOracle {
  static sun.misc.Unsafe unsafe;
  static final Gson JSON = new Gson();

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers subscribers;
    private Server() { super(null,null,null,null,Optional.empty(),null,null,null,null,null); }
    public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return subscribers; }
  }

  static class Probe extends ServerLevel {
    // No layers: every environment attribute at its default (monsters do
    // not burn, lava is slow).
    net.minecraft.world.attribute.EnvironmentAttributeSystem env;
    public net.minecraft.world.attribute.EnvironmentAttributeSystem environmentAttributes() { return env; }
    Server server;
    public net.minecraft.server.MinecraftServer getServer() { return server; }
    Map<BlockPos, BlockState> blocks; List<Entity> entities; GameRules rules; DamageSources sources; WorldBorder border;
    private Probe() { super(null,null,null,null,null,null,false,0L,List.of(),false); }
    public BlockState getBlockState(BlockPos p) { return blocks.getOrDefault(p, Blocks.AIR.defaultBlockState()); }
    public FluidState getFluidState(BlockPos p) { return getBlockState(p).getFluidState(); }
    public BlockGetter getChunkForCollisions(int x, int z) { return this; }
    int ids; net.minecraft.world.level.chunk.ChunkAccess chunk;
    // Every section reports fluid: fluid lookups then read the scene.
    public net.minecraft.world.level.chunk.ChunkAccess getChunk(int x, int z, net.minecraft.world.level.chunk.status.ChunkStatus s, boolean load) {
      if (chunk == null) {
        try {
          chunk = (net.minecraft.world.level.chunk.ChunkAccess)unsafe.allocateInstance(net.minecraft.world.level.chunk.ProtoChunk.class);
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
    public int getNextEntityId() { return ++ids; }
    public boolean isLoaded(BlockPos p) { return true; }
    public boolean isRainingAt(BlockPos p) { return false; }
    public boolean isPositionEntityTicking(BlockPos p) { return true; }
    // No light: a monster's idle time ignores brightness.
    public boolean hasChunk(int x, int z) { return false; }
    public WorldBorder getWorldBorder() { return border; }
    public int getMinY() { return -64; }
    public int getHeight() { return 384; }
    public long getGameTime() { return 0; }
    public GameRules getGameRules() { return rules; }
    public DamageSources damageSources() { return sources; }
    public void gameEvent(Holder<GameEvent> e, Vec3 p, GameEvent.Context c) {}
    public void broadcastEntityEvent(Entity e, byte b) {}
    public void broadcastDamageEvent(Entity e, DamageSource s) {}
    public <T extends ParticleOptions> int sendParticles(T o, double x, double y, double z, int n, double a, double b, double c, double s) { return 0; }
    public void playSeededSound(Entity e, double x, double y, double z, Holder<SoundEvent> s, SoundSource c, float v, float p, long seed) {}
    public void playSeededSound(Entity e, Entity t, Holder<SoundEvent> s, SoundSource c, float v, float p, long seed) {}
    public List<Entity> getEntities(Entity except, AABB box, Predicate<? super Entity> test) {
      var out = new ArrayList<Entity>();
      for (var e : entities) if (e != except && e.getBoundingBox().intersects(box) && test.test(e)) out.add(e);
      return out;
    }
  }

  static class Mob extends Zombie {
    final List<JsonObject> events = new ArrayList<>();
    Mob(Probe level) { super(EntityTypes.ZOMBIE, level); }
    protected net.minecraft.world.entity.ai.navigation.PathNavigation createNavigation(net.minecraft.world.level.Level level) {
      try { return (net.minecraft.world.entity.ai.navigation.PathNavigation)unsafe.allocateInstance(Nav.class); }
      catch (Exception e) { throw new RuntimeException(e); }
    }
    protected boolean isSunSensitive() { return false; }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
    protected boolean convertsInWater() { return false; }
    public boolean causeFallDamage(double distance, float multiplier, DamageSource source) {
      var e = new JsonObject(); e.addProperty("kind","fall"); e.addProperty("distance",distance);
      e.addProperty("multiplier",multiplier); e.addProperty("damage",calculateFallDamage(distance,multiplier));
      events.add(e); return false;
    }
    public boolean hurtServer(ServerLevel level, DamageSource source, float amount) {
      var e = new JsonObject(); e.addProperty("kind","hurt"); e.addProperty("amount",amount); events.add(e); return false;
    }
  }

  // No paths: the oracle drives MoveControl directly.
  static class Nav extends net.minecraft.world.entity.ai.navigation.GroundPathNavigation {
    private Nav() { super(null, null); }
    public void tick() {}
    public boolean isDone() { return true; }
    public void stop() {}
  }

  static void setFinal(Class<?> c, String n, Object o, Object v) throws Exception {
    var f = c.getDeclaredField(n); unsafe.putObject(o, unsafe.objectFieldOffset(f), v);
  }
  static Field field(Class<?> c, String n) throws Exception { var f=c.getDeclaredField(n); f.setAccessible(true); return f; }
  static String bits(double d) { return HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d)); }
  static JsonArray bits(Vec3 v) { var a=new JsonArray(); a.add(bits(v.x)); a.add(bits(v.y)); a.add(bits(v.z)); return a; }

  record Block(int x, int y, int z, BlockState state) {}
  record Start(Vec3 position, float yaw, Vec3 target, double speed) {}

  static JsonObject run(String name, List<Block> blocks, List<Start> mobs, int ticks) throws Exception {
    var level = (Probe)unsafe.allocateInstance(Probe.class);
    level.blocks = new HashMap<>(); level.entities = new ArrayList<>();
    level.rules = new GameRules(FeatureFlagSet.of());
    level.sources = (DamageSources)unsafe.allocateInstance(DamageSources.class);
    level.border = new WorldBorder();
    level.env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    level.server = (Server)unsafe.allocateInstance(Server.class);
    level.server.subscribers = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    for (var b : blocks) level.blocks.put(new BlockPos(b.x, b.y, b.z), b.state);
    var bodies = new ArrayList<Mob>();
    for (var s : mobs) {
      var m = new Mob(level);
      ((net.minecraft.world.entity.ai.goal.GoalSelector)field(net.minecraft.world.entity.Mob.class,"goalSelector").get(m)).removeAllGoals(g -> true);
      ((net.minecraft.world.entity.ai.goal.GoalSelector)field(net.minecraft.world.entity.Mob.class,"targetSelector").get(m)).removeAllGoals(g -> true);
      m.setSilent(true);
      m.snapTo(s.position.x, s.position.y, s.position.z, s.yaw, 0);
      m.setYHeadRot(s.yaw); m.setYBodyRot(s.yaw);
      bodies.add(m); level.entities.add(m);
    }
    var trace = new JsonArray();
    for (int t = 0; t < ticks; t++) {
      for (int i = 0; i < bodies.size(); i++) {
        var s = mobs.get(i);
        if (s.target != null) bodies.get(i).getMoveControl().setWantedPosition(s.target.x, s.target.y, s.target.z, s.speed);
      }
      // Every mob ticks, then each is recorded as the next tick finds it
      // (later mobs' pushes included).
      for (var m : bodies) { m.events.clear(); m.tick(); }
      var row = new JsonArray();
      for (var m : bodies) {
        var r = new JsonObject();
        r.add("position", bits(m.position())); r.add("velocity", bits(m.getDeltaMovement()));
        r.addProperty("on_ground", m.onGround()); r.addProperty("fall_distance", bits(m.fallDistance));
        r.addProperty("yaw", Float.floatToRawIntBits(m.getYRot()));
        r.addProperty("horizontal_collision", m.horizontalCollision);
        r.addProperty("air", m.getAirSupply());
        r.addProperty("jumping", field(LivingEntity.class, "jumping").getBoolean(m));
        r.addProperty("no_jump_delay", field(LivingEntity.class, "noJumpDelay").getInt(m));
        var ev = new JsonArray(); for (var e : m.events) ev.add(e); r.add("events", ev);
        row.add(r);
      }
      trace.add(row);
    }
    var out = new JsonObject(); out.addProperty("name", name);
    var bs = new JsonArray();
    for (var b : blocks) { var a=new JsonArray(); a.add(b.x); a.add(b.y); a.add(b.z); a.add(net.minecraft.world.level.block.Block.getId(b.state)); bs.add(a); }
    out.add("blocks", bs);
    var ms = new JsonArray();
    for (var s : mobs) {
      var o = new JsonObject(); o.add("position", bits(s.position)); o.addProperty("yaw", Float.floatToRawIntBits(s.yaw));
      o.add("target", s.target == null ? JsonNull.INSTANCE : bits(s.target)); o.addProperty("speed", s.speed); ms.add(o);
    }
    out.add("mobs", ms); out.add("ticks", trace);
    return out;
  }

  static List<Block> floor(int y, int radius, BlockState state) {
    var out = new ArrayList<Block>();
    for (int x = -radius; x <= radius; x++) for (int z = -radius; z <= radius; z++) out.add(new Block(x, y, z, state));
    return out;
  }

  // The vanilla data pack's tags of `registry`, bound to its built-in holders.
  @SuppressWarnings({"unchecked","rawtypes"})
  static void bind(net.minecraft.server.packs.resources.ResourceManager resources, net.minecraft.core.Registry registry) throws Exception {
    Map<Object, Collection<Object>> tags = (Map)net.minecraft.tags.TagLoader.loadTagsForRegistry(resources, registry.key(), (id, required) -> registry.get((net.minecraft.resources.Identifier)id));
    var memberships = new HashMap<Object, List<Object>>();
    for (var entry : tags.entrySet()) for (var h : entry.getValue()) memberships.computeIfAbsent(h, k -> new ArrayList<>()).add(entry.getKey());
    var bindTags = Holder.Reference.class.getDeclaredMethod("bindTags", Collection.class); bindTags.setAccessible(true);
    for (Object holder : (List)registry.listElements().toList()) bindTags.invoke(holder, memberships.getOrDefault(holder, List.of()));
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      bind(resources, net.minecraft.core.registries.BuiltInRegistries.BLOCK);
      bind(resources, net.minecraft.core.registries.BuiltInRegistries.FLUID);
      bind(resources, net.minecraft.core.registries.BuiltInRegistries.ENTITY_TYPE);
      bind(resources, net.minecraft.core.registries.BuiltInRegistries.ITEM);
    }
    unsafe = (sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var stone = Blocks.STONE.defaultBlockState();
    var cases = new JsonArray();
    // Falls onto stone from heights below and past the safe distance.
    for (double h : new double[]{2.0, 3.5, 6.0, 11.25})
      cases.add(run("fall_" + h, floor(63, 3, stone), List.of(new Start(new Vec3(.5, 64 + h, .5), 0, null, 0)), 40));
    // Walks east across stone, ice, onto a slab, a full block (a jump) and against a wall.
    for (var ground : List.of(stone, Blocks.ICE.defaultBlockState(), Blocks.SOUL_SAND.defaultBlockState()))
      cases.add(run("walk_" + net.minecraft.core.registries.BuiltInRegistries.BLOCK.getKey(ground.getBlock()).getPath(), floor(63, 8, ground),
        List.of(new Start(new Vec3(-4.5, 64, .5), 0, new Vec3(6.5, 64, .5), 1.0)), 60));
    var step = new ArrayList<>(floor(63, 8, stone));
    step.add(new Block(2, 64, 0, Blocks.STONE_SLAB.defaultBlockState()));
    cases.add(run("step_slab", step, List.of(new Start(new Vec3(-2.5, 64, .5), 0, new Vec3(6.5, 64.5, .5), 1.0)), 50));
    var block = new ArrayList<>(floor(63, 8, stone));
    block.add(new Block(2, 64, 0, stone));
    // MoveControl jumps for a target a block up within a block.
    cases.add(run("jump_block", block, List.of(new Start(new Vec3(1.5, 64, .5), 0, new Vec3(2.5, 65, .5), 1.0)), 30));
    var wall = new ArrayList<>(floor(63, 8, stone));
    for (int y = 64; y < 67; y++) for (int z = -2; z <= 2; z++) wall.add(new Block(2, y, z, stone));
    cases.add(run("wall", wall, List.of(new Start(new Vec3(-1.5, 64, .5), 30, new Vec3(6.5, 64, .5), 1.0)), 40));
    // Water: a pool three deep, walked into and across.
    var pool = new ArrayList<>(floor(60, 8, stone));
    for (int x = -8; x <= 8; x++) for (int z = -8; z <= 8; z++) for (int y = 61; y < 64; y++)
      pool.add(new Block(x, y, z, Blocks.WATER.defaultBlockState()));
    cases.add(run("water_sink", pool, List.of(new Start(new Vec3(.5, 66, .5), 0, null, 0)), 80));
    cases.add(run("water_cross", pool, List.of(new Start(new Vec3(-4.5, 63.2, .5), 0, new Vec3(6.5, 64, .5), 1.0)), 80));
    // Lava: a shallow pool walked into.
    var lava = new ArrayList<>(floor(62, 6, stone));
    for (int x = -6; x <= 6; x++) for (int z = -6; z <= 6; z++) lava.add(new Block(x, 63, z, Blocks.LAVA.defaultBlockState()));
    cases.add(run("lava", lava, List.of(new Start(new Vec3(.5, 64.5, .5), 0, new Vec3(4.5, 64, .5), 1.0)), 40));
    // A ladder on a wall, walked against toward a point above.
    var ladder = new ArrayList<>(floor(63, 4, stone));
    for (int y = 64; y < 70; y++) {
      ladder.add(new Block(0, y, 1, stone));
      ladder.add(new Block(0, y, 0, Blocks.LADDER.defaultBlockState()));
    }
    cases.add(run("ladder", ladder, List.of(new Start(new Vec3(.5, 64, -1.5), 0, new Vec3(.5, 70, 1.5), 1.0)), 60));
    // A cobweb in the way.
    var web = new ArrayList<>(floor(63, 6, stone));
    web.add(new Block(1, 64, 0, Blocks.COBWEB.defaultBlockState()));
    cases.add(run("cobweb", web, List.of(new Start(new Vec3(-1.5, 64, .5), 0, new Vec3(5.5, 64, .5), 1.0)), 50));
    // Two zombies overlapping push each other apart.
    cases.add(run("push", floor(63, 4, stone), List.of(new Start(new Vec3(.5, 64, .5), 0, null, 0),
      new Start(new Vec3(.7, 64, .6), 0, null, 0)), 30));
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    Files.writeString(Path.of(args[0]), JSON.toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla zombie traces (fall, walk, step, jump, wall, water, ladder, cobweb, push).");
  }
}
