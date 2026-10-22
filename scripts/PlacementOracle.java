import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ServerboundUseItemOnPacket;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.util.RandomSource;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.*;
import net.minecraft.world.item.context.BlockPlaceContext;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.CollisionContext;
import net.minecraft.world.ticks.TickPriority;

/**
 * Block placement (VMC-029d): what vanilla's `BlockItem.useOn` does with every block item, as
 * one table per item, and the coverage matrix that checks ValiMC against it.
 *
 * A placement reads the click (the clicked face, the cursor), the player (the nearest looking
 * directions, the horizontal direction, the rotation, the vertical direction, sneaking) and the
 * cells around it. Each of these is an input with a small domain:
 *
 * - `face` (6) and `replace` (2, whether the clicked block itself is replaced, which the
 *   `replacement` rules decide from the clicked state);
 * - `order` (48): `Direction.orderedByNearest(player)`, one of `orders`;
 * - `vertical` (2): `getNearestLookingVerticalDirection` (0 down, 1 up);
 * - `horizontal` (4): `getHorizontalDirection` (2D data value);
 * - `rotation` (20): the yaw's `RotationSegment` and `Direction.fromYRot` together, one of
 *   `rotations` (segment, 2D value);
 * - `cursor` (27): per axis whether the cursor (relative to the clicked block) is below, at or
 *   above 0.5, x major;
 * - `secondary` (2): sneaking;
 * - `light` (16): the target's raw brightness (`getRawBrightness(pos, 0)`, crops and mushrooms);
 * - `sky` (2): whether the target sees the sky (`canSeeSky`, crops);
 * - `signal`, `signal_above` (2 each): whether the target and the cell above it receive redstone
 *   power (`hasNeighborSignal`: doors, trapdoors, fence gates, heads, lamps).
 *
 * The placement runs as `BlockItem.place` does it (`canPlace`, `updatePlacementContext`,
 * `getPlacementState` with obstruction left to ValiMC, `placeBlock`, `setPlacedBy`) in a probe
 * level whose cells are the inputs; its outcome is what it wrote, relative to the target cell (the
 * placed block, the other half of a door or bed, the water a tall plant's top replaces), or a
 * refusal. Randoms it draws (a kelp's age, a pale moss carpet's sides) make an outcome of
 * alternatives, one per drawn sequence. Scaffolding clicked on scaffolding walks along the column
 * to the first free cell (`ScaffoldingBlockItem.updatePlacementContext`): that outcome is `walk`,
 * which ValiMC does in code, as it places a pale moss carpet (`mossy_carpet`: its sides, survival
 * and the topper it draws). Block entity data, sounds and game events are not part of
 * it, nor what `onPlace` does afterwards.
 *
 * Per item a rule: per input the classes of its values, and per class combination a leaf; a leaf
 * is a table like the shape facts' (`ShapeOracle`): the cells it reads (offsets from the target),
 * a partition of all states per cell and per class combination an outcome. Partitions are found as
 * `ShapeOracle` finds them. Connecting blocks (stairs, fences, bars and panes, walls) read their
 * neighbours as air here and leaves read no distance; ValiMC then applies their shape updates and
 * leaf distance (`post` 1 and 2), and this oracle checks that vanilla's placement equals that
 * composition on random neighbourhoods.
 *
 * Output: per item `[item, root, post step, first state of its block, of its wall block or -1]`; an
 * outcome is null (refused), the cells written (`[dx, dy, dz, state]`, or `[dx, dy, dz, k, slot]`
 * for the `k`th state of the item's block (slot 0) or wall block (slot 1), so that items that
 * place alike share their diagram), `walk`, `mossy_carpet`, or `{draws, outcomes}`.
 *
 * `replacement`: per state whether a click on it replaces it (`BlockPlaceContext.replaceClicked`)
 * as a rule over `own` (the held item is the state's block's item, `items` by block id), `face`,
 * `cursor` and `secondary`; every other block item acts as stone does.
 *
 * `operator`: the items only players who may use operator blocks place; `buckets`: the items
 * that leave an empty bucket; `on_water`: the items a click on a block does not place
 * (`PlaceOnWaterBlockItem`), which use places as a click on the cell above the water source the
 * player looks at.
 *
 * Usage: PlacementOracle FACTS.json CASES.json. FACTS: `priv/physics/placement.json`. CASES: the
 * coverage matrix (per block item random clicks from real yaw and pitch over random cells, each
 * with vanilla's outcome, relative to the clicked block) and the use-on packet codec cases. For
 * debugging, `PLACEMENT_ONLY=ITEM,...` tabulates only those items.
 */
public class PlacementOracle {
  static final BlockPos ORIGIN = new BlockPos(0, 64, 0);
  /** Cells stored around the origin, and how far from the target a rule may read. */
  static final int R = 3, W = 2 * R + 1, CELLS = W * W * W, READ = 2;
  static final int MAX_OFFSETS = 14, MAX_TABLE = 1 << 20, MAX_LEAVES = 1 << 17, FULL_CONTEXTS = 64;
  static final String[] VARS = {"order", "vertical", "horizontal", "rotation", "cursor", "secondary", "face", "replace", "light", "sky", "signal",
      "signal_above", "own"};
  static final int ORDER = 0, VERTICAL = 1, HORIZONTAL = 2, ROTATION = 3, CURSOR = 4, SECONDARY = 5, FACE = 6, REPLACE = 7, LIGHT = 8, SKY = 9,
      SIGNAL = 10, SIGNAL_ABOVE = 11, OWN = 12;
  static final int[] DOMAIN = {48, 2, 4, 20, 27, 2, 6, 2, 16, 2, 2, 2, 2};
  static final double[] CURSOR_AT = {0.25, 0.5, 0.75};
  static final int POST_SHAPE = 1, POST_LEAVES = 2;
  static Direction[][] ORDERS = new Direction[48][];
  static float[][] ORDER_VIEWS = new float[48][];
  static int[][] ROTATIONS = new int[20][];
  static float[] ROTATION_YAW = new float[20];
  static BlockState[] STATES;
  static int COUNT;
  static BlockState AIR;
  static RegistryAccess REGISTRIES;
  static final WorldBorder BORDER = new WorldBorder();
  static Method GET_PLACEMENT_STATE, PLACE_BLOCK, UPDATE_DISTANCE;
  static sun.misc.Unsafe UNSAFE;

  static int index(int dx, int dy, int dz) { return ((dx + R) * W + (dy + R)) * W + (dz + R); }
  static int[] offset(int i) { return new int[] {i / (W * W) - R, i / W % W - R, i % W - R}; }
  static int index(BlockPos p) { return index(p.getX() - ORIGIN.getX(), p.getY() - ORIGIN.getY(), p.getZ() - ORIGIN.getZ()); }

  static final class Unsupported extends RuntimeException {
    Unsupported(String reason) { super(reason, null, false, false); }
  }

  static final ThreadLocal<Probe> CURRENT = new ThreadLocal<>();

  /** A server level of cells: the probe's, air elsewhere; writes land in the probe's overlay. */
  static class ProbeLevel extends ServerLevel {
    Probe probe;
    private ProbeLevel() { super(null, null, null, null, null, null, false, 0, null, false); }
    @Override public BlockState getBlockState(BlockPos pos) { return probe.at(pos); }
    @Override public FluidState getFluidState(BlockPos pos) { return probe.at(pos).getFluidState(); }
    @Override public boolean setBlock(BlockPos pos, BlockState state, int flags) { probe.write(pos, state); return true; }
    @Override public boolean setBlock(BlockPos pos, BlockState state, int flags, int recursion) { probe.write(pos, state); return true; }
    @Override public boolean isUnobstructed(BlockState state, BlockPos pos, CollisionContext context) { return true; }
    @Override public RandomSource getRandom() { return probe.random; }
    @Override public WorldBorder getWorldBorder() { return BORDER; }
    @Override public int getMinY() { return -64; }
    @Override public int getHeight() { return 384; }
    @Override public RegistryAccess registryAccess() { return REGISTRIES; }
    @Override public FeatureFlagSet enabledFeatures() { return FeatureFlags.DEFAULT_FLAGS; }
    @Override public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos pos) { return null; }
    @Override public void neighborShapeChanged(Direction d, BlockPos pos, BlockPos neighbour, BlockState state, int flags, int limit) {}
    @Override public void updateNeighborsAt(BlockPos pos, Block block) {}
    @Override public void updateNeighborsAt(BlockPos pos, Block block, net.minecraft.world.level.redstone.Orientation o) {}
    @Override public void scheduleTick(BlockPos pos, Block block, int delay) {}
    @Override public void scheduleTick(BlockPos pos, Block block, int delay, TickPriority priority) {}
    @Override public void scheduleTick(BlockPos pos, Fluid fluid, int delay) {}
    @Override public void scheduleTick(BlockPos pos, Fluid fluid, int delay, TickPriority priority) {}
    @Override public void playSound(Entity except, BlockPos pos, SoundEvent sound, SoundSource source, float volume, float pitch) {}
    @Override public int getRawBrightness(BlockPos pos, int darkening) {
      probe.target(pos);
      if (darkening != 0) throw new Unsupported("darkened brightness");
      probe.read(LIGHT);
      return probe.vars[LIGHT];
    }
    @Override public boolean hasNeighborSignal(BlockPos pos) {
      if (probe.real) return probe.signal(pos);
      if (pos.equals(probe.targetPos())) { probe.read(SIGNAL); return probe.vars[SIGNAL] == 1; }
      if (pos.equals(probe.targetPos().above())) { probe.read(SIGNAL_ABOVE); return probe.vars[SIGNAL_ABOVE] == 1; }
      throw new Unsupported("signal away from the target");
    }
    @Override public List<Entity> getEntities(Entity except, net.minecraft.world.phys.AABB box, java.util.function.Predicate<? super Entity> filter) {
      return List.of();
    }
    @Override public boolean canSeeSky(BlockPos pos) {
      probe.target(pos);
      probe.read(SKY);
      return probe.vars[SKY] == 1;
    }
  }

  /** The placing player: only its view rotations are read (the rest the context answers). */
  static class ProbePlayer extends ServerPlayer {
    private ProbePlayer() { super(null, null, null, null); }
  }

  /**
   * A placement context whose player inputs are the probe's (`real`: the player's own, as a case
   * gives them), recording which inputs a placement reads. The player itself is absent but where
   * its view is read (it has no entity data; obstruction is ValiMC's to check).
   */
  static final class Ctx extends BlockPlaceContext {
    boolean viewing;
    Ctx(Probe p, ItemStack stack, BlockHitResult hit) { super(p.level, null, InteractionHand.MAIN_HAND, stack, hit); }
    static Probe probe() { return CURRENT.get(); }
    void replace(boolean replace) { this.replaceClicked = replace; }
    @Override public Player getPlayer() { return viewing ? probe().player : null; }
    @Override public Direction getHorizontalDirection() {
      var p = probe();
      if (p.real) return p.player.getDirection();
      p.read(HORIZONTAL);
      return Direction.from2DDataValue(p.vars[HORIZONTAL]);
    }
    @Override public float getRotation() {
      var p = probe();
      if (p.real) return p.player.getYRot();
      p.read(ROTATION);
      return ROTATION_YAW[p.vars[ROTATION]];
    }
    @Override public Direction getNearestLookingVerticalDirection() {
      var p = probe();
      if (p.real) return Direction.getFacingAxis(p.player, Direction.Axis.Y);
      p.read(VERTICAL);
      return p.vars[VERTICAL] == 1 ? Direction.UP : Direction.DOWN;
    }
    @Override public Direction getNearestLookingDirection() {
      probe().read(ORDER);
      viewing = true;
      try { return super.getNearestLookingDirection(); } finally { viewing = false; }
    }
    @Override public Direction[] getNearestLookingDirections() {
      probe().read(ORDER);
      viewing = true;
      try { return super.getNearestLookingDirections(); } finally { viewing = false; }
    }
    @Override public boolean isSecondaryUseActive() { var p = probe(); p.read(SECONDARY); return p.vars[SECONDARY] == 1; }
    @Override public Vec3 getClickLocation() { probe().read(CURSOR); return super.getClickLocation(); }
    @Override public Direction getClickedFace() { probe().read(FACE); return super.getClickedFace(); }
    @Override public ItemStack getItemInHand() { probe().read(OWN); return super.getItemInHand(); }
    @Override public boolean isInside() {
      var p = probe();
      if (!p.real) throw new Unsupported("inside");
      return p.inside;
    }
  }

  /** One thread's probe: cells by offset index, the inputs, what a run read and wrote. */
  static final class Probe {
    final BlockState[] cells = new BlockState[CELLS];
    final int[] set = new int[CELLS];
    int setCount;
    // Stamps are longs: a thread runs billions of probes, and an int generation wraps around.
    final long[] stamp = new long[CELLS];
    long generation;
    int trace, readCount, varReads;
    final int[] reads = new int[CELLS];
    final BlockState[] written = new BlockState[CELLS];
    final long[] writeStamp = new long[CELLS];
    final int[] writes = new int[CELLS];
    int writeCount;
    final boolean[] masked = new boolean[CELLS];
    /** The inputs the current rule's search already has. */
    final boolean[] known = new boolean[CELLS];
    int knownVars;
    final int[] vars = new int[VARS.length];
    /** Reads during construction (`quiet`) are not inputs; `real` uses the player's own view. */
    boolean quiet, real;
    /** A real click's `isInside`. */
    boolean inside;
    /** Draws: their bounds as this run made them, and the values the first `fixed` return. */
    final int[] bounds = new int[8], values = new int[8];
    int draws, fixed;
    /** The target cell and how far from it reads may go. */
    int targetX, targetY, targetZ, reach = READ;
    final ProbeLevel level;
    final ProbePlayer player;
    final RandomSource random;

    Probe() throws Exception {
      level = (ProbeLevel) UNSAFE.allocateInstance(ProbeLevel.class);
      level.probe = this;
      player = (ProbePlayer) UNSAFE.allocateInstance(ProbePlayer.class);
      var abilities = Player.class.getDeclaredField("abilities");
      abilities.setAccessible(true);
      abilities.set(player, new Abilities());
      random = (RandomSource) Proxy.newProxyInstance(RandomSource.class.getClassLoader(), new Class<?>[] {RandomSource.class}, (proxy, m, a) -> {
        switch (m.getName()) {
          case "nextInt": if (a != null && a.length == 1) return draw((Integer) a[0]); break;
          case "nextBoolean": return draw(2) == 1;
          case "hashCode": return System.identityHashCode(proxy);
          case "equals": return proxy == a[0];
          default:
        }
        throw new Unsupported("random." + m.getName());
      });
    }

    int draw(int bound) {
      if (draws == bounds.length) throw new Unsupported("draws");
      bounds[draws] = bound;
      int v = draws < fixed ? values[draws] : 0;
      draws++;
      return v;
    }

    void read(int var) { if (!quiet) varReads |= 1 << var; }

    BlockPos targetPos() { return ORIGIN.offset(targetX, targetY, targetZ); }

    /** A real click's redstone power by position: random, and recorded for the case. */
    final Map<BlockPos, Boolean> signals = new LinkedHashMap<>();
    long signalSeed;
    boolean signal(BlockPos pos) {
      return signals.computeIfAbsent(pos.immutable(), q -> new Random(signalSeed ^ q.asLong()).nextInt(3) == 0);
    }

    /** Light inputs are the target's; a read elsewhere is not one. */
    void target(BlockPos p) {
      // A real click's light is its target's, wherever that is.
      if (real) return;
      if (p.getX() - ORIGIN.getX() != targetX || p.getY() - ORIGIN.getY() != targetY || p.getZ() - ORIGIN.getZ() != targetZ)
        throw new Unsupported("light away from the target");
    }

    BlockState at(BlockPos p) {
      int dx = p.getX() - ORIGIN.getX(), dy = p.getY() - ORIGIN.getY(), dz = p.getZ() - ORIGIN.getZ();
      if (Math.abs(dx) > R || Math.abs(dy) > R || Math.abs(dz) > R) throw new Unsupported("far read");
      int i = index(dx, dy, dz);
      if (writeStamp[i] == generation) return written[i];
      if (quiet) { var s = cells[i]; return s == null ? AIR : s; }
      if (Math.abs(dx - targetX) > reach || Math.abs(dy - targetY) > reach || Math.abs(dz - targetZ) > reach) throw new Unsupported("far read");
      if (masked[i]) return AIR;
      if (stamp[i] != generation) { stamp[i] = generation; reads[readCount++] = i; trace = trace * 31 + i; }
      var s = cells[i];
      return s == null ? AIR : s;
    }

    void write(BlockPos p, BlockState s) {
      int i = index(p);
      if (Math.abs(p.getX() - ORIGIN.getX()) > R || Math.abs(p.getY() - ORIGIN.getY()) > R || Math.abs(p.getZ() - ORIGIN.getZ()) > R) throw new Unsupported("far write");
      if (writeStamp[i] != generation) { writeStamp[i] = generation; writes[writeCount++] = i; }
      written[i] = s;
    }

    void clear() { for (int k = 0; k < setCount; k++) cells[set[k]] = null; setCount = 0; }
    void put(int i, BlockState s) { if (cells[i] == null) set[setCount++] = i; cells[i] = s; }
    void begin() { generation++; readCount = 0; trace = 1; varReads = 0; writeCount = 0; draws = 0; }

    /** The context of a click: on `clicked` at its face, the cursor from the inputs or given. */
    Ctx context(Job job, BlockPos clicked, Vec3 cursor) {
      var face = Direction.from3DDataValue(vars[FACE]);
      if (cursor == null) {
        int c = vars[CURSOR];
        cursor = new Vec3(CURSOR_AT[c / 9], CURSOR_AT[c / 3 % 3], CURSOR_AT[c % 3]);
      }
      var hit = new BlockHitResult(new Vec3(clicked.getX() + cursor.x, clicked.getY() + cursor.y, clicked.getZ() + cursor.z), face, clicked, false);
      return new Ctx(this, job.stack, hit);
    }

    /** One run of the placement with the current cells and inputs: its outcome key. */
    String run(Job job) {
      var face = Direction.from3DDataValue(vars[FACE]);
      boolean replace = vars[REPLACE] == 1;
      // The target is the origin; the clicked block is the origin or behind it.
      var clicked = replace ? ORIGIN : ORIGIN.relative(face.getOpposite());
      targetX = targetY = targetZ = 0;
      setView(ORDER_VIEWS[vars[ORDER]]);
      begin();
      quiet = true;
      Ctx context;
      try { context = context(job, clicked, null); } finally { quiet = false; }
      context.replace(replace);
      return place(job, context);
    }

    void setView(float[] view) {
      player.setYRot(view[0]);
      player.setYHeadRot(view[0]);
      player.setXRot(view[1]);
    }

    /** `BlockItem.place` up to `setPlacedBy`, against the probe level. */
    String place(Job job, BlockPlaceContext context) {
      if (!context.canPlace()) return "x";
      // Scaffolding on scaffolding walks along the column (`ScaffoldingBlockItem`), which ValiMC
      // does in code; the walk's end places as a click there does.
      if (!real && job.item instanceof ScaffoldingBlockItem && level.getBlockState(context.getClickedPos()).is(job.item.getBlock())) return "s";
      // A pale moss carpet's sides and the topper it draws read a dozen cells; ValiMC places it with
      // the carpet's code that decoration uses.
      if (!real && job.item.getBlock() instanceof MossyCarpetBlock) return "m";
      var updated = job.item.updatePlacementContext(context);
      if (updated == null) return "x";
      BlockState state = (BlockState) invoke(GET_PLACEMENT_STATE, job.item, updated);
      if (state == null) return "x";
      if (!(Boolean) invoke(PLACE_BLOCK, job.item, updated, state)) return "x";
      var pos = updated.getClickedPos();
      var placed = level.getBlockState(pos);
      if (placed.is(state.getBlock()) && job.placedBy) placed.getBlock().setPlacedBy(level, pos, placed, null, updated.getItemInHand());
      int[] order = Arrays.copyOf(writes, writeCount);
      Arrays.sort(order);
      var key = new StringBuilder("w");
      for (int i : order) {
        int[] o = offset(i);
        key.append(o[0] - targetX).append(',').append(o[1] - targetY).append(',').append(o[2] - targetZ).append(',').append(Block.getId(written[i])).append(';');
      }
      return key.toString();
    }

    /** The outcome of the current cells and inputs, with every sequence of draws. */
    int outcome(Job job) {
      fixed = 0;
      var first = run(job);
      if (draws == 0) return outcomeId(first);
      int n = draws;
      int[] radix = Arrays.copyOf(bounds, n);
      long product = 1;
      for (int b : radix) product *= b;
      if (product > 256) throw new Unsupported("draws");
      int trace0 = trace;
      var keys = new ArrayList<String>();
      int[] choice = new int[n];
      do {
        System.arraycopy(choice, 0, values, 0, n);
        fixed = n;
        var key = run(job);
        if (draws != n || !Arrays.equals(Arrays.copyOf(bounds, n), radix) || trace != trace0) throw new Unsupported("random reads");
        keys.add(key);
      } while (SupportOracle.next(choice, radix));
      fixed = 0;
      if (new HashSet<>(keys).size() == 1) return outcomeId(keys.get(0));
      return outcomeId("r" + Arrays.toString(radix) + "|" + String.join("|", keys));
    }
  }

  static Object invoke(Method m, Object target, Object... args) {
    try {
      return m.invoke(target, args);
    } catch (InvocationTargetException e) {
      if (e.getCause() instanceof RuntimeException r) throw r;
      throw new RuntimeException(e.getCause());
    } catch (IllegalAccessException e) {
      throw new RuntimeException(e);
    }
  }

  record Job(BlockItem item, ItemStack stack, int post, boolean placedBy) {}

  // Outcomes by key: "x" a refusal, "w" writes "dx,dy,dz,state;", "r[bounds]|key|key..." random.
  static final ConcurrentHashMap<String, Integer> OUTCOMES = new ConcurrentHashMap<>();
  static final ConcurrentHashMap<Integer, String> OUTCOME_KEYS = new ConcurrentHashMap<>();
  static final AtomicInteger NEXT = new AtomicInteger();

  static int outcomeId(String key) {
    Integer id = OUTCOMES.get(key);
    if (id != null) return id;
    return OUTCOMES.computeIfAbsent(key, k -> { int n = NEXT.getAndIncrement(); OUTCOME_KEYS.put(n, k); return n; });
  }

  /** An input of a rule: a variable (`var` ≥ 0) or a cell (its offset, representatives, partition). */
  static final class Dim {
    final int var, offset;
    List<BlockState> reps;
    int[] classes;
    Dim(int var, int offset, List<BlockState> reps) { this.var = var; this.offset = offset; this.reps = reps; }
    int size() { return var >= 0 ? DOMAIN[var] : reps.size(); }
  }

  /** A leaf: the cells it reads (dims), their partitions and per combination an outcome. */
  record Leaf(int[] offsets, int[][] classes, int[] table, String key) {
    Leaf(int[] offsets, int[][] classes, int[] table) { this(offsets, classes, table, key(offsets, classes, table)); }
    static String key(int[] offsets, int[][] classes, int[] table) {
      var b = new StringBuilder();
      for (int i = 0; i < offsets.length; i++) b.append(offsets[i]).append(':').append(classId(classes[i])).append(',');
      return b.append(Arrays.toString(table)).toString();
    }
  }

  /** Interned partitions by identity (`SupportOracle.intern`), numbered for leaf keys. */
  static final IdentityHashMap<int[], Integer> CLASS_IDS = new IdentityHashMap<>();
  static synchronized int classId(int[] classes) { return CLASS_IDS.computeIfAbsent(classes, c -> CLASS_IDS.size()); }

  /** An item's rule: its variables with the classes of their values and a leaf per combination. */
  record Rule(int[] vars, int[][] classes, Leaf[] leaves) {}

  static void place(Probe p, List<Dim> dims, int[] choice) {
    p.clear();
    Arrays.fill(p.vars, 0);
    // Inputs found after the choice was made take their first value.
    for (int i = 0; i < dims.size(); i++) {
      var d = dims.get(i);
      int c = i < choice.length ? choice[i] : 0;
      if (d.var >= 0) p.vars[d.var] = c;
      else p.put(d.offset, d.reps.get(c));
    }
  }

  /** New inputs the last run read: variables and cells. */
  static boolean absorb(Probe p, List<Dim> dims, List<BlockState> seeds) {
    if ((p.varReads & ~p.knownVars & ~(1 << OWN)) == 0) {
      boolean known = true;
      for (int k = 0; k < p.readCount && known; k++) known = p.known[p.reads[k]];
      if (known) return false;
    }
    boolean grown = false;
    for (int v = 0; v < VARS.length; v++) {
      if ((p.varReads & 1 << v) == 0 || v == OWN) continue;
      final int var = v;
      if (dims.stream().noneMatch(d -> d.var == var)) { dims.add(new Dim(v, -1, null)); grown = true; }
      p.knownVars |= 1 << v;
    }
    for (int k = 0; k < p.readCount; k++) {
      int i = p.reads[k];
      if (dims.stream().noneMatch(d -> d.var < 0 && d.offset == i)) { dims.add(new Dim(-1, i, seeds)); grown = true; }
      p.known[i] = true;
    }
    if (dims.stream().filter(d -> d.var < 0).count() > MAX_OFFSETS) throw new Unsupported("offsets");
    return grown;
  }

  static int[] radix(List<Dim> dims) { return dims.stream().mapToInt(Dim::size).toArray(); }

  static List<int[]> contexts(int[] radix, int skip, int[] alive) {
    long product = 1;
    int[] r = radix.clone();
    r[skip] = 1;
    for (int x : r) product *= x;
    var out = new LinkedHashMap<List<Integer>, int[]>();
    if (product <= FULL_CONTEXTS) {
      int[] choice = new int[r.length];
      do out.putIfAbsent(Arrays.stream(choice).boxed().toList(), choice.clone()); while (SupportOracle.next(choice, r));
    } else {
      around(out, new int[r.length], r);
      if (alive != null) { int[] base = alive.clone(); base[skip] = 0; around(out, base, r); }
    }
    return new ArrayList<>(out.values());
  }

  static void around(Map<List<Integer>, int[]> out, int[] base, int[] radix) {
    out.putIfAbsent(Arrays.stream(base).boxed().toList(), base.clone());
    for (int i = 0; i < radix.length; i++) for (int c = 0; c < radix[i]; c++) if (c != base[i]) {
      int[] choice = base.clone();
      choice[i] = c;
      out.putIfAbsent(Arrays.stream(choice).boxed().toList(), choice);
    }
  }

  /** A combination of inputs whose outcome differs from the base's, if any. */
  static int[] interesting(Probe p, Job job, List<Dim> dims, int base, Random random) {
    int[] radix = radix(dims);
    long product = 1;
    for (int x : radix) product *= x;
    int[] choice = new int[radix.length];
    if (product <= 4096) {
      do { place(p, dims, choice); if (p.outcome(job) != base) return choice; } while (SupportOracle.next(choice, radix));
      return null;
    }
    for (int k = 0; k < 4096; k++) {
      for (int i = 0; i < radix.length; i++) choice[i] = random.nextInt(radix[i]);
      place(p, dims, choice);
      if (p.outcome(job) != base) return choice;
    }
    return null;
  }

  static List<BlockState> seeds(BlockItem item) {
    var seeds = new ArrayList<>(List.of(AIR, Blocks.STONE.defaultBlockState(), Blocks.WATER.defaultBlockState(), Blocks.LAVA.defaultBlockState(),
        Blocks.GRASS_BLOCK.defaultBlockState(), Blocks.SAND.defaultBlockState(), Blocks.OAK_LOG.defaultBlockState(), Blocks.OAK_LEAVES.defaultBlockState(),
        Blocks.SNOW.defaultBlockState(), Blocks.SHORT_GRASS.defaultBlockState(), Blocks.OAK_SLAB.defaultBlockState(), Blocks.OAK_FENCE.defaultBlockState(),
        Blocks.FARMLAND.defaultBlockState()));
    var own = item.getBlock().getStateDefinition().getPossibleStates();
    for (int k = 0; k < own.size(); k += Math.max(1, own.size() / 4)) seeds.add(own.get(k));
    return List.copyOf(seeds);
  }

  /** The rule of `job`'s item: inputs and partitions as `ShapeOracle` finds them, then the leaves. */
  static Rule rule(Probe p, Job job) {
    var seeds = seeds(job.item);
    var dims = new ArrayList<Dim>(List.of(new Dim(FACE, -1, null), new Dim(REPLACE, -1, null)));
    var random = new Random(BuiltInRegistries.ITEM.getId(job.item));
    mask(p, job);
    Arrays.fill(p.known, false);
    p.knownVars = 1 << FACE | 1 << REPLACE;
    // Inputs any click reads, from the empty neighbourhood and random ones.
    for (boolean grown = true; grown; ) {
      grown = false;
      int[] radix = radix(dims);
      int[] choice = new int[radix.length];
      for (int k = 0; k < 256; k++) {
        for (int i = 0; i < radix.length; i++) choice[i] = k < 12 && dims.get(i).var < 0 ? 0 : random.nextInt(radix[i]);
        if (k < 12) { choice[0] = k % 6; choice[1] = k / 6; }
        place(p, dims, choice);
        p.outcome(job);
        if (absorb(p, dims, seeds)) { grown = true; break; }
      }
    }
    Arrays.fill(p.vars, 0);
    p.clear();
    int base = p.outcome(job);
    var dirty = new ArrayDeque<Integer>();
    for (int i = 0; i < dims.size(); i++) if (dims.get(i).var < 0) dirty.add(i);
    // Counterexamples (random clicks whose outcome the partitions got wrong): contexts every cell's
    // refinement also scans, as actual states and values per dim.
    var extra = new ArrayList<Setting>();
    long probes = 0;
    for (int verified = 0; ; verified++) {
      probes += refine(p, job, dims, dirty, extra, base, random, seeds, probes);
      int wrong = verify(p, job, dims, random, extra, seeds);
      if (System.getenv("PLACEMENT_DEBUG") != null)
        System.err.println(job.item + " verify " + verified + ": " + (wrong >= 0 ? Arrays.toString(offset(dims.get(wrong).offset)) : wrong) + " extra " + extra.size());
      if (wrong == -1) break;
      if (verified >= 40) throw new Unsupported("unverified partitions");
      // A new dim (read only by the counterexample) or the cell that got its class wrong.
      for (int i = 0; i < dims.size(); i++) if (dims.get(i).var < 0 && !dirty.contains(i) && (wrong == -2 || i == wrong)) dirty.add(i);
    }
    for (var d : dims) if (d.var < 0 && d.classes == null) throw new Unsupported("unrefined cell");
    if (System.getenv("PLACEMENT_DEBUG") != null) {
      var b = new StringBuilder(job.item + ":");
      for (var d : dims) {
        if (d.var >= 0) { b.append(' ').append(VARS[d.var]); continue; }
        b.append(' ').append(Arrays.toString(offset(d.offset))).append('=').append(d.reps.size())
            .append(d.classes[Block.getId(AIR)] == d.classes[Block.getId(Blocks.STONE.defaultBlockState())] ? "(stone~air)" : "");
      }
      System.err.println(b);
    }
    return leaves(p, job, dims);
  }

  /** A context as states and values per dim (null states take the dim's first representative). */
  record Setting(int[] values, BlockState[] states) {}

  static void place(Probe p, List<Dim> dims, Setting s) {
    p.clear();
    Arrays.fill(p.vars, 0);
    for (int i = 0; i < dims.size(); i++) {
      var d = dims.get(i);
      if (d.var >= 0) p.vars[d.var] = i < s.values.length ? s.values[i] : 0;
      else p.put(d.offset, i < s.states.length && s.states[i] != null ? s.states[i] : d.reps.get(0));
    }
  }

  static Setting setting(List<Dim> dims, int[] choice) {
    var states = new BlockState[dims.size()];
    int[] values = new int[dims.size()];
    for (int i = 0; i < dims.size(); i++) {
      int c = i < choice.length ? choice[i] : 0;
      if (dims.get(i).var >= 0) values[i] = c;
      else states[i] = dims.get(i).reps.get(c);
    }
    return new Setting(values, states);
  }

  /**
   * Random clicks with actual states against the same clicks with each cell's class representative:
   * -1 when all agree, -2 when one read a new input (now a dim), else the cell whose class was wrong,
   * with the click added to `extra`.
   */
  static int verify(Probe p, Job job, List<Dim> dims, Random random, List<Setting> extra, List<BlockState> seeds) {
    var own = job.item.getBlock().getStateDefinition().getPossibleStates();
    // Counterexamples can need several inputs at once (a door's hinge cells matter on a solid floor
    // with a free cell above, facing along them, with a balanced score): many cheap clicks.
    for (int k = 0; k < 30000; k++) {
      int n = dims.size();
      int[] values = new int[n];
      var actual = new BlockState[n];
      var reps = new BlockState[n];
      for (int i = 0; i < n; i++) {
        var d = dims.get(i);
        if (d.var >= 0) { values[i] = random.nextInt(DOMAIN[d.var]); continue; }
        int r = random.nextInt(10);
        actual[i] = r < 3 ? STATES[random.nextInt(COUNT)] : r < 5 ? own.get(random.nextInt(own.size())) : d.reps.get(random.nextInt(d.reps.size()));
        reps[i] = d.reps.get(d.classes[Block.getId(actual[i])]);
      }
      var real = new Setting(values, actual);
      place(p, dims, real);
      int outcome = p.outcome(job);
      if (absorb(p, dims, seeds)) { extra.add(real); return -2; }
      place(p, dims, new Setting(values, reps));
      if (p.outcome(job) == outcome) continue;
      for (int i = 0; i < n; i++) {
        if (dims.get(i).var >= 0) continue;
        var one = actual.clone();
        one[i] = reps[i];
        place(p, dims, new Setting(values, one));
        if (p.outcome(job) != outcome) { extra.add(real); return i; }
      }
      // Only several cells together: refine them all.
      extra.add(real);
      return -2;
    }
    return -1;
  }

  /** `ShapeOracle`'s refinement of the dirty cells' partitions; returns the probes it took. */
  static long refine(Probe p, Job job, List<Dim> dims, ArrayDeque<Integer> dirty, List<Setting> extra, int base, Random random,
      List<BlockState> seeds, long spent) {
    int rounds = 0;
    long probes = 0;
    while (!dirty.isEmpty()) {
      if (++rounds > 4096) throw new Unsupported("unstable partition");
      int o = dirty.poll();
      var cell = dims.get(o);
      int known = dims.size();
      var contexts = new ArrayList<Setting>();
      for (var c : contexts(radix(dims), o, interesting(p, job, dims, base, random))) contexts.add(setting(dims, c));
      contexts.addAll(extra);
      // Per state and context in which the cell is read: the outcome and the trace of reads.
      var used = new ArrayList<Setting>();
      for (var c : contexts) {
        place(p, dims, c);
        boolean read = false;
        for (var s : List.of(AIR, Blocks.STONE.defaultBlockState())) {
          p.put(cell.offset, s);
          p.outcome(job);
          for (int k = 0; k < p.readCount; k++) if (p.reads[k] == cell.offset) read = true;
        }
        if (read) used.add(c);
      }
      probes += (long) used.size() * COUNT;
      if (spent + probes > 6_000_000_000L) throw new Unsupported("search budget");
      var signatures = new long[COUNT][used.size() * 2];
      for (int c = 0; c < used.size(); c++) {
        place(p, dims, used.get(c));
        for (int n = 0; n < COUNT; n++) {
          p.put(cell.offset, STATES[n]);
          signatures[n][2 * c] = p.outcome(job);
          signatures[n][2 * c + 1] = p.trace;
          absorb(p, dims, seeds);
        }
      }
      var seen = new HashMap<List<Long>, Integer>();
      int[] cls = new int[COUNT];
      var found = new ArrayList<BlockState>();
      for (int n = 0; n < COUNT; n++) {
        var sig = Arrays.stream(signatures[n]).boxed().toList();
        Integer c = seen.get(sig);
        if (c == null) { c = seen.size(); seen.put(sig, c); found.add(STATES[n]); }
        cls[n] = c;
      }
      if (found.size() > 255) throw new Unsupported("classes");
      cls = SupportOracle.intern(cls);
      boolean changed = cell.classes == null || !Arrays.equals(cell.classes, cls);
      boolean grown = dims.size() > known;
      cell.classes = cls;
      cell.reps = found;
      if (changed || grown) for (int i = 0; i < dims.size(); i++) if (i != o && dims.get(i).var < 0 && !dirty.contains(i)) dirty.add(i);
      if (grown && !dirty.contains(o)) dirty.add(o);
    }
    return probes;
  }

  /** Per combination of variable values the leaf of cells read under it, then the classes of values. */
  static Rule leaves(Probe p, Job job, List<Dim> dims) {
    var varDims = new ArrayList<Integer>();
    for (int i = 0; i < dims.size(); i++) if (dims.get(i).var >= 0) varDims.add(i);
    int[] varRadix = varDims.stream().mapToInt(i -> dims.get(i).size()).toArray();
    long product = 1;
    for (int x : varRadix) product *= x;
    if (product > MAX_LEAVES) throw new Unsupported("variables");
    var leaves = new Leaf[(int) product];
    var interned = new HashMap<String, Leaf>();
    int[] values = new int[varRadix.length];
    int index = 0;
    do {
      // Cells read under these values, grown until enumerating them reads nothing new.
      var cells = new TreeSet<Integer>();
      int[] choice = new int[dims.size()];
      for (int i = 0; i < varDims.size(); i++) choice[varDims.get(i)] = values[i];
      place(p, dims, choice);
      p.outcome(job);
      collect(p, dims, cells);
      Leaf leaf;
      while (true) {
        var order = new ArrayList<>(cells);
        int[] radix = order.stream().mapToInt(i -> dims.get(i).size()).toArray();
        long size = 1;
        for (int x : radix) size *= x;
        if (size > MAX_TABLE) throw new Unsupported("table");
        int[] table = new int[(int) size];
        int[] pick = new int[radix.length];
        int t = 0;
        boolean grown = false;
        do {
          for (int i = 0; i < pick.length; i++) choice[order.get(i)] = pick[i];
          place(p, dims, choice);
          table[t++] = p.outcome(job);
          if (collect(p, dims, cells)) { grown = true; break; }
        } while (SupportOracle.next(pick, radix));
        if (grown) continue;
        int[] offsets = order.stream().mapToInt(i -> dims.get(i).offset).toArray();
        int[][] classes = order.stream().map(i -> dims.get(i).classes).toArray(int[][]::new);
        leaf = new Leaf(offsets, classes, table);
        break;
      }
      final Leaf found = leaf;
      leaves[index++] = interned.computeIfAbsent(found.key(), k -> found);
    } while (SupportOracle.next(values, varRadix));
    // Classes of each variable's values: equal when every leaf they select is equal.
    int[][] classes = new int[varRadix.length][];
    for (int v = 0; v < varRadix.length; v++) {
      var slices = new ArrayList<List<Leaf>>();
      classes[v] = new int[varRadix[v]];
      for (int value = 0; value < varRadix[v]; value++) {
        var slice = new ArrayList<Leaf>();
        int[] at = new int[varRadix.length];
        int[] r = varRadix.clone();
        r[v] = 1;
        do {
          at[v] = value;
          slice.add(leaves[flat(at, varRadix)]);
          at[v] = 0;
        } while (SupportOracle.next(at, r));
        int c = -1;
        for (int k = 0; k < slices.size(); k++) if (same(slices.get(k), slice)) c = k;
        if (c < 0) { c = slices.size(); slices.add(slice); }
        classes[v][value] = c;
      }
    }
    // Keep the variables with more than one class; the leaves over their classes.
    var kept = new ArrayList<Integer>();
    for (int v = 0; v < varRadix.length; v++) if (Arrays.stream(classes[v]).max().orElse(0) > 0) kept.add(v);
    int[] keptRadix = kept.stream().mapToInt(v -> Arrays.stream(classes[v]).max().getAsInt() + 1).toArray();
    long size = 1;
    for (int x : keptRadix) size *= x;
    var out = new Leaf[(int) size];
    int[] pick = new int[kept.size()];
    int t = 0;
    do {
      int[] at = new int[varRadix.length];
      for (int i = 0; i < kept.size(); i++) {
        int v = kept.get(i);
        for (int value = 0; value < varRadix[v]; value++) if (classes[v][value] == pick[i]) { at[v] = value; break; }
      }
      out[t++] = leaves[flat(at, varRadix)];
    } while (SupportOracle.next(pick, keptRadix));
    int[] vars = kept.stream().mapToInt(v -> dims.get(varDims.get(v)).var).toArray();
    int[][] keptClasses = kept.stream().map(v -> classes[v]).toArray(int[][]::new);
    return new Rule(vars, keptClasses, out);
  }

  static boolean same(List<Leaf> a, List<Leaf> b) {
    for (int i = 0; i < a.size(); i++) if (a.get(i) != b.get(i)) return false;
    return true;
  }

  static int flat(int[] at, int[] radix) {
    int f = 0;
    for (int i = 0; i < at.length; i++) f = f * radix[i] + at[i];
    return f;
  }

  /** Adds the cells the last run read to `cells` (dim indices); whether any was new. */
  static boolean collect(Probe p, List<Dim> dims, Set<Integer> cells) {
    boolean grown = false;
    for (int k = 0; k < p.readCount; k++) {
      int r = p.reads[k];
      int dim = -1;
      for (int i = 0; i < dims.size(); i++) if (dims.get(i).var < 0 && dims.get(i).offset == r) dim = i;
      if (dim < 0) throw new Unsupported("unstable reads");
      grown |= cells.add(dim);
    }
    if ((p.varReads & ~(1 << OWN)) != 0) {
      for (int v = 0; v < VARS.length; v++) {
        final int var = v;
        if (v != OWN && (p.varReads & 1 << v) != 0 && dims.stream().noneMatch(d -> d.var == var)) throw new Unsupported("unstable variables");
      }
    }
    return grown;
  }

  /**
   * Connecting blocks and leaves read their neighbours as air (redstone wire every cell around
   * it but its floor); ValiMC adds the rest.
   */
  static void mask(Probe p, Job job) {
    Arrays.fill(p.masked, false);
    for (int i : masked(job)) p.masked[i] = true;
  }

  static List<Integer> masked(Job job) {
    var out = new ArrayList<Integer>();
    if (job.post == 0) return out;
    if (job.item.getBlock() instanceof RedstoneWireBlock) {
      for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++)
        if (!(dx == 0 && dz == 0 && dy <= 0)) out.add(index(dx, dy, dz));
      return out;
    }
    for (var d : Direction.values()) out.add(index(d.getStepX(), d.getStepY(), d.getStepZ()));
    return out;
  }

  static int post(Block block) {
    if (block instanceof StairBlock || block instanceof FenceBlock || block instanceof IronBarsBlock || block instanceof WallBlock
        || block instanceof RedstoneWireBlock) return POST_SHAPE;
    if (block instanceof LeavesBlock) return POST_LEAVES;
    return 0;
  }

  /** Vanilla's placement against the masked one with the post step, on random neighbourhoods. */
  static void checkPost(Probe p, Job job, List<BlockState> pool, Random random) {
    for (int k = 0; k < 400; k++) {
      p.clear();
      for (int i = 0; i < VARS.length; i++) p.vars[i] = random.nextInt(DOMAIN[i]);
      p.put(index(0, 0, 0), random.nextInt(3) == 0 ? Blocks.WATER.defaultBlockState() : AIR);
      for (int i : masked(job)) if (random.nextInt(3) > 0) p.put(i, pool.get(random.nextInt(pool.size())));
      if (random.nextInt(4) > 0) p.put(index(0, -1, 0), random.nextBoolean() ? Blocks.STONE.defaultBlockState() : pool.get(random.nextInt(pool.size())));
      Arrays.fill(p.masked, false);
      String real;
      try { real = p.run(job); } catch (Unsupported e) { continue; }
      mask(p, job);
      String masked = p.run(job);
      String composed = masked;
      if (masked.startsWith("w") && p.writeCount == 1) {
        Arrays.fill(p.masked, false);
        BlockState s = p.written[index(0, 0, 0)];
        p.begin();
        if (job.post == POST_SHAPE) {
          for (var d : Direction.values()) s = s.updateShape(p.level, p.level, ORIGIN, d, ORIGIN.relative(d), p.at(ORIGIN.relative(d)), p.random);
        } else {
          s = (BlockState) invoke(UPDATE_DISTANCE, null, s, p.level, ORIGIN);
        }
        composed = "w0,0,0," + Block.getId(s) + ";";
      }
      if (!real.equals(composed)) throw new Unsupported("placement is not its masked placement and post step: " + real + " " + composed);
    }
    mask(p, job);
  }

  // ---- Replacement: whether a click replaces the clicked state ----

  static final int[] REPLACEMENT_VARS = {OWN, FACE, CURSOR, SECONDARY};

  /** Whether a click on `s` replaces it, per combination of the inputs it reads ("0", "1" or a rule). */
  static String replacement(Probe p, BlockState s, Item other) {
    var own = s.getBlock().asItem();
    int reads = 0;
    // Inputs read, found from every face, cursor and item.
    for (int pass = 0; pass < 2; pass++) {
      for (int k = 0; k < 64; k++) {
        p.vars[FACE] = k % 6; p.vars[CURSOR] = (k * 7) % 27; p.vars[SECONDARY] = k / 32; p.vars[OWN] = k / 6 % 2;
        replaced(p, s, own, other);
        reads |= p.varReads;
      }
    }
    var used = new ArrayList<Integer>();
    for (int v : REPLACEMENT_VARS) if ((reads & 1 << v) != 0 && (v != OWN || own != Items.AIR)) used.add(v);
    int[] radix = used.stream().mapToInt(v -> DOMAIN[v]).toArray();
    int[] values = new int[radix.length];
    var bits = new StringBuilder();
    do {
      Arrays.fill(p.vars, 0);
      for (int i = 0; i < values.length; i++) p.vars[used.get(i)] = values[i];
      bits.append(replaced(p, s, own, other) ? '1' : '0');
    } while (SupportOracle.next(values, radix));
    if (bits.indexOf("1") < 0) return "0";
    if (bits.indexOf("0") < 0) return "1";
    var names = new StringJoiner(",");
    for (int v : used) names.add(VARS[v]);
    return names + "|" + bits;
  }

  static boolean replaced(Probe p, BlockState s, Item own, Item other) {
    var item = p.vars[OWN] == 1 && own != Items.AIR ? own : other;
    p.clear();
    p.put(index(0, 0, 0), s);
    p.targetX = p.targetY = p.targetZ = 0;
    p.reach = 0;
    p.begin();
    try {
      var context = p.context(new Job(null, new ItemStack(item), 0, false), ORIGIN, null);
      if (p.readCount > 1 || p.readCount == 1 && p.reads[0] != index(0, 0, 0)) throw new AssertionError("Replacement reads the level: " + s);
      return context.replacingClickedOnBlock();
    } finally {
      p.reach = READ;
    }
  }

  // ---- Views: the orders and rotations, with yaw and pitch that give them ----

  static void views(Probe p) {
    var orders = new LinkedHashMap<String, Integer>();
    for (int yaw10 = -1800; yaw10 < 1800; yaw10 += 5) for (int pitch10 = -895; pitch10 <= 895; pitch10 += 10) {
      float yaw = yaw10 / 10f + 0.13f, pitch = pitch10 / 10f + 0.07f;
      p.setView(new float[] {yaw, pitch});
      var order = Direction.orderedByNearest(p.player);
      var key = Arrays.toString(order);
      if (!orders.containsKey(key)) {
        if (orders.size() == 48) throw new AssertionError("More than 48 orders");
        ORDERS[orders.size()] = order;
        ORDER_VIEWS[orders.size()] = new float[] {yaw, pitch};
        orders.put(key, orders.size());
      }
    }
    if (orders.size() != 48) throw new AssertionError("Orders: " + orders.size());
    // Rotation classes: the yaw's segment and horizontal direction, between both kinds of boundary.
    var bounds = new TreeSet<Double>();
    for (int k = 0; k < 16; k++) bounds.add(-180 + 11.25 + 22.5 * k);
    for (int k = 0; k < 4; k++) bounds.add(-135.0 + 90 * k);
    var edges = new ArrayList<>(bounds);
    int n = 0;
    for (int k = 0; k < edges.size(); k++) {
      double lo = edges.get(k), hi = k + 1 < edges.size() ? edges.get(k + 1) : edges.get(0) + 360;
      float yaw = (float) ((lo + hi) / 2);
      if (yaw >= 180) yaw -= 360;
      ROTATIONS[n] = new int[] {RotationSegmentProbe.segment(yaw), Direction.fromYRot(yaw).get2DDataValue()};
      ROTATION_YAW[n++] = yaw;
    }
    if (n != 20) throw new AssertionError("Rotations: " + n);
  }

  static final class RotationSegmentProbe {
    static int segment(float yaw) { return net.minecraft.world.level.block.state.properties.RotationSegment.convertToSegment(yaw); }
  }

  // ---- Cases: the coverage matrix ----

  /** A random click of `job`'s item from real yaw and pitch: its cells, inputs and vanilla's outcome. */
  static JsonArray realCase(Probe p, Job job, List<BlockState> pool, List<Integer> offsets, Random random) {
    p.clear();
    var face = Direction.from3DDataValue(random.nextInt(6));
    // Cells relative to the clicked block: the clicked block, and the cells read around either target.
    p.put(index(0, 0, 0), pool.get(random.nextInt(pool.size())));
    for (int target = 0; target < 2; target++) for (int o : offsets) {
      int[] d = offset(o);
      int x = d[0] + (target == 1 ? face.getStepX() : 0), y = d[1] + (target == 1 ? face.getStepY() : 0), z = d[2] + (target == 1 ? face.getStepZ() : 0);
      if (Math.abs(x) > R || Math.abs(y) > R || Math.abs(z) > R || x == 0 && y == 0 && z == 0) continue;
      if (random.nextInt(10) < 6) p.put(index(x, y, z), pool.get(random.nextInt(pool.size())));
    }
    float yaw = random.nextFloat() * 360 - 180, pitch = random.nextFloat() * 180 - 90;
    double[] cursor = new double[3];
    for (int a = 0; a < 3; a++) cursor[a] = random.nextInt(8) == 0 ? 0.5 : (double) random.nextFloat();
    int step = face.getAxisDirection() == Direction.AxisDirection.POSITIVE ? 1 : 0;
    cursor[face.getAxis().ordinal()] = step;
    boolean secondary = random.nextBoolean();
    p.inside = random.nextInt(4) == 0;
    p.vars[SECONDARY] = secondary ? 1 : 0;
    // The target's light, which ValiMC reads from its light engine.
    p.vars[LIGHT] = random.nextInt(16);
    p.vars[SKY] = random.nextInt(4) == 0 ? 1 : 0;
    p.signals.clear();
    p.signalSeed = random.nextLong();
    p.vars[FACE] = face.get3DDataValue();
    p.setView(new float[] {yaw, pitch});
    p.real = true;
    String outcome;
    try {
      p.targetX = p.targetY = p.targetZ = 0;
      p.reach = R;
      p.begin();
      Arrays.fill(p.masked, false);
      var context = p.context(job, ORIGIN, new Vec3(cursor[0], cursor[1], cursor[2]));
      outcome = random(p, job, context);
    } catch (Unsupported e) {
      return null;
    } finally {
      p.real = false;
      p.reach = READ;
    }
    var row = new JsonArray();
    row.add(BuiltInRegistries.ITEM.getId(job.item));
    row.add(yaw);
    row.add(pitch);
    row.add(face.get3DDataValue());
    var c = new JsonArray();
    for (double v : cursor) c.add(v);
    row.add(c);
    row.add(secondary);
    row.add(p.inside);
    row.add(p.vars[LIGHT]);
    row.add(p.vars[SKY] == 1);
    // The redstone power the click asked about, by position relative to the clicked block.
    var signals = new JsonArray();
    p.signals.forEach((pos, on) -> {
      var s = new JsonArray();
      s.add(pos.getX() - ORIGIN.getX());
      s.add(pos.getY() - ORIGIN.getY());
      s.add(pos.getZ() - ORIGIN.getZ());
      s.add(on);
      signals.add(s);
    });
    row.add(signals);
    var cells = new JsonArray();
    for (int k = 0; k < p.setCount; k++) {
      int i = p.set[k];
      int[] o = offset(i);
      var cell = new JsonArray();
      for (int v : o) cell.add(v);
      cell.add(Block.getId(p.cells[i]));
      cells.add(cell);
    }
    row.add(cells);
    row.add(writes(outcome));
    return row;
  }

  /** A real click's outcome, relative to the clicked block; a random outcome as its draws' first. */
  static String random(Probe p, Job job, BlockPlaceContext context) {
    p.fixed = 0;
    var key = p.place(job, context);
    return key;
  }

  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    // The run takes most of an hour; its own classes load now, before the shared class cache may
    // drop this build (`java_tool.py` keeps the most recent builds).
    for (var nested : PlacementOracle.class.getDeclaredClasses()) Class.forName(nested.getName());
    SupportOracle.bindFluidTags();
    var unsafe = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafe.setAccessible(true);
    UNSAFE = (sun.misc.Unsafe) unsafe.get(null);
    REGISTRIES = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    COUNT = Block.BLOCK_STATE_REGISTRY.size();
    SupportOracle.COUNT = COUNT;
    STATES = new BlockState[COUNT];
    for (int n = 0; n < COUNT; n++) STATES[n] = Block.stateById(n);
    AIR = Blocks.AIR.defaultBlockState();
    GET_PLACEMENT_STATE = BlockItem.class.getDeclaredMethod("getPlacementState", BlockPlaceContext.class);
    PLACE_BLOCK = BlockItem.class.getDeclaredMethod("placeBlock", BlockPlaceContext.class, BlockState.class);
    UPDATE_DISTANCE = LeavesBlock.class.getDeclaredMethod("updateDistance", BlockState.class, net.minecraft.world.level.LevelAccessor.class, BlockPos.class);
    for (var m : List.of(GET_PLACEMENT_STATE, PLACE_BLOCK, UPDATE_DISTANCE)) m.setAccessible(true);
    var main = new Probe();
    CURRENT.set(main);
    views(main);

    // Block items, in registry order, and how ValiMC treats those it does not place by use on a block.
    var excluded = new TreeMap<Integer, String>();
    var jobs = new ArrayList<Job>();
    // For debugging, `PLACEMENT_ONLY=oak_door,...` tabulates only those items.
    var only = System.getenv("PLACEMENT_ONLY") == null ? null : Set.of(System.getenv("PLACEMENT_ONLY").split(","));
    for (var item : BuiltInRegistries.ITEM) {
      if (!(item instanceof BlockItem blockItem)) continue;
      if (only != null && !only.contains(BuiltInRegistries.ITEM.getKey(item).getPath())) continue;
      int id = BuiltInRegistries.ITEM.getId(item);
      var block = blockItem.getBlock();
      // A wither skull's check for a wither and a hook's tripwire circuit read far; neither changes the placed block.
      // Repeaters and comparators read the signals beside them and the frames before them: redstone (VMC-047).
      if (block instanceof DiodeBlock) { excluded.put(id, "a redstone component, placed with redstone"); continue; }
      // A creaking heart wakes by the time of day: with the creaking (VMC-043).
      if (block instanceof CreakingHeartBlock) { excluded.put(id, "awake by the time of day, placed with the creaking"); continue; }
      // A wither skull's check for a wither, a hook's tripwire circuit and a piston's extension read far;
      // none changes the placed block.
      boolean placedBy = !(block instanceof WitherSkullBlock || block instanceof WitherWallSkullBlock || block instanceof TripWireHookBlock
          || block instanceof net.minecraft.world.level.block.piston.PistonBaseBlock);
      jobs.add(new Job(blockItem, new ItemStack(item), post(block), placedBy));
    }

    var rules = new Rule[jobs.size()];
    var reasons = new String[jobs.size()];
    var probes = ThreadLocal.withInitial(() -> { try { var p = new Probe(); CURRENT.set(p); return p; } catch (Exception e) { throw new RuntimeException(e); } });
    var pool = Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors());
    var tasks = new ArrayList<Future<?>>();
    var done = new AtomicInteger();
    // The slowest first (doors, multiface blocks, standing-and-wall blocks), so they overlap.
    var slowest = new ArrayList<Integer>();
    for (int j = 0; j < jobs.size(); j++) slowest.add(j);
    slowest.sort(Comparator.comparingInt(j -> {
      var block = jobs.get(j).item.getBlock();
      return block instanceof DoorBlock ? 0 : block instanceof MultifaceBlock || block instanceof VineBlock ? 1
          : jobs.get(j).item instanceof StandingAndWallBlockItem ? 2 : 3;
    }));
    for (int j : slowest) {
      final int k = j;
      tasks.add(pool.submit(() -> {
        var p = probes.get();
        var job = jobs.get(k);
        long started = System.nanoTime();
        try {
          if (job.post != 0) checkPost(p, job, seeds(job.item).stream().flatMap(s -> List.of(s,
              Blocks.OAK_STAIRS.defaultBlockState(), Blocks.COBBLESTONE_WALL.defaultBlockState(), Blocks.GLASS_PANE.defaultBlockState()).stream()).toList(),
              new Random(k));
          rules[k] = rule(p, job);
        } catch (Unsupported e) {
          reasons[k] = e.getMessage();
        } catch (RuntimeException e) {
          reasons[k] = e.getClass().getSimpleName() + (e.getStackTrace().length > 0 ? " at " + e.getStackTrace()[0] : "");
        }
        int n = done.incrementAndGet();
        long seconds = (System.nanoTime() - started) / 1_000_000_000L;
        if (seconds >= 10) System.err.println("item " + job.item + ": " + seconds + " s" + (reasons[k] != null ? " (" + reasons[k] + ")" : ""));
        if (n % 100 == 0) System.err.println("items " + n + "/" + jobs.size());
      }));
    }
    for (var task : tasks) task.get();

    // Replacement of every state, per thread over slices.
    var replacements = new String[COUNT];
    var replaceTasks = new ArrayList<Future<?>>();
    int slice = (COUNT + 63) / 64;
    for (int from = 0; from < COUNT; from += slice) {
      final int lo = from, hi = Math.min(COUNT, from + slice);
      replaceTasks.add(pool.submit(() -> {
        var p = probes.get();
        for (int n = lo; n < hi; n++) {
          var stone = replacement(p, STATES[n], Items.STONE);
          for (var other : List.of(Items.DIRT, Items.OAK_SLAB, Items.CANDLE, Items.SEA_PICKLE, Items.SNOW, Items.TURTLE_EGG, Items.GLOW_LICHEN,
              Items.PINK_PETALS, Items.LEAF_LITTER, Items.VINE, Items.SCAFFOLDING, Items.SHORT_GRASS)) {
            if (other == STATES[n].getBlock().asItem()) continue;
            var with = replacement(p, STATES[n], other);
            if (!with.equals(stone))
              throw new AssertionError("Replacement differs by item: " + STATES[n] + " " + other + " " + stone + " " + with);
          }
          replacements[n] = stone;
        }
      }));
    }
    for (var task : replaceTasks) task.get();

    // The coverage matrix: random clicks of every placed item.
    var caseRows = new JsonArray[jobs.size()];
    var caseTasks = new ArrayList<Future<?>>();
    for (int j = 0; j < jobs.size(); j++) {
      if (rules[j] == null) continue;
      final int k = j;
      caseTasks.add(pool.submit(() -> {
        var p = probes.get();
        var job = jobs.get(k);
        var random = new Random(20261022L * 31 + k);
        var cellPool = new ArrayList<BlockState>();
        var offsets = new TreeSet<Integer>();
        for (var leaf : rules[k].leaves) for (int i = 0; i < leaf.offsets.length; i++) {
          offsets.add(leaf.offsets[i]);
          var cls = leaf.classes[i];
          var firsts = new HashMap<Integer, BlockState>();
          for (int n = 0; n < COUNT; n++) firsts.putIfAbsent(cls[n], STATES[n]);
          cellPool.addAll(firsts.values());
        }
        cellPool.addAll(job.item.getBlock().getStateDefinition().getPossibleStates());
        for (int n = 0; n < 40; n++) cellPool.add(STATES[random.nextInt(COUNT)]);
        cellPool.addAll(List.of(AIR, AIR, AIR, Blocks.WATER.defaultBlockState(), Blocks.SHORT_GRASS.defaultBlockState(), Blocks.STONE.defaultBlockState()));
        var rows = new JsonArray();
        // The placements ValiMC does in code get more.
        int count = job.item instanceof ScaffoldingBlockItem || job.item.getBlock() instanceof MossyCarpetBlock ? 600 : 96;
        for (int n = 0; n < count; n++) {
          var row = realCase(p, job, cellPool, new ArrayList<>(offsets), random);
          if (row != null) rows.add(row);
        }
        caseRows[k] = rows;
      }));
    }
    for (var task : caseTasks) task.get();
    pool.shutdown();

    // Facts, numbered in item order so they do not depend on thread timing: per item the root of
    // a decision diagram over its inputs, then its cells.
    var diagram = new Diagram();
    var items = new JsonArray();
    for (int j = 0; j < jobs.size(); j++) {
      var job = jobs.get(j);
      int id = BuiltInRegistries.ITEM.getId(job.item);
      if (rules[j] == null) { excluded.put(id, reasons[j]); continue; }
      // The item's own blocks, which outcomes name relative to their first state.
      var own = new Block[] {job.item.getBlock(), job.item instanceof StandingAndWallBlockItem ? wallBlock(job.item) : null};
      var row = new JsonArray();
      row.add(id);
      row.add(diagram.rule(rules[j], own));
      row.add(job.post);
      for (var b : own) row.add(b == null ? -1 : Block.getId(b.getStateDefinition().getPossibleStates().get(0)));
      items.add(row);
    }
    var gson = new Gson();
    // Outcomes in order of first use; a random one names its alternatives by index.
    var outcomes = new JsonArray();
    for (int k = 0; k < diagram.outKeys.size(); k++) {
      var key = diagram.outKeys.get(k);
      if (key.startsWith("r")) {
        var parts = key.split("\\|");
        var o = new JsonObject();
        var bounds = new JsonArray();
        for (var b : parts[0].substring(2, parts[0].length() - 1).split(", ")) bounds.add(Integer.parseInt(b));
        o.add("draws", bounds);
        var alts = new JsonArray();
        for (int a = 1; a < parts.length; a++) alts.add(diagram.outcome(parts[a]));
        o.add("outcomes", alts);
        outcomes.add(o);
      } else {
        outcomes.add(writes(key));
      }
    }
    // Replacement rules by state run.
    var replacementRules = new JsonArray();
    var replacementIndex = new HashMap<String, Integer>();
    var replacementRuns = new JsonArray();
    for (int n = 0; n < COUNT; n++) {
      var rep = replacements[n];
      int rid;
      if (rep.equals("0")) rid = 0;
      else if (rep.equals("1")) rid = 1;
      else {
        Integer known = replacementIndex.get(rep);
        if (known == null) {
          known = replacementRules.size() + 2;
          replacementIndex.put(rep, known);
          var parts = rep.split("\\|");
          var o = new JsonObject();
          var names = new JsonArray();
          for (var name : parts[0].split(",")) names.add(name);
          o.add("vars", names);
          o.addProperty("table", parts[1]);
          replacementRules.add(o);
        }
        rid = known;
      }
      if (replacementRuns.size() == 0 || replacementRuns.get(replacementRuns.size() - 1).getAsJsonArray().get(2).getAsInt() != rid) {
        var run = new JsonArray();
        run.add(n);
        run.add(n);
        run.add(rid);
        replacementRuns.add(run);
      } else {
        replacementRuns.get(replacementRuns.size() - 1).getAsJsonArray().set(1, new JsonPrimitive(n));
      }
    }
    var excludedJson = new JsonArray();
    excluded.forEach((item, reason) -> { var a = new JsonArray(); a.add(item); a.add(reason); excludedJson.add(a); });
    var ordersJson = new JsonArray();
    for (var order : ORDERS) { var a = new JsonArray(); for (var d : order) a.add(d.get3DDataValue()); ordersJson.add(a); }
    var rotationsJson = new JsonArray();
    for (var rotation : ROTATIONS) rotationsJson.add(SupportOracle.json(rotation));

    var facts = new JsonObject();
    facts.addProperty("version", "26.3");
    facts.addProperty("data_version", 5023);
    facts.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    facts.addProperty("state_count", COUNT);
    facts.add("orders", ordersJson);
    facts.add("rotations", rotationsJson);
    facts.add("partitions", diagram.partitions());
    facts.add("outcomes", outcomes);
    facts.add("nodes", diagram.nodes);
    facts.add("items", items);
    var replacement = new JsonObject();
    replacement.add("rules", replacementRules);
    replacement.add("states", replacementRuns);
    facts.add("replacement", replacement);
    // Each block's item (`Block.asItem`), which `own` compares the held item with.
    var own = new JsonArray();
    for (var block : BuiltInRegistries.BLOCK) {
      if (block.asItem() == Items.AIR) continue;
      var pair = new JsonArray();
      pair.add(BuiltInRegistries.BLOCK.getId(block));
      pair.add(BuiltInRegistries.ITEM.getId(block.asItem()));
      own.add(pair);
    }
    replacement.add("items", own);
    // Operator blocks place only for players who may use them (`GameMasterBlockItem`); a solid
    // bucket leaves an empty bucket in the hand (`SolidBucketItem`).
    var operator = new JsonArray();
    var buckets = new JsonArray();
    var onWater = new JsonArray();
    for (var job : jobs) {
      if (job.item instanceof GameMasterBlockItem) operator.add(BuiltInRegistries.ITEM.getId(job.item));
      if (job.item instanceof SolidBucketItem) buckets.add(BuiltInRegistries.ITEM.getId(job.item));
      if (job.item instanceof PlaceOnWaterBlockItem) onWater.add(BuiltInRegistries.ITEM.getId(job.item));
    }
    facts.add("operator", operator);
    facts.add("buckets", buckets);
    facts.add("on_water", onWater);
    facts.add("excluded", excludedJson);
    Files.writeString(Path.of(args[0]), gson.toJson(facts) + "\n");

    var cases = new JsonObject();
    var matrix = new JsonArray();
    int count = 0;
    for (var rows : caseRows) if (rows != null) { matrix.addAll(rows); count += rows.size(); }
    cases.add("matrix", matrix);
    cases.add("packets", packets());
    cases.add("nonfinite", nonfinite());
    Files.writeString(Path.of(args[1]), gson.toJson(cases));
    var names = new StringJoiner(", ");
    excluded.forEach((item, reason) -> names.add(BuiltInRegistries.ITEM.byId(item) + " (" + reason + ")"));
    System.out.println("PASS: " + items.size() + " block items placed by " + diagram.nodes.size() + " decision nodes ("
        + diagram.partitionList.size() + " partitions, " + outcomes.size() + " outcomes), " + replacementRules.size() + " replacement rules, "
        + count + " matrix cases; excluded " + names);
  }

  static Block wallBlock(BlockItem item) {
    try {
      var f = StandingAndWallBlockItem.class.getDeclaredField("wallBlock");
      f.setAccessible(true);
      return (Block) f.get(item);
    } catch (ReflectiveOperationException e) {
      throw new RuntimeException(e);
    }
  }

  static JsonElement writes(String key) {
    if (key.equals("x")) return JsonNull.INSTANCE;
    if (key.equals("s")) return new JsonPrimitive("walk");
    if (key.equals("m")) return new JsonPrimitive("mossy_carpet");
    var out = new JsonArray();
    for (var w : key.substring(1).split(";")) {
      if (w.isEmpty()) continue;
      var a = new JsonArray();
      // An own state is `k@slot`: [dx, dy, dz, k, slot].
      for (var v : w.replace('@', ',').split(",")) a.add(Integer.parseInt(v));
      out.add(a);
    }
    return out;
  }

  /**
   * The rules as one decision diagram: a node tests an input (`[0, input, child per value]`) or a
   * cell (`[1, dx, dy, dz, partition, child per class]`); a child is a node's index, or `-1 - id`
   * for an outcome. A test whose children are all one is left out, and equal nodes are shared.
   */
  static final class Diagram {
    final JsonArray nodes = new JsonArray();
    final Map<String, Integer> index = new HashMap<>();
    /** Outcome keys with the item's own states relative (`k@slot`), in order of first use. */
    final List<String> outKeys = new ArrayList<>();
    final Map<String, Integer> outIds = new HashMap<>();
    Block[] own;
    final List<int[]> partitionList = new ArrayList<>();
    final Map<int[], Integer> partitionIds = new IdentityHashMap<>();

    int outcome(String key) {
      return outIds.computeIfAbsent(key, k -> { outKeys.add(k); return outKeys.size() - 1; });
    }

    /** A key with the states of the item's own blocks relative to their first state. */
    String relative(String key) {
      if (key.startsWith("r")) {
        var parts = key.split("\\|");
        var b = new StringJoiner("|");
        b.add(parts[0]);
        for (int a = 1; a < parts.length; a++) b.add(relative(parts[a]));
        return b.toString();
      }
      if (!key.startsWith("w")) return key;
      var b = new StringBuilder("w");
      for (var w : key.substring(1).split(";")) {
        if (w.isEmpty()) continue;
        var v = w.split(",");
        int state = Integer.parseInt(v[3]);
        var block = Block.stateById(state).getBlock();
        b.append(v[0]).append(',').append(v[1]).append(',').append(v[2]).append(',');
        int slot = block == own[0] ? 0 : block == own[1] ? 1 : -1;
        if (slot < 0) b.append(state);
        else b.append(state - Block.getId(block.getStateDefinition().getPossibleStates().get(0))).append('@').append(slot);
        b.append(';');
      }
      return b.toString();
    }

    int rule(Rule rule, Block[] own) {
      this.own = own;
      int[] radix = new int[rule.vars.length];
      for (int v = 0; v < radix.length; v++) radix[v] = Arrays.stream(rule.classes[v]).max().getAsInt() + 1;
      return vars(rule, radix, 0, 0);
    }

    int vars(Rule rule, int[] radix, int v, int prefix) {
      if (v == radix.length) return leaf(rule.leaves[prefix], 0, 0);
      int[] byClass = new int[radix[v]];
      for (int c = 0; c < radix[v]; c++) byClass[c] = vars(rule, radix, v + 1, prefix * radix[v] + c);
      int[] children = new int[rule.classes[v].length];
      for (int value = 0; value < children.length; value++) children[value] = byClass[rule.classes[v][value]];
      return node(new int[] {0, rule.vars[v]}, children);
    }

    int leaf(Leaf leaf, int i, int prefix) {
      if (i == leaf.offsets.length) return -1 - outcome(relative(OUTCOME_KEYS.get(leaf.table[prefix])));
      int[] cls = leaf.classes[i];
      int radix = Arrays.stream(cls).max().getAsInt() + 1;
      int[] children = new int[radix];
      for (int c = 0; c < radix; c++) children[c] = leaf(leaf, i + 1, prefix * radix + c);
      int[] o = offset(leaf.offsets[i]);
      Integer part = partitionIds.get(cls);
      if (part == null) { part = partitionList.size(); partitionList.add(cls); partitionIds.put(cls, part); }
      return node(new int[] {1, o[0], o[1], o[2], part}, children);
    }

    int node(int[] head, int[] children) {
      boolean same = true;
      for (int c : children) same &= c == children[0];
      if (same) return children[0];
      var key = Arrays.toString(head) + Arrays.toString(children);
      Integer id = index.get(key);
      if (id != null) return id;
      var n = new JsonArray();
      for (int h : head) n.add(h);
      for (int c : children) n.add(c);
      id = nodes.size();
      nodes.add(n);
      index.put(key, id);
      return id;
    }

    /**
     * Partitions with their fluid factored out: runs of coarse classes over the states, and per
     * coarse class the class by the state's fluid (registry id). Waterlogged states alternate with
     * dry ones, which a fluid's class tells apart.
     */
    JsonArray partitions() {
      var out = new JsonArray();
      for (int[] cls : partitionList) {
        var runs = new JsonArray();
        var maps = new ArrayList<String>();
        var mapIds = new HashMap<String, Integer>();
        int[] current = null;
        int start = 0;
        var pending = new ArrayList<int[]>();
        for (int n = 0; n <= COUNT; n++) {
          int f = n < COUNT ? BuiltInRegistries.FLUID.getId(STATES[n].getFluidState().getType()) : -1;
          if (n < COUNT && current != null && (current[f] < 0 || current[f] == cls[n])) { current[f] = cls[n]; continue; }
          if (current != null) pending.add(new int[] {start, mapId(current, maps, mapIds)});
          if (n == COUNT) break;
          current = new int[] {-1, -1, -1, -1, -1};
          current[f] = cls[n];
          start = n;
        }
        // Adjacent runs of one map merge.
        for (int k = 0; k < pending.size(); k++) {
          if (k > 0 && pending.get(k)[1] == pending.get(k - 1)[1]) continue;
          runs.add(pending.get(k)[0]);
          runs.add(pending.get(k)[1]);
        }
        var o = new JsonObject();
        o.add("runs", runs);
        var fluids = new JsonArray();
        for (var m : maps) {
          var a = new JsonArray();
          for (var v : m.split(",")) a.add(Math.max(0, Integer.parseInt(v)));
          fluids.add(a);
        }
        o.add("fluids", fluids);
        out.add(o);
      }
      return out;
    }

    static int mapId(int[] map, List<String> maps, Map<String, Integer> ids) {
      var key = String.join(",", Arrays.stream(map).mapToObj(Integer::toString).toList());
      return ids.computeIfAbsent(key, k -> { maps.add(k); return maps.size() - 1; });
    }
  }

  // ---- The use-on packet codec (VMC-029b) ----

  static JsonArray position(BlockPos pos) { return new Gson().toJsonTree(List.of(pos.getX(), pos.getY(), pos.getZ())).getAsJsonArray(); }

  static JsonArray packets() {
    var packets = new JsonArray();
    for (var hand : InteractionHand.values()) for (var face : Direction.values())
      for (var pos : List.of(BlockPos.ZERO, new BlockPos(-33554432, -2048, 33554431), new BlockPos(33554431, 2047, -33554432)))
        for (int sequence : new int[] {0, 127, 128, Integer.MAX_VALUE}) for (boolean inside : new boolean[] {false, true}) for (boolean border : new boolean[] {false, true}) {
          var hit = new BlockHitResult(new Vec3(pos.getX() + .25, pos.getY() + .5, pos.getZ() + .75), face, pos, inside, border);
          var packet = new ServerboundUseItemOnPacket(hand, hit, sequence);
          var buffer = new FriendlyByteBuf(Unpooled.buffer());
          try {
            ServerboundUseItemOnPacket.STREAM_CODEC.encode(buffer, packet);
            var raw = new byte[buffer.readableBytes()];
            buffer.getBytes(buffer.readerIndex(), raw);
            var decoded = ServerboundUseItemOnPacket.STREAM_CODEC.decode(buffer);
            var decodedHit = decoded.hitResult();
            if (buffer.isReadable() || decoded.hand() != hand || decoded.sequence() != sequence || !decodedHit.getBlockPos().equals(pos)
                || decodedHit.getDirection() != face || !decodedHit.getLocation().equals(hit.getLocation()) || decodedHit.isInside() != inside
                || decodedHit.isWorldBorderHit() != border) throw new AssertionError("Placement codec differs");
            var row = new JsonObject();
            row.addProperty("hand", hand == InteractionHand.MAIN_HAND ? "main" : "off");
            row.add("position", position(pos));
            row.addProperty("face", face.get3DDataValue());
            row.addProperty("sequence", sequence);
            row.addProperty("inside", inside);
            row.addProperty("border", border);
            row.add("cursor", new Gson().toJsonTree(List.of(.25, .5, .75)));
            row.addProperty("wire", HexFormat.of().formatHex(raw));
            packets.add(row);
          } finally {
            buffer.release();
          }
        }
    return packets;
  }

  static JsonArray nonfinite() {
    var nonfinite = new JsonArray();
    for (int axis = 0; axis < 3; axis++) for (int bits : new int[] {0x7fc00000, 0x7f800000, 0xff800000}) {
      var buffer = new FriendlyByteBuf(Unpooled.buffer());
      try {
        buffer.writeVarInt(0);
        buffer.writeBlockPos(BlockPos.ZERO);
        buffer.writeVarInt(Direction.UP.get3DDataValue());
        for (int i = 0; i < 3; i++) buffer.writeInt(i == axis ? bits : Float.floatToIntBits(.5f));
        buffer.writeBoolean(false);
        buffer.writeBoolean(false);
        buffer.writeVarInt(1);
        var raw = new byte[buffer.readableBytes()];
        buffer.getBytes(buffer.readerIndex(), raw);
        var decoded = ServerboundUseItemOnPacket.STREAM_CODEC.decode(buffer);
        var location = decoded.hitResult().getLocation();
        double value = axis == 0 ? location.x : axis == 1 ? location.y : location.z;
        if (buffer.isReadable() || decoded.sequence() != 1 || Double.isFinite(value))
          throw new AssertionError("Native codec must retain nonfinite hit for gameplay admission");
        var row = new JsonObject();
        row.addProperty("wire", HexFormat.of().formatHex(raw));
        nonfinite.add(row);
      } finally {
        buffer.release();
      }
    }
    return nonfinite;
  }
}
