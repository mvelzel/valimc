import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.projectile.ShulkerBullet;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.phys.*;

/**
 * Shulker bullets (VMC-043e): `ShulkerBullet` made as a shulker makes it
 * (`new ShulkerBullet(level, shulker, target, axis)`, its random seeded),
 * then flown tick by tick over block scenes toward a zombie standing still
 * (one lost mid flight), on the projectile probe of `ProjectileOracle`.
 * Each tick its position, motion, rotation, direction, steps until it
 * turns, target deltas and random seed, and what it hit.
 */
public class ShulkerBulletOracle {
  static java.lang.reflect.Field field(Class<?> c, String n) throws Exception { var f = c.getDeclaredField(n); f.setAccessible(true); return f; }

  /** The chunk a bullet's standing test reads (`loadedAndEntityCanStandOn`): the scene. */
  static class SceneChunk extends net.minecraft.world.level.chunk.ProtoChunk {
    ProjectileOracle.Probe level;
    private SceneChunk() { super(null, null, null, null, null); }
    public net.minecraft.world.level.block.state.BlockState getBlockState(BlockPos p) { return level.getBlockState(p); }
    public net.minecraft.world.level.material.FluidState getFluidState(BlockPos p) { return level.getFluidState(p); }
  }

  // A bullet whose hit is recorded and ends it.
  static class TBullet extends ShulkerBullet {
    TBullet(ProjectileOracle.Probe l) { super(EntityTypes.SHULKER_BULLET, l); }
    protected void onHit(HitResult r) { ProjectileOracle.hits.add(ProjectileOracle.recorded(r)); discard(); }
  }

  static JsonObject state(ShulkerBullet b) throws Exception {
    var o = ProjectileOracle.state(b);
    var dir = (Direction)field(ShulkerBullet.class, "currentMoveDirection").get(b);
    o.addProperty("direction", dir == null ? -1 : dir.get3DDataValue());
    o.addProperty("steps", field(ShulkerBullet.class, "flightSteps").getInt(b));
    var d = new JsonArray();
    for (var n : List.of("targetDeltaX", "targetDeltaY", "targetDeltaZ")) d.add(ProjectileOracle.bits(field(ShulkerBullet.class, n).getDouble(b)));
    o.add("deltas", d);
    o.addProperty("seed", ((java.util.concurrent.atomic.AtomicLong)field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed").get(b.getRandom())).get());
    return o;
  }

  record Block(int x, int y, int z, net.minecraft.world.level.block.state.BlockState state) {}

  /**
   * A bullet from `from` (its shooter's box centre, the shooter holding a
   * face on `axis`) at a zombie at `to`, which is gone from tick `lose` on.
   */
  static JsonObject run(String name, List<Block> blocks, Vec3 from, Direction.Axis axis, Vec3 to, long seed, int lose, int ticks) throws Exception {
    var unsafe = ProjectileOracle.unsafe;
    var level = (ProjectileOracle.Probe)unsafe.allocateInstance(ProjectileOracle.Probe.class);
    level.blocks = new HashMap<>(); level.entities = new ArrayList<>();
    level.rules = new GameRules(FeatureFlagSet.of());
    level.sources = (DamageSources)unsafe.allocateInstance(DamageSources.class);
    level.border = new WorldBorder();
    level.env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    level.server = (ProjectileOracle.Server)unsafe.allocateInstance(ProjectileOracle.Server.class);
    level.server.subscribers = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    for (var b : blocks) level.blocks.put(new BlockPos(b.x, b.y, b.z), b.state);
    var chunk = (SceneChunk)unsafe.allocateInstance(SceneChunk.class); chunk.level = level; level.chunk = chunk;
    // Every section reports fluid, as the probe's own chunk does.
    var sections = new net.minecraft.world.level.chunk.LevelChunkSection[24];
    for (int i = 0; i < 24; i++) {
      sections[i] = (net.minecraft.world.level.chunk.LevelChunkSection)unsafe.allocateInstance(net.minecraft.world.level.chunk.LevelChunkSection.class);
      MobTravelOracle.field(net.minecraft.world.level.chunk.LevelChunkSection.class, "fluidCount").setShort(sections[i], (short)1);
      MobTravelOracle.field(net.minecraft.world.level.chunk.LevelChunkSection.class, "tickingFluidCount").setShort(sections[i], (short)1);
    }
    MobTravelOracle.setFinal(net.minecraft.world.level.chunk.ChunkAccess.class, "sections", chunk, sections);
    MobTravelOracle.setFinal(net.minecraft.world.level.chunk.ChunkAccess.class, "levelHeightAccessor", chunk, level);
    var owner = new ProjectileOracle.Target(level); owner.setSilent(true); owner.snapTo(from.x, from.y - 0.5, from.z, 0, 0);
    var target = new ProjectileOracle.Target(level); target.setSilent(true); target.snapTo(to.x, to.y, to.z, 0, 0);
    level.entities.add(owner); level.entities.add(target);
    // `new ShulkerBullet(level, owner, target, axis)` with a seeded random.
    var b = new TBullet(level);
    MobTravelOracle.setFinal(Entity.class, "random", b, RandomSource.create(seed));
    b.setSilent(true);
    b.setOwner(owner);
    b.snapTo(from.x, from.y, from.z, b.getYRot(), b.getXRot());
    field(ShulkerBullet.class, "finalTarget").set(b, EntityReference.of(target));
    field(ShulkerBullet.class, "currentMoveDirection").set(b, Direction.UP);
    var select = ShulkerBullet.class.getDeclaredMethod("selectNextMoveDirection", Direction.Axis.class, Entity.class);
    select.setAccessible(true);
    select.invoke(b, axis, target);
    var out = new JsonObject();
    out.addProperty("name", name); out.addProperty("seed", seed); out.addProperty("lose", lose);
    out.addProperty("axis", axis.ordinal());
    out.add("from", ProjectileOracle.bits(from));
    var bs = new JsonArray();
    for (var k : blocks) { var a = new JsonArray(); a.add(k.x); a.add(k.y); a.add(k.z); a.add(net.minecraft.world.level.block.Block.getId(k.state)); bs.add(a); }
    out.add("blocks", bs);
    var t = new JsonObject(); t.addProperty("id", target.getId()); t.add("position", ProjectileOracle.bits(target.position()));
    var box = target.getBoundingBox(); var a = new JsonArray();
    for (double v : new double[]{box.minX, box.minY, box.minZ, box.maxX, box.maxY, box.maxZ}) a.add(ProjectileOracle.bits(v));
    t.add("box", a); out.add("target", t);
    out.addProperty("owner", owner.getId());
    var ob = owner.getBoundingBox(); var oa = new JsonArray();
    for (double v : new double[]{ob.minX, ob.minY, ob.minZ, ob.maxX, ob.maxY, ob.maxZ}) oa.add(ProjectileOracle.bits(v));
    out.add("owner_box", oa); out.add("owner_position", ProjectileOracle.bits(owner.position()));
    out.add("start", state(b));
    var trace = new JsonArray();
    for (int i = 0; i < ticks && !b.isRemoved(); i++) {
      if (i == lose) field(Entity.class, "removalReason").set(target, Entity.RemovalReason.DISCARDED);
      ProjectileOracle.hits.clear();
      b.setOldPosAndRot(); b.tickCount++; b.tick();
      var row = state(b);
      var h = new JsonArray(); for (var e : ProjectileOracle.hits) h.add(e); row.add("hits", h);
      row.addProperty("removed", b.isRemoved());
      trace.add(row);
    }
    out.add("ticks", trace);
    return out;
  }

  static List<Block> box(int x0, int y0, int z0, int x1, int y1, int z1) {
    var out = new ArrayList<Block>();
    for (int x = x0; x <= x1; x++) for (int y = y0; y <= y1; y++) for (int z = z0; z <= z1; z++)
      out.add(new Block(x, y, z, Blocks.STONE.defaultBlockState()));
    return out;
  }

  @SafeVarargs
  static List<Block> scene(List<Block>... parts) {
    var out = new ArrayList<Block>(); for (var p : parts) out.addAll(p); return out;
  }

  static Vec3 v(double x, double y, double z) { return new Vec3(x, y, z); }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.BLOCK);
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.FLUID);
      MobTravelOracle.bind(resources, net.minecraft.core.registries.BuiltInRegistries.ENTITY_TYPE);
    }
    ProjectileOracle.unsafe = (sun.misc.Unsafe)MobTravelOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    MobTravelOracle.unsafe = ProjectileOracle.unsafe;
    ProjectileOracle.leftOwner = MobTravelOracle.field(net.minecraft.world.entity.projectile.Projectile.class, "leftOwner");
    var cases = new JsonArray();
    var floor = box(-14, 63, -14, 14, 63, 14);
    var from = v(.5, 64.5, .5);
    for (long seed : new long[]{1L, 2L, 3L}) {
      // Across open ground, far off, onto a ledge above, around a pillar,
      // and a target lost on the way (the bullet falls).
      cases.add(run("bullet_open", floor, from, Direction.Axis.Y, v(6.5, 64, 3.5), seed, -1, 200));
      cases.add(run("bullet_far", floor, v(.5, 64.5, .5), Direction.Axis.X, v(-9.5, 64, 8.5), seed, -1, 300));
      cases.add(run("bullet_ledge", scene(floor, box(3, 64, -6, 6, 67, -2)), from, Direction.Axis.Z, v(4.5, 68, -3.5), seed, -1, 300));
      cases.add(run("bullet_pillar", scene(floor, box(3, 64, -1, 4, 67, 1)), from, Direction.Axis.Y, v(8.5, 64, .5), seed, -1, 300));
      cases.add(run("bullet_lost", floor, from, Direction.Axis.Y, v(7.5, 64, -6.5), seed, 12, 300));
    }
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    int ticks = 0; for (var c : cases) ticks += c.getAsJsonObject().getAsJsonArray("ticks").size();
    System.out.println("PASS: " + cases.size() + " vanilla shulker bullet flights, " + ticks + " ticks.");
  }
}
