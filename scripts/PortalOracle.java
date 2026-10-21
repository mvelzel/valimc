import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.BlockUtil;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.EntityDimensions;
import net.minecraft.world.entity.ai.village.poi.*;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.portal.PortalForcer;
import net.minecraft.world.level.portal.PortalShape;
import net.minecraft.world.phys.Vec3;

/**
 * Nether portal parity facts (VMC-026b2), from vanilla's own code over a fake level: portal
 * shapes (`PortalShape.findEmptyPortalShape`, `findAnyShape`), fire placement
 * (`BaseFireBlock.canBePlacedAt`, `getState`), the largest portal rectangle around a block
 * (`BlockUtil.getLargestRectangleAround`), an entity's relative position in a portal
 * (`PortalShape.getRelativePosition`), the closest portal search (`PortalForcer
 * .findClosestPortalPosition` over the POIs of the square) and portal creation
 * (`PortalForcer.createPortal`, every block it sets, in order).
 *
 * Usage: PortalOracle OUT
 */
public class PortalOracle {
  /** A level of explicit blocks (air elsewhere), its bounds, border and portal POIs. */
  static class World extends ServerLevel {
    Map<BlockPos, BlockState> blocks;
    List<long[]> edits;
    int minY, height, logical;
    WorldBorder border;
    ResourceKey<Level> dimension;
    Poi poi;

    protected World() {
      super(null, null, null, null, null, null, false, 0L, List.of(), false);
    }

    public BlockState getBlockState(BlockPos pos) {
      return blocks.getOrDefault(pos, Blocks.AIR.defaultBlockState());
    }

    public boolean setBlock(BlockPos pos, BlockState state, int flags, int limit) {
      edits.add(new long[] {pos.getX(), pos.getY(), pos.getZ(), Block.getId(state)});
      blocks.put(pos.immutable(), state);
      return true;
    }

    public int getMinY() { return minY; }
    public int getHeight() { return height; }
    public int getLogicalHeight() { return logical; }
    public WorldBorder getWorldBorder() { return border; }
    public PoiManager getPoiManager() { return poi; }
    public ResourceKey<Level> dimension() { return dimension; }
    public boolean hasChunk(int x, int z) { return true; }
    public RandomSource getRandom() { return RandomSource.create(0); }

    /** Vanilla's MOTION_BLOCKING heightmap: one above the top state it is opaque for. */
    public int getHeight(Heightmap.Types type, int x, int z) {
      for (int y = minY + height - 1; y >= minY; y--) {
        if (type.isOpaque().test(getBlockState(new BlockPos(x, y, z)))) return y + 1;
      }
      return minY;
    }
  }

  /** POIs of nether portal blocks; `getInSquare` and its filters stay vanilla's. */
  static class Poi extends PoiManager {
    Map<Long, List<PoiRecord>> byChunk;

    protected Poi() {
      super(null, null, null, false, null, null, null);
    }

    public void ensureLoadedAndValid(net.minecraft.world.level.LevelReader reader, BlockPos center, int radius) {}

    public Stream<PoiRecord> getInChunk(java.util.function.Predicate<Holder<PoiType>> predicate, ChunkPos chunk, Occupancy occupancy) {
      return byChunk.getOrDefault(chunk.pack(), List.of()).stream().filter(r -> predicate.test(r.getPoiType()));
    }
  }

  static sun.misc.Unsafe unsafe;
  static Random random = new Random(20261021L);
  // Block constants, set after bootstrap.
  static BlockState AIR, OBSIDIAN;
  static BlockState[] CLUTTER, NEIGHBOURS;

  static World world(int minY, int height, int logical, ResourceKey<Level> dimension) throws Exception {
    var w = (World) unsafe.allocateInstance(World.class);
    w.blocks = new HashMap<>();
    w.edits = new ArrayList<>();
    w.minY = minY;
    w.height = height;
    w.logical = logical;
    w.dimension = dimension;
    w.border = new WorldBorder();
    var poi = (Poi) unsafe.allocateInstance(Poi.class);
    poi.byChunk = new HashMap<>();
    w.poi = poi;
    return w;
  }

  static JsonArray pos(BlockPos p) {
    var a = new JsonArray();
    a.add(p.getX());
    a.add(p.getY());
    a.add(p.getZ());
    return a;
  }

  static JsonArray blocks(World w) {
    var out = new JsonArray();
    w.blocks.entrySet().stream().sorted(Map.Entry.comparingByKey()).forEach(e -> {
      var a = pos(e.getKey());
      a.add(Block.getId(e.getValue()));
      out.add(a);
    });
    return out;
  }

  static String axis(Direction.Axis axis) {
    return axis == Direction.Axis.X ? "x" : "z";
  }

  static Object field(Object target, String name) throws Exception {
    var f = PortalShape.class.getDeclaredField(name);
    f.setAccessible(true);
    return f.get(target);
  }

  static JsonObject shape(PortalShape shape) throws Exception {
    var o = new JsonObject();
    o.addProperty("axis", axis((Direction.Axis) field(shape, "axis")));
    o.add("bottom_left", pos((BlockPos) field(shape, "bottomLeft")));
    o.addProperty("width", (int) field(shape, "width"));
    o.addProperty("height", (int) field(shape, "height"));
    o.addProperty("portal_blocks", (int) field(shape, "numPortalBlocks"));
    o.addProperty("complete", shape.isComplete());
    return o;
  }

  static BlockState portal(Direction.Axis axis) {
    return Blocks.NETHER_PORTAL.defaultBlockState().setValue(NetherPortalBlock.AXIS, axis);
  }

  /** A frame of `frame` blocks around a `w` × `h` opening at `base` along `axis`, with options. */
  static void frame(World world, BlockPos base, Direction.Axis axis, int w, int h, double holes, BlockState inside) {
    Direction right = axis == Direction.Axis.X ? Direction.EAST : Direction.SOUTH;
    for (int i = -1; i <= w; i++) {
      for (int j = -1; j <= h; j++) {
        var p = base.relative(right, i).above(j);
        boolean edge = i == -1 || i == w || j == -1 || j == h;
        boolean corner = (i == -1 || i == w) && (j == -1 || j == h);
        if (edge) {
          if (corner && random.nextBoolean()) continue;
          if (random.nextDouble() < holes) continue;
          world.blocks.put(p, OBSIDIAN);
        } else if (inside != null) {
          world.blocks.put(p, inside);
        }
      }
    }
  }


  static JsonArray shapes() throws Exception {
    var cases = new JsonArray();
    for (int n = 0; n < 600; n++) {
      int minY = n % 3 == 0 ? 0 : -64;
      var world = world(minY, n % 3 == 0 ? 256 : 384, n % 3 == 0 ? 128 : 384, n % 3 == 0 ? Level.NETHER : Level.OVERWORLD);
      var axis = random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z;
      int w = 1 + random.nextInt(23), h = 2 + random.nextInt(23);
      int y = minY + (n % 7 == 0 ? random.nextInt(4) : 10 + random.nextInt(30));
      var base = new BlockPos(random.nextInt(9) - 4, y, random.nextInt(9) - 4);
      double holes = n % 4 == 0 ? 0.05 : 0.0;
      BlockState inside = switch (n % 6) {
        case 1 -> Blocks.FIRE.defaultBlockState();
        case 2 -> portal(axis);
        case 3 -> portal(axis == Direction.Axis.X ? Direction.Axis.Z : Direction.Axis.X);
        default -> null;
      };
      frame(world, base, axis, w, h, holes, inside);
      if (n % 5 == 0) frame(world, base.offset(random.nextInt(5) - 2, random.nextInt(3), random.nextInt(5) - 2),
          axis == Direction.Axis.X ? Direction.Axis.Z : Direction.Axis.X, 1 + random.nextInt(5), 2 + random.nextInt(5), 0.1, null);
      for (int k = random.nextInt(n % 3 == 1 ? 6 : 2); k > 0; k--)
        world.blocks.put(base.offset(random.nextInt(w + 2) - 1, random.nextInt(h + 2) - 1, random.nextInt(3) - 1),
            CLUTTER[random.nextInt(CLUTTER.length)]);
      var queries = new JsonArray();
      Direction right = axis == Direction.Axis.X ? Direction.EAST : Direction.SOUTH;
      for (int q = 0; q < 6; q++) {
        // Half the queries inside the opening, half anywhere around the frame.
        var p = q < 3
            ? base.relative(right, random.nextInt(Math.max(1, w))).above(random.nextInt(Math.max(1, h)))
            : base.offset(random.nextInt(w + 4) - 2, random.nextInt(h + 4) - 2, random.nextInt(3) - 1);
        var preferred = random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z;
        var o = new JsonObject();
        o.add("pos", pos(p));
        o.addProperty("axis", axis(preferred));
        var empty = PortalShape.findEmptyPortalShape(world, p, preferred);
        o.add("empty", empty.isPresent() ? shape(empty.get()) : JsonNull.INSTANCE);
        o.add("any", shape(PortalShape.findAnyShape(world, p, preferred)));
        queries.add(o);
      }
      var c = new JsonObject();
      c.addProperty("min_y", minY);
      c.add("blocks", blocks(world));
      c.add("queries", queries);
      cases.add(c);
    }
    return cases;
  }


  static JsonArray fires() throws Exception {
    var cases = new JsonArray();
    for (int n = 0; n < 600; n++) {
      var dimension = switch (n % 3) { case 0 -> Level.OVERWORLD; case 1 -> Level.NETHER; default -> Level.END; };
      var world = world(dimension == Level.OVERWORLD ? -64 : 0, dimension == Level.OVERWORLD ? 384 : 256, 256, dimension);
      var p = new BlockPos(0, 70, 0);
      if (n % 4 == 0) {
        // A frame around p, so a portal may open there.
        var axis = random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z;
        frame(world, p.relative(axis == Direction.Axis.X ? Direction.WEST : Direction.NORTH, random.nextInt(2)),
            axis, 2 + random.nextInt(3), 3 + random.nextInt(3), n % 8 == 0 ? 0.08 : 0.0, null);
      }
      for (var d : Direction.values()) {
        if (random.nextInt(3) == 0) world.blocks.put(p.relative(d), NEIGHBOURS[random.nextInt(NEIGHBOURS.length)]);
      }
      if (random.nextInt(8) == 0) world.blocks.put(p, NEIGHBOURS[random.nextInt(NEIGHBOURS.length)]);
      var queries = new JsonArray();
      for (var facing : new Direction[] {Direction.NORTH, Direction.EAST, Direction.SOUTH, Direction.WEST}) {
        var o = new JsonObject();
        o.addProperty("facing", facing.getSerializedName());
        o.addProperty("placeable", BaseFireBlock.canBePlacedAt(world, p, facing));
        queries.add(o);
      }
      var c = new JsonObject();
      c.addProperty("dimension", dimension.identifier().toString());
      c.add("pos", pos(p));
      c.add("blocks", blocks(world));
      c.addProperty("state", Block.getId(BaseFireBlock.getState(world, p)));
      c.add("queries", queries);
      cases.add(c);
    }
    return cases;
  }

  static JsonObject rectangle(BlockUtil.FoundRectangle r) {
    var o = new JsonObject();
    o.add("min", pos(r.minCorner));
    o.addProperty("axis1", r.axis1Size);
    o.addProperty("axis2", r.axis2Size);
    return o;
  }

  static JsonArray rectangles() throws Exception {
    var cases = new JsonArray();
    for (int n = 0; n < 300; n++) {
      var world = world(-64, 384, 384, Level.OVERWORLD);
      var axis = random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z;
      var state = portal(axis);
      Direction right = axis == Direction.Axis.X ? Direction.EAST : Direction.SOUTH;
      // A union of rectangles, so the largest one is not the whole set.
      for (int k = 1 + random.nextInt(4); k > 0; k--) {
        int x0 = random.nextInt(12) - 6, y0 = 60 + random.nextInt(12), w = 1 + random.nextInt(8), h = 1 + random.nextInt(8);
        for (int i = 0; i < w; i++) for (int j = 0; j < h; j++) world.blocks.put(BlockPos.ZERO.relative(right, x0 + i).atY(y0 + j), state);
      }
      if (n % 3 == 0) world.blocks.put(BlockPos.ZERO.relative(right, random.nextInt(8) - 4).atY(64 + random.nextInt(6)), portal(
          axis == Direction.Axis.X ? Direction.Axis.Z : Direction.Axis.X));
      var portals = world.blocks.entrySet().stream().filter(e -> e.getValue() == state).map(Map.Entry::getKey).sorted().toList();
      var center = portals.get(random.nextInt(portals.size()));
      var r = BlockUtil.getLargestRectangleAround(center, axis, 21, Direction.Axis.Y, 21, p -> world.getBlockState(p) == state);
      var c = new JsonObject();
      c.add("blocks", blocks(world));
      c.add("center", pos(center));
      c.addProperty("axis", axis(axis));
      c.add("result", rectangle(r));
      cases.add(c);
    }
    return cases;
  }

  static JsonArray relative() {
    var cases = new JsonArray();
    for (int n = 0; n < 300; n++) {
      var axis = random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z;
      var min = new BlockPos(random.nextInt(40) - 20, 60 + random.nextInt(10), random.nextInt(40) - 20);
      var rect = new BlockUtil.FoundRectangle(min, 1 + random.nextInt(21), 1 + random.nextInt(21));
      var dims = EntityDimensions.scalable(0.6F, new float[] {1.8F, 1.5F, 0.6F}[random.nextInt(3)]);
      var at = new Vec3(min.getX() + random.nextDouble() * 25 - 2, min.getY() + random.nextDouble() * 25 - 2,
          min.getZ() + random.nextDouble() * 25 - 2);
      var v = PortalShape.getRelativePosition(rect, axis, at, dims);
      var c = new JsonObject();
      c.add("rect", rectangle(rect));
      c.addProperty("axis", axis(axis));
      var a = new JsonArray();
      a.add(at.x);
      a.add(at.y);
      a.add(at.z);
      c.add("pos", a);
      var d = new JsonArray();
      d.add((double) dims.width());
      d.add((double) dims.height());
      c.add("dims", d);
      var r = new JsonArray();
      r.add(v.x);
      r.add(v.y);
      r.add(v.z);
      c.add("result", r);
      cases.add(c);
    }
    return cases;
  }

  static JsonObject border(WorldBorder border) {
    var o = new JsonObject();
    o.addProperty("center_x", border.getCenterX());
    o.addProperty("center_z", border.getCenterZ());
    o.addProperty("size", border.getSize());
    return o;
  }

  /** Terrain for portal creation: columns of ground, water, lava, plants, trees and cliffs. */
  static void terrain(World world, int kind, int spread) {
    var stone = kind == 1 ? Blocks.NETHERRACK.defaultBlockState() : Blocks.STONE.defaultBlockState();
    int sea = kind == 1 ? 31 : 62;
    int ground = kind == 1 ? 40 + random.nextInt(50) : 55 + random.nextInt(25);
    int amplitude = random.nextInt(12);
    boolean ocean = kind == 2;
    for (int x = -spread; x <= spread; x++) {
      for (int z = -spread; z <= spread; z++) {
        int h = ocean ? sea - 8 : ground + (int) Math.round(amplitude * Math.sin((x + 3 * z) / 9.0) * Math.cos(z / 7.0));
        if (!ocean && random.nextInt(60) == 0) h += 6 + random.nextInt(10);
        int bottom = Math.max(world.minY, h - 12);
        for (int y = bottom; y < h; y++) world.blocks.put(new BlockPos(x, y, z), stone);
        if (kind == 0 && h > sea) world.blocks.put(new BlockPos(x, h - 1, z), Blocks.GRASS_BLOCK.defaultBlockState());
        for (int y = h; y <= sea; y++) world.blocks.put(new BlockPos(x, y, z),
            kind == 1 ? Blocks.LAVA.defaultBlockState() : Blocks.WATER.defaultBlockState());
        if (h > sea) {
          int r = random.nextInt(40);
          if (kind == 0 && r < 6) world.blocks.put(new BlockPos(x, h, z), Blocks.SHORT_GRASS.defaultBlockState());
          else if (kind == 0 && r < 8) world.blocks.put(new BlockPos(x, h, z), Blocks.SNOW.defaultBlockState());
          else if (kind == 0 && r < 9) {
            for (int y = h; y < h + 4; y++) world.blocks.put(new BlockPos(x, y, z), Blocks.OAK_LOG.defaultBlockState());
            world.blocks.put(new BlockPos(x, h + 4, z), Blocks.OAK_LEAVES.defaultBlockState());
          } else if (kind == 1 && r < 3) world.blocks.put(new BlockPos(x, h, z), Blocks.FIRE.defaultBlockState());
          else if (r < 10) world.blocks.put(new BlockPos(x, h, z), Blocks.GLASS.defaultBlockState());
        }
        if (kind == 1) {
          // The Nether's ceiling.
          for (int y = 123; y < 128; y++) world.blocks.put(new BlockPos(x, y, z), y == 127 ? Blocks.BEDROCK.defaultBlockState() : stone);
          if (random.nextInt(25) == 0) for (int y = 110; y < 123; y++) world.blocks.put(new BlockPos(x, y, z), stone);
        }
      }
    }
  }

  static JsonArray create() throws Exception {
    var cases = new JsonArray();
    for (int n = 0; n < 60; n++) {
      int kind = n % 5 == 4 ? 2 : n % 3 == 1 ? 1 : 0;
      boolean nether = kind == 1;
      var world = world(nether ? 0 : -64, nether ? 256 : 384, nether ? 128 : 384, nether ? Level.NETHER : Level.OVERWORLD);
      if (n % 7 == 3) {
        world.border.setCenter(random.nextInt(20) - 10, random.nextInt(20) - 10);
        world.border.setSize(8 + random.nextInt(30));
      }
      terrain(world, kind, 20);
      var origin = new BlockPos(random.nextInt(9) - 4, nether ? 20 + random.nextInt(100) : 40 + random.nextInt(60), random.nextInt(9) - 4);
      origin = world.border.clampToBounds(origin.getX(), origin.getY(), origin.getZ());
      var axis = random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z;
      var c = new JsonObject();
      c.addProperty("min_y", world.minY);
      c.addProperty("height", world.height);
      c.addProperty("logical", world.logical);
      c.add("border", border(world.border));
      c.add("blocks", blocks(world));
      c.add("origin", pos(origin));
      c.addProperty("axis", axis(axis));
      var result = new PortalForcer(world).createPortal(origin, axis);
      c.add("rect", result.isPresent() ? rectangle(result.get()) : JsonNull.INSTANCE);
      var edits = new JsonArray();
      for (var e : world.edits) {
        var a = new JsonArray();
        for (long v : e) a.add(v);
        edits.add(a);
      }
      c.add("edits", edits);
      cases.add(c);
    }
    return cases;
  }

  static JsonArray closest() throws Exception {
    var type = BuiltInRegistries.POINT_OF_INTEREST_TYPE.getOrThrow(PoiTypes.NETHER_PORTAL);
    var cases = new JsonArray();
    for (int n = 0; n < 300; n++) {
      boolean toNether = n % 2 == 0;
      int radius = toNether ? 16 : 128;
      var world = world(-64, 384, 384, toNether ? Level.NETHER : Level.OVERWORLD);
      if (n % 5 == 2) {
        world.border.setCenter(random.nextInt(60) - 30, random.nextInt(60) - 30);
        world.border.setSize(20 + random.nextInt(120));
      }
      var approx = new BlockPos(random.nextInt(200) - 100, 30 + random.nextInt(60), random.nextInt(200) - 100);
      var portals = new JsonArray();
      int count = random.nextInt(n % 4 == 0 ? 3 : 40);
      int span = (radius + 40) * 2;
      for (int k = 0; k < count; k++) {
        var p = approx.offset(random.nextInt(span) - span / 2, random.nextInt(80) - 40, random.nextInt(span) - span / 2);
        if (n % 6 == 1 && k % 3 == 0) p = approx.offset(random.nextInt(5) - 2, random.nextInt(3) - 1, random.nextInt(5) - 2);
        // Some POIs went stale: their block is no longer a portal.
        boolean stale = random.nextInt(10) == 0;
        var state = stale ? OBSIDIAN : portal(random.nextBoolean() ? Direction.Axis.X : Direction.Axis.Z);
        world.blocks.put(p, state);
        world.poi.byChunk.computeIfAbsent(ChunkPos.containing(p).pack(), x -> new ArrayList<>()).add(new PoiRecord(p, type, () -> {}));
        var a = pos(p);
        a.add(Block.getId(state));
        portals.add(a);
      }
      var found = new PortalForcer(world).findClosestPortalPosition(approx, toNether, world.border);
      // Positions as close and as low as the found one: vanilla's POI order picks among them.
      var ties = new JsonArray();
      if (found.isPresent()) {
        var f = found.get();
        world.poi.byChunk.values().stream().flatMap(List::stream).map(PoiRecord::getPos)
            .filter(p -> Math.abs(p.getX() - approx.getX()) <= radius && Math.abs(p.getZ() - approx.getZ()) <= radius)
            .filter(world.border::isWithinBounds)
            .filter(p -> world.getBlockState(p).hasProperty(net.minecraft.world.level.block.state.properties.BlockStateProperties.HORIZONTAL_AXIS))
            .filter(p -> p.distSqr(approx) == f.distSqr(approx) && p.getY() == f.getY())
            .distinct().sorted().forEach(p -> ties.add(pos(p)));
      }
      var c = new JsonObject();
      c.addProperty("to_nether", toNether);
      c.add("border", border(world.border));
      c.add("approx", pos(approx));
      c.add("portals", portals);
      c.add("result", found.isPresent() ? pos(found.get()) : JsonNull.INSTANCE);
      c.add("ties", ties);
      cases.add(c);
    }
    return cases;
  }

  /** End portal frames around 3 × 3 openings, some incomplete, turned or without eyes. */
  static JsonArray frames() throws Exception {
    var cases = new JsonArray();
    Direction[] faces = {Direction.NORTH, Direction.SOUTH, Direction.WEST, Direction.EAST};
    for (int n = 0; n < 300; n++) {
      var world = world(-64, 384, 384, Level.OVERWORLD);
      var interior = new BlockPos(random.nextInt(9) - 4, 30 + random.nextInt(4), random.nextInt(9) - 4);
      // Sides: south faces north, north faces south, east faces west, west faces east.
      var cells = new ArrayList<BlockPos>();
      var facings = new ArrayList<Direction>();
      for (int i = 0; i < 3; i++) {
        cells.add(interior.offset(i, 0, 3)); facings.add(Direction.NORTH);
        cells.add(interior.offset(i, 0, -1)); facings.add(Direction.SOUTH);
        cells.add(interior.offset(3, 0, i)); facings.add(Direction.WEST);
        cells.add(interior.offset(-1, 0, i)); facings.add(Direction.EAST);
      }
      for (int k = 0; k < cells.size(); k++) {
        var facing = n % 5 == 1 && random.nextInt(12) == 0 ? faces[random.nextInt(4)] : facings.get(k);
        boolean eye = !(n % 3 == 2 && random.nextInt(12) == 0);
        if (n % 7 == 4 && random.nextInt(10) == 0) continue;
        world.blocks.put(cells.get(k), Blocks.END_PORTAL_FRAME.defaultBlockState()
            .setValue(EndPortalFrameBlock.FACING, facing).setValue(EndPortalFrameBlock.HAS_EYE, eye));
      }
      if (n % 4 == 0) world.blocks.put(interior.offset(random.nextInt(3), 0, random.nextInt(3)), Blocks.STONE.defaultBlockState());
      if (n % 6 == 0) world.blocks.put(interior.offset(-1, 0, -1), OBSIDIAN);
      var queries = new JsonArray();
      for (int q = 0; q < 4; q++) {
        var p = cells.get(random.nextInt(cells.size()));
        var match = EndPortalFrameBlock.getOrCreatePortalShape().find(world, p);
        var o = new JsonObject();
        o.add("pos", pos(p));
        o.add("interior", match == null ? JsonNull.INSTANCE : pos(match.getFrontTopLeft().offset(-3, 0, -3)));
        queries.add(o);
      }
      var c = new JsonObject();
      c.add("blocks", blocks(world));
      c.add("queries", queries);
      cases.add(c);
    }
    return cases;
  }

  /** The End's arrival platform over varied island terrain (`createEndPlatform`, no drops). */
  static JsonArray platforms() throws Exception {
    var cases = new JsonArray();
    var stone = Blocks.END_STONE.defaultBlockState();
    for (int n = 0; n < 60; n++) {
      var world = world(0, 256, 256, Level.END);
      int ground = 40 + random.nextInt(16);
      for (int x = 95; x <= 105; x++) for (int z = -5; z <= 5; z++) {
        int h = ground + random.nextInt(3);
        for (int y = h - 6; y < h; y++) world.blocks.put(new BlockPos(x, y, z), stone);
        if (random.nextInt(9) == 0) world.blocks.put(new BlockPos(x, h, z), OBSIDIAN);
        if (random.nextInt(15) == 0) world.blocks.put(new BlockPos(x, h, z), Blocks.CAVE_AIR.defaultBlockState());
      }
      var origin = new BlockPos(100, 49, 0);
      var c = new JsonObject();
      c.add("blocks", blocks(world));
      net.minecraft.world.level.levelgen.feature.EndPlatformFeature.createEndPlatform(world, origin, false);
      var edits = new JsonArray();
      for (var e : world.edits) {
        var a = new JsonArray();
        for (long v : e) a.add(v);
        edits.add(a);
      }
      c.add("origin", pos(origin));
      c.add("edits", edits);
      cases.add(c);
    }
    return cases;
  }

  public static void main(String[] args) throws Exception {
    // Block tags (the portal frame, fire, soul fire bases) and fluid tags, as a server binds them.
    MiningToolOracle.initialize();
    SupportOracle.bindFluidTags();
    var f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    unsafe = (sun.misc.Unsafe) f.get(null);
    AIR = Blocks.AIR.defaultBlockState();
    OBSIDIAN = Blocks.OBSIDIAN.defaultBlockState();
    CLUTTER = new BlockState[] {
      Blocks.STONE.defaultBlockState(), Blocks.FIRE.defaultBlockState(), Blocks.SOUL_FIRE.defaultBlockState(),
      Blocks.GLASS.defaultBlockState(), Blocks.CRYING_OBSIDIAN.defaultBlockState(), Blocks.TORCH.defaultBlockState(),
      Blocks.SHORT_GRASS.defaultBlockState(), Blocks.WATER.defaultBlockState(), OBSIDIAN
    };
    NEIGHBOURS = new BlockState[] {
      AIR, AIR, AIR, OBSIDIAN, OBSIDIAN, Blocks.OAK_PLANKS.defaultBlockState(), Blocks.OAK_LEAVES.defaultBlockState(),
      Blocks.STONE.defaultBlockState(), Blocks.SOUL_SAND.defaultBlockState(), Blocks.SOUL_SOIL.defaultBlockState(),
      Blocks.OAK_SLAB.defaultBlockState(), BuiltInRegistries.BLOCK.getValue(net.minecraft.resources.Identifier.withDefaultNamespace("white_wool")).defaultBlockState(), Blocks.GLASS.defaultBlockState(),
      Blocks.NETHERRACK.defaultBlockState(), Blocks.WATER.defaultBlockState(), Blocks.HAY_BLOCK.defaultBlockState(),
      Blocks.OAK_FENCE.defaultBlockState(), Blocks.OAK_STAIRS.defaultBlockState()
    };
    var out = new JsonObject();
    out.addProperty("version", "26.3");
    out.addProperty("data_version", 5023);
    out.add("shapes", shapes());
    out.add("fires", fires());
    out.add("rectangles", rectangles());
    out.add("relative", relative());
    out.add("create", create());
    out.add("closest", closest());
    out.add("frames", frames());
    out.add("platforms", platforms());
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    int edits = 0;
    for (var c : out.getAsJsonArray("create")) edits += c.getAsJsonObject().getAsJsonArray("edits").size();
    System.out.println("PASS: " + out.getAsJsonArray("shapes").size() + " portal frames (6 queries each), "
        + out.getAsJsonArray("fires").size() + " fire placements, " + out.getAsJsonArray("rectangles").size()
        + " portal rectangles, " + out.getAsJsonArray("relative").size() + " relative positions, "
        + out.getAsJsonArray("create").size() + " portal creations (" + edits + " block sets), "
        + out.getAsJsonArray("closest").size() + " portal searches, " + out.getAsJsonArray("frames").size()
        + " end portal frames, " + out.getAsJsonArray("platforms").size() + " End platforms");
  }
}
