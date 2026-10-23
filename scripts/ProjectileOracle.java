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
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.monster.zombie.Zombie;
import net.minecraft.world.entity.projectile.*;
import net.minecraft.world.entity.projectile.arrow.Arrow;
import net.minecraft.world.entity.projectile.hurtingprojectile.*;
import net.minecraft.world.entity.projectile.throwableitemprojectile.*;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.LiquidBlock;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.*;

/**
 * Real vanilla projectile ticks (VMC-037o): `AbstractArrow.tick`,
 * `ThrowableProjectile.tick` (a snowball, a splash potion),
 * `AbstractHurtingProjectile.tick` (small, large and dragon fireballs) and
 * `EyeOfEnder.tick` over a probe level holding a block scene and standing
 * zombies to hit, each tick as `ServerLevel.tickNonPassenger` runs it. Hits
 * are recorded where `onHit` (an arrow's `onHitEntity`, `onHitBlock` and
 * border deflection) receives them; an arrow's block hit then runs as
 * vanilla's, every other hit ends the flight. Sounds, particles and game
 * events are left out.
 * Usage: ProjectileOracle OUT.json
 */
public class ProjectileOracle {
  static sun.misc.Unsafe unsafe;

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers subscribers;
    private Server() { super(null,null,null,null,Optional.empty(),null,null,null,null,null); }
    public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return subscribers; }
  }

  static class Probe extends ServerLevel {
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
    public net.minecraft.world.level.chunk.ChunkAccess getChunk(int x, int z, net.minecraft.world.level.chunk.status.ChunkStatus s, boolean load) {
      if (chunk == null) {
        try {
          chunk = (net.minecraft.world.level.chunk.ChunkAccess)unsafe.allocateInstance(net.minecraft.world.level.chunk.ProtoChunk.class);
          var sections = new net.minecraft.world.level.chunk.LevelChunkSection[24];
          for (int i = 0; i < 24; i++) {
            sections[i] = (net.minecraft.world.level.chunk.LevelChunkSection)unsafe.allocateInstance(net.minecraft.world.level.chunk.LevelChunkSection.class);
            MobTravelOracle.field(net.minecraft.world.level.chunk.LevelChunkSection.class, "fluidCount").setShort(sections[i], (short)1);
            MobTravelOracle.field(net.minecraft.world.level.chunk.LevelChunkSection.class, "tickingFluidCount").setShort(sections[i], (short)1);
          }
          MobTravelOracle.setFinal(net.minecraft.world.level.chunk.ChunkAccess.class, "sections", chunk, sections);
          MobTravelOracle.setFinal(net.minecraft.world.level.chunk.ChunkAccess.class, "levelHeightAccessor", chunk, this);
        } catch (Exception e) { throw new RuntimeException(e); }
      }
      return chunk;
    }
    public int getNextEntityId() { return ++ids; }
    public boolean isLoaded(BlockPos p) { return true; }
    public boolean hasChunk(int x, int z) { return true; }
    public boolean isRainingAt(BlockPos p) { return false; }
    public boolean isPositionEntityTicking(BlockPos p) { return true; }
    public WorldBorder getWorldBorder() { return border; }
    public int getMinY() { return -64; }
    public int getHeight() { return 384; }
    public long getGameTime() { return 0; }
    public GameRules getGameRules() { return rules; }
    public DamageSources damageSources() { return sources; }
    public void gameEvent(Holder<GameEvent> e, Vec3 p, GameEvent.Context c) {}
    public void gameEvent(Entity e, Holder<GameEvent> g, Vec3 p) {}
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
    // An entity gone from the scene is found nowhere (a shulker bullet's lost target).
    public Entity getEntityInAnyDimension(UUID uuid) {
      for (var e : entities) if (!e.isRemoved() && e.getUUID().equals(uuid)) return e;
      return null;
    }
  }

  // A zombie standing still to be hit.
  static class Target extends Zombie {
    Target(Probe level) { super(EntityTypes.ZOMBIE, level); }
    protected net.minecraft.world.entity.ai.navigation.PathNavigation createNavigation(net.minecraft.world.level.Level level) {
      try { return (net.minecraft.world.entity.ai.navigation.PathNavigation)unsafe.allocateInstance(MobTravelOracle.Nav.class); }
      catch (Exception e) { throw new RuntimeException(e); }
    }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
  }

  // Where each kind's hit arrives.
  static List<JsonObject> hits = new ArrayList<>();

  static JsonObject block(BlockHitResult r) {
    var o = new JsonObject(); o.addProperty("kind", "block"); o.add("location", bits(r.getLocation()));
    o.addProperty("face", r.getDirection().get3DDataValue());
    var c = new JsonArray(); c.add(r.getBlockPos().getX()); c.add(r.getBlockPos().getY()); c.add(r.getBlockPos().getZ()); o.add("cell", c);
    o.addProperty("inside", r.isInside()); o.addProperty("border", r.isWorldBorderHit()); return o;
  }

  static JsonObject entity(EntityHitResult r) {
    var o = new JsonObject(); o.addProperty("kind", "entity"); o.add("location", bits(r.getLocation()));
    o.addProperty("id", r.getEntity().getId()); return o;
  }

  static JsonObject recorded(HitResult r) {
    return r instanceof EntityHitResult e ? entity(e) : block((BlockHitResult)r);
  }

  static class TArrow extends Arrow {
    TArrow(Probe l, Vec3 p) { super(l, p.x, p.y, p.z, new ItemStack(Items.ARROW), null); setSilent(true); }
    // The arrow as it stops at the entity, before the tick's drag and gravity.
    protected void onHitEntity(EntityHitResult r) {
      var h = entity(r);
      try { h.add("at", state(this)); } catch (Exception e) { throw new RuntimeException(e); }
      hits.add(h); discard();
    }
    protected void onHitBlock(BlockHitResult r) { hits.add(block(r)); super.onHitBlock(r); }
    public boolean deflect(ProjectileDeflection d, Entity e, EntityReference<Entity> o, boolean a, Vec3 p) {
      var h = new JsonObject(); h.addProperty("kind", "border"); hits.add(h); return super.deflect(d, e, o, a, p);
    }
  }

  static class TSnowball extends Snowball {
    TSnowball(Probe l, Vec3 p) { super(l, p.x, p.y, p.z, new ItemStack(Items.SNOWBALL)); }
    protected void onHit(HitResult r) { hits.add(recorded(r)); discard(); }
  }

  static class TPotion extends ThrownSplashPotion {
    TPotion(Probe l, Vec3 p) { super(l, p.x, p.y, p.z, new ItemStack(Items.SPLASH_POTION)); }
    protected void onHit(HitResult r) { hits.add(recorded(r)); discard(); }
  }

  static class TSmall extends SmallFireball {
    TSmall(Probe l, Vec3 p, Vec3 d) { super(l, p.x, p.y, p.z, d); }
    protected void onHit(HitResult r) { hits.add(recorded(r)); discard(); }
  }

  static class TLarge extends LargeFireball {
    TLarge(Probe l) { super(EntityTypes.FIREBALL, l); }
    protected void onHit(HitResult r) { hits.add(recorded(r)); discard(); }
  }

  static class TDragon extends DragonFireball {
    TDragon(Probe l) { super(EntityTypes.DRAGON_FIREBALL, l); }
    protected void onHit(HitResult r) { hits.add(recorded(r)); discard(); }
  }

  static String bits(double d) { return HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d)); }
  static JsonArray bits(Vec3 v) { var a = new JsonArray(); a.add(bits(v.x)); a.add(bits(v.y)); a.add(bits(v.z)); return a; }

  static JsonObject state(Entity p) throws Exception {
    var o = new JsonObject();
    o.add("position", bits(p.position())); o.add("velocity", bits(p.getDeltaMovement()));
    o.addProperty("yaw", Float.floatToRawIntBits(p.getYRot())); o.addProperty("pitch", Float.floatToRawIntBits(p.getXRot()));
    o.addProperty("in_water", p.isInWater());
    if (p instanceof Arrow) o.addProperty("in_ground", (boolean)inGround.invoke(p));
    if (p instanceof Projectile) o.addProperty("left_owner", leftOwner.getBoolean(p));
    return o;
  }

  static Method inGround; static Field leftOwner;

  record Block(int x, int y, int z, BlockState state) {}

  interface Factory { Entity make(Probe level) throws Exception; }

  /**
   * One flight: `kind` and its parameter as the kernel takes them, the
   * scene, zombies standing at `targets` (the first the owner when `owned`),
   * the projectile `factory` makes, for up to `ticks` ticks.
   */
  static JsonObject run(String name, String kind, double parameter, List<Block> blocks, List<Vec3> targets, boolean owned,
                        double border, Factory factory, int ticks) throws Exception {
    var level = (Probe)unsafe.allocateInstance(Probe.class);
    level.blocks = new HashMap<>(); level.entities = new ArrayList<>();
    level.rules = new GameRules(FeatureFlagSet.of());
    level.sources = (DamageSources)unsafe.allocateInstance(DamageSources.class);
    level.border = new WorldBorder();
    if (border > 0) level.border.setSize(border);
    level.env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    level.server = (Server)unsafe.allocateInstance(Server.class);
    level.server.subscribers = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    for (var b : blocks) level.blocks.put(new BlockPos(b.x, b.y, b.z), b.state);
    var zombies = new ArrayList<Target>();
    for (var t : targets) {
      var z = new Target(level); z.setSilent(true); z.snapTo(t.x, t.y, t.z, 0, 0);
      zombies.add(z); level.entities.add(z);
    }
    var p = factory.make(level);
    p.setSilent(true);
    if (owned && p instanceof Projectile projectile) projectile.setOwner(zombies.get(0));
    // A throwable's first tick scans its box for bubble columns (none here)
    // through loaded chunks the probe does not have.
    if (p instanceof ThrowableProjectile) MobTravelOracle.field(Entity.class, "firstTick").setBoolean(p, false);
    // The draws a tick may take (a border deflection's turn), seeded.
    MobTravelOracle.setFinal(Entity.class, "random", p, RandomSource.create(7L));
    var twin = RandomSource.create(7L);
    var random = new JsonArray(); for (int i = 0; i < 3; i++) random.add(Float.floatToRawIntBits(twin.nextFloat()));
    var out = new JsonObject();
    out.addProperty("name", name); out.addProperty("kind", kind); out.addProperty("parameter", bits(parameter));
    out.addProperty("width", Float.floatToRawIntBits(p.getBbWidth())); out.addProperty("height", Float.floatToRawIntBits(p.getBbHeight()));
    if (p instanceof EyeOfEnder) out.add("target", bits((Vec3)MobTravelOracle.field(EyeOfEnder.class, "target").get(p)));
    var bs = new JsonArray();
    for (var b : blocks) { var a = new JsonArray(); a.add(b.x); a.add(b.y); a.add(b.z); a.add(net.minecraft.world.level.block.Block.getId(b.state)); bs.add(a); }
    out.add("blocks", bs);
    var ts = new JsonArray();
    for (var z : zombies) {
      var o = new JsonObject(); o.addProperty("id", z.getId()); o.add("position", bits(z.position()));
      var b = z.getBoundingBox(); var a = new JsonArray();
      for (double v : new double[]{b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ}) a.add(bits(v));
      o.add("box", a); ts.add(o);
    }
    out.add("targets", ts);
    out.add("owner", owned ? new JsonPrimitive(zombies.get(0).getId()) : JsonNull.INSTANCE);
    if (border > 0) {
      var a = new JsonArray();
      for (double v : new double[]{level.border.getMinX(), level.border.getMinZ(), level.border.getMaxX(), level.border.getMaxZ()}) a.add(bits(v));
      out.add("border", a);
    }
    out.add("random", random);
    out.add("start", state(p));
    var trace = new JsonArray();
    // Until it leaves the scene (a flight past its edge or below it falls on).
    for (int t = 0; t < ticks && !p.isRemoved() && Math.abs(p.getX()) < 14 && Math.abs(p.getZ()) < 14 && p.getY() > 56; t++) {
      hits.clear();
      p.setOldPosAndRot(); p.tickCount++; p.tick();
      var row = state(p);
      var h = new JsonArray(); for (var e : hits) h.add(e); row.add("hits", h);
      row.addProperty("removed", p.isRemoved());
      trace.add(row);
    }
    out.add("ticks", trace);
    return out;
  }

  static List<Block> floor(int y, int radius, BlockState state) {
    var out = new ArrayList<Block>();
    for (int x = -radius; x <= radius; x++) for (int z = -radius; z <= radius; z++) out.add(new Block(x, y, z, state));
    return out;
  }

  static List<Block> scene(String name) {
    var stone = Blocks.STONE.defaultBlockState();
    var out = new ArrayList<>(floor(63, 12, stone));
    switch (name) {
      case "wall" -> { for (int y = 64; y < 72; y++) for (int z = -12; z <= 12; z++) out.add(new Block(8, y, z, stone)); }
      case "slab" -> { for (int z = -12; z <= 12; z++) out.add(new Block(6, 64, z, Blocks.STONE_SLAB.defaultBlockState())); }
      case "pool" -> {
        for (int x = 2; x <= 12; x++) for (int z = -12; z <= 12; z++) {
          out.add(new Block(x, 62, z, stone));
          out.add(new Block(x, 63, z, Blocks.WATER.defaultBlockState()));
          out.add(new Block(x, 64, z, Blocks.WATER.defaultBlockState()));
        }
      }
      // Water flowing east, one level lower per block.
      case "current" -> {
        for (int x = 0; x <= 7; x++) for (int z = -2; z <= 2; z++)
          out.add(new Block(x, 64, z, Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL, x)));
      }
      default -> {}
    }
    return out;
  }

  static Vec3 v(double x, double y, double z) { return new Vec3(x, y, z); }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    net.minecraft.core.registries.BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(net.minecraft.data.registries.VanillaRegistries.createWorldLookup()).forEach(c -> c.apply());
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.BLOCK);
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.FLUID);
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.ENTITY_TYPE);
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.ITEM);
    }
    unsafe = (sun.misc.Unsafe)MobTravelOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    MobTravelOracle.unsafe = unsafe;
    inGround = net.minecraft.world.entity.projectile.arrow.AbstractArrow.class.getDeclaredMethod("isInGround"); inGround.setAccessible(true);
    leftOwner = MobTravelOracle.field(Projectile.class, "leftOwner");
    var cases = new JsonArray();
    var start = v(.5, 65.5, .5);
    // Arrows from a bow's full draw (power 3) and weaker, into the floor, a
    // wall, a slab, water and a current, at a zombie, straight up, and at a
    // world border; the shooter stands at the start (the arrow leaves it).
    var shots = List.of(v(1, 0.1, 0), v(1, -0.3, 0.2), v(0.4, 1, -0.1), v(1, 0.05, 1), v(0, 1, 0), v(-1, -0.6, 0.3));
    for (var scene : List.of("floor", "wall", "slab", "pool", "current"))
      for (var dir : shots)
        for (float power : new float[]{3.0f, 1.2f}) {
          var d = dir; var pw = power;
          cases.add(run("arrow_" + scene, "arrow", 0.05, scene(scene), List.of(v(.5, 64, .5)), true, 0, l -> {
            var a = new TArrow(l, start); a.shoot(d.x, d.y, d.z, pw, 0); return a; }, 140));
        }
    for (var dir : List.of(v(1, 0.02, 0), v(1, 0.1, 0.05), v(1, -0.05, 0)))
      cases.add(run("arrow_zombie", "arrow", 0.05, scene("floor"), List.of(v(.5, 64, .5), v(7.5, 64, .5), v(9.5, 64, .9)), true, 0, l -> {
        var a = new TArrow(l, start); a.shoot(dir.x, dir.y, dir.z, 3.0f, 0); return a; }, 40));
    cases.add(run("arrow_border", "arrow", 0.05, scene("floor"), List.of(v(.5, 64, .5)), true, 16, l -> {
      var a = new TArrow(l, start); a.shoot(1, 0.15, 0.1, 2.0f, 0); return a; }, 60));
    // Thrown items (power 1.5; potions 0.5 with gravity 0.05).
    for (var scene : List.of("floor", "wall", "pool", "current"))
      for (var dir : shots) {
        cases.add(run("snowball_" + scene, "throwable", 0.03, scene(scene), List.of(v(.5, 64, .5)), true, 0, l -> {
          var s = new TSnowball(l, start); s.shoot(dir.x, dir.y, dir.z, 1.5f, 0); return s; }, 120));
        cases.add(run("potion_" + scene, "throwable", 0.05, scene(scene), List.of(v(.5, 64, .5)), true, 0, l -> {
          var s = new TPotion(l, start); s.shoot(dir.x, dir.y, dir.z, 0.5f, 0); return s; }, 120));
      }
    for (var dir : List.of(v(1, 0, 0), v(1, 0.05, 0.02)))
      cases.add(run("snowball_zombie", "throwable", 0.03, scene("floor"), List.of(v(.5, 64, .5), v(6.5, 64, .5)), true, 0, l -> {
        var s = new TSnowball(l, start); s.shoot(dir.x, dir.y, dir.z, 1.5f, 0); return s; }, 40));
    // Fireballs, accelerating along their direction.
    var aims = List.of(v(1, 0, 0), v(1, -0.2, 0.3), v(0.2, -1, 0.1), v(1, 0.4, -0.5));
    for (var scene : List.of("floor", "wall", "pool"))
      for (var dir : aims) {
        cases.add(run("small_fireball_" + scene, "hurting", 0.1, scene(scene), List.of(v(.5, 64, .5)), true, 0,
          l -> new TSmall(l, start, dir), 80));
        cases.add(run("fireball_" + scene, "hurting", 0.1, scene(scene), List.of(v(.5, 64, .5)), true, 0, l -> {
          var f = new TLarge(l); f.setPos(start); f.setDeltaMovement(dir.normalize().scale(0.1)); return f; }, 80));
        cases.add(run("dragon_fireball_" + scene, "hurting", 0.1, scene(scene), List.of(v(.5, 64, .5)), true, 0, l -> {
          var f = new TDragon(l); f.setPos(start); f.setDeltaMovement(dir.normalize().scale(0.1)); return f; }, 80));
      }
    cases.add(run("fireball_zombie", "hurting", 0.1, scene("floor"), List.of(v(-5.5, 64, .5), v(6.5, 64, .5)), true, 0, l -> {
      var f = new TLarge(l); f.setPos(start); f.setDeltaMovement(v(0.1, 0, 0)); return f; }, 60));
    // Eyes of ender toward a near and a far point, over land and water.
    for (var scene : List.of("floor", "pool"))
      for (var target : List.of(v(5, 70, 3), v(200, 30, -80), v(-3, 20, 0.5))) {
        cases.add(run("eye_" + scene, "eye", 0, scene(scene), List.of(), false, 0, l -> {
          var e = new EyeOfEnder(l, start.x, start.y, start.z); e.signalTo(target); return e; }, 80));
      }
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    int ticks = 0; for (var c : cases) ticks += c.getAsJsonObject().getAsJsonArray("ticks").size();
    System.out.println("PASS: " + cases.size() + " vanilla projectile flights, " + ticks + " ticks (arrows, thrown items, fireballs, eyes of ender).");
  }
}
