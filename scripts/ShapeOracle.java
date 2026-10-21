import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.util.RandomSource;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.level.LevelReader;
import net.minecraft.world.level.ScheduledTickAccess;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.material.Fluid;

/**
 * Vanilla's `updateShape` as decoration and structure templates call it (VMC-025): for a
 * state at a position, a direction and the neighbour there, the state it becomes and the
 * block and fluid ticks it schedules. Per state and direction a rule like the survival
 * facts' (`SupportOracle`): the cells the call reads (the neighbour always among them), a
 * partition of all states per cell, and a table over the class combinations, here of
 * outcome indices. Light reads answer as unlit chunks do (sky 15, block 0); a call that
 * reads scheduled ticks, draws randoms or reads more than eight cells, or a state whose search
 * takes more than the probe budget, is excluded.
 *
 * Analyzed: the states of blocks whose class overrides `updateShape` and that the generated
 * worldgen facts (features, placed features, state providers, material rules, noise settings,
 * with block tags expanded), every structure template's blocks and the processor lists, or
 * `scripts/shape_blocks.txt` (the blocks ValiMC's worldgen code places by name, structure pieces'
 * palettes included) name, except fire, chorus plants, pale moss carpets, vines and
 * speleothems (their updates are code). Blocks that do not override it keep their state and
 * schedule nothing, as vanilla's default does; the other overriding blocks are listed as
 * unmodelled.
 *
 * `ShapeOracle code OUT.json` (VMC-026a): cases for the blocks whose update ValiMC implements
 * in code instead (fire, soul fire, chorus plants and flowers; redstone wire, stairs, fences, bars,
 * panes, walls, doors and coral blocks, VMC-025f): per case a state of one of them,
 * a direction, the cells around it (a random neighbourhood of states those updates read, air
 * elsewhere) and vanilla's outcome (the new state and the ticks scheduled).
 *
 * Usage: ShapeOracle OUT.json. Output: partitions (runs), outcomes ([new state or -1 for
 * unchanged, [[dx, dy, dz, kind (0 block, 1 fluid), id, delay], ...]]), rules (offsets,
 * partitions, table of outcome indices), per analyzed state its six rule ids (-1 unchanged,
 * -2 excluded), and the runs of states whose class overrides `updateShape` but which are not
 * analyzed (unmodelled).
 */
public class ShapeOracle {
  static final BlockPos ORIGIN = new BlockPos(0, 64, 0);
  static final int R = 4, W = 2 * R + 1, CELLS = W * W * W, SELF = index(0, 0, 0);
  static final int MAX_OFFSETS = 8, FULL_CONTEXTS = 64, MAX_TABLE = 65536;
  static final Direction[] DIRS = Direction.values();
  static BlockState[] STATES;
  static int COUNT;
  static BlockState AIR;

  static int index(int dx, int dy, int dz) { return ((dx + R) * W + (dy + R)) * W + (dz + R); }
  static int index(Direction d) { return index(d.getStepX(), d.getStepY(), d.getStepZ()); }
  static int[] offset(int i) { return new int[] {i / (W * W) - R, i / W % W - R, i % W - R}; }

  static final class Unsupported extends RuntimeException {
    Unsupported(String reason) { super(reason, null, false, false); }
  }

  /** One thread's synthetic world: cells by offset index, air elsewhere. */
  static final class Probe implements InvocationHandler {
    final BlockState[] cells = new BlockState[CELLS];
    final int[] set = new int[CELLS];
    int setCount;
    final int[] stamp = new int[CELLS];
    int generation, trace, readCount;
    final int[] reads = new int[CELLS];
    final List<String> ticks = new ArrayList<>();
    final LevelReader level = (LevelReader) Proxy.newProxyInstance(LevelReader.class.getClassLoader(), new Class<?>[] {LevelReader.class}, this);
    final ScheduledTickAccess tickAccess = (ScheduledTickAccess) Proxy.newProxyInstance(ScheduledTickAccess.class.getClassLoader(),
        new Class<?>[] {ScheduledTickAccess.class}, (proxy, m, a) -> {
          if (!m.getName().equals("scheduleTick")) throw new Unsupported("ticks." + m.getName());
          var p = (BlockPos) a[0];
          var o = offsetOf(p);
          if (a[1] instanceof Block block) ticks.add(o[0] + "," + o[1] + "," + o[2] + ",0," + BuiltInRegistries.BLOCK.getId(block) + "," + a[2]);
          else ticks.add(o[0] + "," + o[1] + "," + o[2] + ",1," + BuiltInRegistries.FLUID.getId((Fluid) a[1]) + "," + a[2]);
          return null;
        });
    final RandomSource random = (RandomSource) Proxy.newProxyInstance(RandomSource.class.getClassLoader(), new Class<?>[] {RandomSource.class},
        (proxy, m, a) -> { throw new Unsupported("random"); });

    static int[] offsetOf(BlockPos p) {
      return new int[] {p.getX() - ORIGIN.getX(), p.getY() - ORIGIN.getY(), p.getZ() - ORIGIN.getZ()};
    }

    BlockState at(BlockPos p) {
      int dx = p.getX() - ORIGIN.getX(), dy = p.getY() - ORIGIN.getY(), dz = p.getZ() - ORIGIN.getZ();
      if (Math.abs(dx) > R || Math.abs(dy) > R || Math.abs(dz) > R) throw new Unsupported("far read");
      int i = index(dx, dy, dz);
      if (stamp[i] != generation) { stamp[i] = generation; reads[readCount++] = i; trace = trace * 31 + i; }
      var s = cells[i];
      return s == null ? AIR : s;
    }

    @Override
    public Object invoke(Object proxy, Method m, Object[] a) throws Throwable {
      switch (m.getName()) {
        case "getBlockState": return at((BlockPos) a[0]);
        case "getFluidState": return at((BlockPos) a[0]).getFluidState();
        case "getBlockEntity": return null;
        case "getMinY": if (a == null) return -64; break;
        case "getHeight": if (a == null) return 384; break;
        case "isClientSide": return false;
        case "getSeaLevel": return 63;
        case "enabledFeatures": return FeatureFlags.DEFAULT_FLAGS;
        case "getRawBrightness": case "getMaxLocalRawBrightness": return 15;
        case "getBrightness": return a[0] == net.minecraft.world.level.LightLayer.BLOCK ? 0 : 15;
        case "canSeeSky": return true;
        case "getSkyDarken": return 0;
        // Lava's tick delay reads it; a proto chunk keeps no delays.
        case "environmentAttributes": return net.minecraft.world.attribute.EnvironmentAttributeReader.EMPTY;
        case "hashCode": return System.identityHashCode(proxy);
        case "equals": return proxy == a[0];
        case "toString": return "ShapeProbe";
        default:
      }
      if (m.isDefault()) {
        try { return InvocationHandler.invokeDefault(proxy, m, a); } catch (InvocationTargetException e) { throw e.getCause(); }
      }
      throw new Unsupported("level." + m.getName());
    }

    void clear() { for (int k = 0; k < setCount; k++) cells[set[k]] = null; setCount = 0; }
    void put(int i, BlockState s) { if (cells[i] == null) set[setCount++] = i; cells[i] = s; }
    void begin() { generation++; readCount = 0; trace = 1; ticks.clear(); }

    /**
     * The outcome of `state.updateShape` toward `d` in the current cells: the new state id
     * (-1 unchanged) when nothing is scheduled, else an interned outcome above 2^32.
     */
    long outcome(BlockState state, Direction d) {
      begin();
      var neighborPos = ORIGIN.relative(d);
      var neighbor = at(neighborPos);
      var result = state.updateShape(level, tickAccess, ORIGIN, d, neighborPos, neighbor, random);
      int id = result == state ? -1 : Block.getId(result);
      if (ticks.isEmpty()) return id;
      return (1L << 32) + outcomeId(id + "|" + String.join(";", ticks));
    }
  }

  record Rule(int[] offsets, int[][] classes, int[] radix, long[] table) {}

  static final ConcurrentHashMap<String, Integer> OUTCOMES = new ConcurrentHashMap<>();
  static final ConcurrentHashMap<Integer, String> OUTCOME_KEYS = new ConcurrentHashMap<>();
  static final java.util.concurrent.atomic.AtomicInteger NEXT = new java.util.concurrent.atomic.AtomicInteger();

  static int outcomeId(String key) {
    Integer id = OUTCOMES.get(key);
    if (id != null) return id;
    return OUTCOMES.computeIfAbsent(key, k -> { int n = NEXT.getAndIncrement(); OUTCOME_KEYS.put(n, k); return n; });
  }

  /** An outcome code's key: new state id, then ticks. */
  static String key(long code) {
    return code >= (1L << 32) ? OUTCOME_KEYS.get((int) (code - (1L << 32))) : code + "|";
  }

  static final List<BlockState> SEEDS = new ArrayList<>();

  static void place(Probe p, List<Integer> offsets, List<List<BlockState>> reps, int[] choice) {
    p.clear();
    for (int i = 0; i < choice.length; i++) p.put(offsets.get(i), reps.get(i).get(choice[i]));
  }

  /** A combination of representatives whose outcome differs from `base`, if any. */
  static int[] interesting(Probe p, BlockState s, Direction d, List<Integer> offsets, List<List<BlockState>> reps, long base, Random random) {
    int[] radix = new int[reps.size()];
    long product = 1;
    for (int i = 0; i < radix.length; i++) { radix[i] = reps.get(i).size(); product *= radix[i]; }
    int[] choice = new int[radix.length];
    if (product <= 4096) {
      do { place(p, offsets, reps, choice); if (p.outcome(s, d) != base) return choice; } while (SupportOracle.next(choice, radix));
      return null;
    }
    for (int k = 0; k < 4096; k++) {
      for (int i = 0; i < radix.length; i++) choice[i] = random.nextInt(radix[i]);
      place(p, offsets, reps, choice);
      if (p.outcome(s, d) != base) return choice;
    }
    return null;
  }

  /** The rule of `s` toward `d`, or null when it keeps its state and schedules nothing. */
  static Rule rule(Probe p, BlockState s, Direction d) {
    int neighbor = index(d);
    p.clear();
    long base = p.outcome(s, d);
    var offsets = new ArrayList<Integer>();
    offsets.add(neighbor);
    for (int k = 0; k < p.readCount; k++) if (!offsets.contains(p.reads[k])) offsets.add(p.reads[k]);
    var reps = new ArrayList<List<BlockState>>();
    var classes = new ArrayList<int[]>();
    for (int i = 0; i < offsets.size(); i++) { reps.add(SEEDS); classes.add(null); }
    var dirty = new ArrayDeque<Integer>();
    for (int i = 0; i < offsets.size(); i++) dirty.add(i);
    var random = new Random(Block.getId(s) * 6L + d.ordinal());
    int rounds = 0;
    // A state whose neighbourhood takes more probes than this (chorus plants) stays unmodelled.
    long probes = 0;
    while (!dirty.isEmpty()) {
      if (++rounds > 64) throw new Unsupported("unstable partition");
      int o = dirty.poll();
      int known = offsets.size();
      var contexts = SupportOracle.contexts(reps, o, interesting(p, s, d, offsets, reps, base, random));
      probes += (long) contexts.size() * COUNT;
      if (probes > 400_000_000L) throw new Unsupported("search budget");
      // Per state and context: the outcome and the trace of reads.
      var signatures = new long[COUNT][contexts.size() * 2];
      for (int c = 0; c < contexts.size(); c++) {
        place(p, offsets, reps, contexts.get(c));
        int key = offsets.get(o);
        for (int n = 0; n < COUNT; n++) {
          p.put(key, STATES[n]);
          long outcome = p.outcome(s, d);
          signatures[n][2 * c] = outcome;
          signatures[n][2 * c + 1] = p.trace;
          for (int k = 0; k < p.readCount; k++) if (!offsets.contains(p.reads[k])) offsets.add(p.reads[k]);
        }
      }
      if (offsets.size() > MAX_OFFSETS) throw new Unsupported("offsets");
      var seen = new HashMap<List<Long>, Integer>();
      int[] cls = new int[COUNT];
      var found = new ArrayList<BlockState>();
      for (int n = 0; n < COUNT; n++) {
        var sig = Arrays.stream(signatures[n]).boxed().toList();
        Integer c = seen.get(sig);
        if (c == null) { c = seen.size(); seen.put(sig, c); found.add(STATES[n]); }
        cls[n] = c;
      }
      boolean grown = offsets.size() > known;
      for (int i = known; i < offsets.size(); i++) { reps.add(SEEDS); classes.add(null); }
      cls = SupportOracle.intern(cls);
      boolean changed = classes.get(o) == null || !Arrays.equals(classes.get(o), cls);
      classes.set(o, cls);
      reps.set(o, found);
      if (found.size() > 255) throw new Unsupported("classes");
      if (changed || grown) for (int i = 0; i < offsets.size(); i++) if (i != o && !dirty.contains(i)) dirty.add(i);
      if (grown && !dirty.contains(o)) dirty.add(o);
    }
    int[] keys = offsets.stream().mapToInt(Integer::intValue).toArray();
    int[] radix = new int[keys.length];
    long size = 1;
    for (int i = 0; i < keys.length; i++) { radix[i] = reps.get(i).size(); size *= radix[i]; }
    if (size > MAX_TABLE) throw new Unsupported("table");
    long[] table = new long[(int) size];
    int[] choice = new int[radix.length];
    int index = 0;
    boolean trivial = true;
    do {
      place(p, offsets, reps, choice);
      long outcome = p.outcome(s, d);
      if (outcome != -1) trivial = false;
      table[index++] = outcome;
      for (int k = 0; k < p.readCount; k++) {
        int r = p.reads[k];
        if (Arrays.stream(keys).noneMatch(x -> x == r)) throw new Unsupported("unstable reads");
      }
    } while (SupportOracle.next(choice, radix));
    if (trivial) return null;
    return new Rule(keys, classes.toArray(int[][]::new), radix, table);
  }

  /** Blocks the worldgen facts name, with block tags expanded. */
  static Set<Block> worldgenBlocks() throws Exception {
    var out = new HashSet<Block>();
    var pattern = java.util.regex.Pattern.compile("\"(#?)minecraft:([a-z0-9_/]+)\"");
    for (var name : List.of("features", "placed_features", "block_state_providers", "material_rules", "noise_settings",
        "processor_lists")) {
      var matcher = pattern.matcher(Files.readString(Path.of("priv/worldgen/" + name + ".json")));
      while (matcher.find()) {
        var id = net.minecraft.resources.Identifier.withDefaultNamespace(matcher.group(2));
        if (matcher.group(1).isEmpty()) {
          BuiltInRegistries.BLOCK.getOptional(id).ifPresent(out::add);
        } else {
          var tag = net.minecraft.tags.TagKey.create(net.minecraft.core.registries.Registries.BLOCK, id);
          BuiltInRegistries.BLOCK.get(tag).ifPresent(set -> set.forEach(h -> out.add(h.value())));
        }
      }
    }
    for (var block : List.of(Blocks.AIR, Blocks.CAVE_AIR, Blocks.WATER, Blocks.LAVA, Blocks.STONE, Blocks.BEDROCK)) out.add(block);
    // The blocks of every structure template (VMC-025c features, VMC-025f structures).
    var templates = JsonParser.parseString(Files.readString(Path.of("priv/worldgen/structure_templates.json"))).getAsJsonObject();
    for (var template : templates.entrySet()) {
      for (var palette : template.getValue().getAsJsonObject().getAsJsonArray("blocks")) {
        for (var state : palette.getAsJsonObject().getAsJsonArray("states")) {
          out.add(Block.stateById(state.getAsJsonArray().get(0).getAsInt()).getBlock());
        }
      }
    }
    // And the blocks ValiMC's worldgen code places by name (tree decorators, bamboo, huge mushrooms,
    // structure pieces' palettes, VMC-025f), listed in scripts/shape_blocks.txt (VMC-076d).
    for (var line : Files.readAllLines(Path.of("scripts/shape_blocks.txt"))) {
      var name = line.strip();
      if (name.isEmpty() || name.startsWith("#")) continue;
      out.add(BuiltInRegistries.BLOCK.getOptional(net.minecraft.resources.Identifier.withDefaultNamespace(name))
          .orElseThrow(() -> new IllegalStateException("scripts/shape_blocks.txt: unknown block " + name)));
    }
    // And what structure processors turn template blocks into (VMC-025f): the blackstone
    // replacements of nether ruined portals and every state block ageing picks from.
    var replacements = net.minecraft.world.level.levelgen.structure.templatesystem.BlackstoneReplaceProcessor.class
        .getDeclaredField("replacements");
    replacements.setAccessible(true);
    var blackstone = net.minecraft.world.level.levelgen.structure.templatesystem.BlackstoneReplaceProcessor.INSTANCE;
    ((Map<?, ?>) replacements.get(blackstone)).values().forEach(b -> out.add((Block) b));
    for (var field : net.minecraft.world.level.levelgen.structure.templatesystem.BlockAgeProcessor.class.getDeclaredFields()) {
      if (java.lang.reflect.Modifier.isStatic(field.getModifiers()) && field.getType() == BlockState[].class) {
        field.setAccessible(true);
        for (var state : (BlockState[]) field.get(null)) out.add(state.getBlock());
      }
    }
    // Fire reads all six neighbours' flammability (too many contexts to enumerate) and chorus plants
    // read up to ten cells; ValiMC implements their updates in code, checked by `code` (VMC-026a).
    out.remove(Blocks.FIRE);
    out.remove(Blocks.SOUL_FIRE);
    out.remove(Blocks.CHORUS_PLANT);
    out.remove(Blocks.CHORUS_FLOWER);
    // Pale moss carpets and vines read up to six neighbours too; ValiMC implements their updates in
    // code (VMC-025b).
    out.remove(Blocks.PALE_MOSS_CARPET);
    out.remove(Blocks.VINE);
    // Speleothems read scheduled ticks; ValiMC implements their updates in code (VMC-025c).
    out.remove(Blocks.POINTED_DRIPSTONE);
    out.remove(Blocks.SULFUR_SPIKE);
    // Redstone wire reads too many cells to tabulate; ValiMC implements its update in code (a
    // woodland mansion's, VMC-025f). Repeaters and the other traps and circuits structures place lie
    // underground in jungle temples or come in jigsaw pieces, which place without shape updates;
    // they stay unmodelled.
    for (var block : List.of(Blocks.REDSTONE_WIRE, Blocks.REPEATER, Blocks.COMPARATOR, Blocks.TRIPWIRE,
        Blocks.TRIPWIRE_HOOK, Blocks.STICKY_PISTON, Blocks.PISTON_HEAD)) {
      out.remove(block);
    }
    // Stairs, fences, bars and panes and walls connect to their neighbours over thousands of states;
    // ValiMC implements their updates in code, checked by `code` (VMC-025f).
    // Doors take the other half's state, whatever door it is (VMC-025f): code as well.
    out.removeIf(b -> b instanceof net.minecraft.world.level.block.StairBlock || b instanceof net.minecraft.world.level.block.FenceBlock
        || b instanceof net.minecraft.world.level.block.IronBarsBlock || b instanceof net.minecraft.world.level.block.WallBlock
        || b instanceof net.minecraft.world.level.block.DoorBlock);
    // Live corals draw their death tick's delay from the level's random when no water is beside
    // them (template edges in warm oceans): code as well, with the dead ones.
    out.removeIf(b -> b instanceof net.minecraft.world.level.block.CoralBlock
        || b instanceof net.minecraft.world.level.block.BaseCoralPlantTypeBlock);
    return out;
  }

  static boolean overridesUpdateShape(Block block) {
    for (Class<?> k = block.getClass(); k != null && k != net.minecraft.world.level.block.state.BlockBehaviour.class; k = k.getSuperclass()) {
      for (var m : k.getDeclaredMethods()) if (m.getName().equals("updateShape") && m.getParameterCount() == 8) return true;
    }
    return false;
  }

  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    SupportOracle.bindFluidTags();
    COUNT = Block.BLOCK_STATE_REGISTRY.size();
    STATES = new BlockState[COUNT];
    AIR = Blocks.AIR.defaultBlockState();
    for (int n = 0; n < COUNT; n++) STATES[n] = Block.stateById(n);
    if (args[0].equals("code")) {
      code(Path.of(args[1]));
      return;
    }
    SupportOracle.COUNT = COUNT;
    SupportOracle.STATES = STATES;
    SupportOracle.AIR = AIR;
    SEEDS.addAll(List.of(AIR, Blocks.STONE.defaultBlockState(), Blocks.WATER.defaultBlockState(), Blocks.LAVA.defaultBlockState(),
        Blocks.GRASS_BLOCK.defaultBlockState(), Blocks.DIRT.defaultBlockState(), Blocks.SAND.defaultBlockState(),
        Blocks.OAK_LOG.defaultBlockState(), Blocks.OAK_LEAVES.defaultBlockState(), Blocks.SNOW.defaultBlockState()));
    var blocks = worldgenBlocks();
    var targets = new ArrayList<Integer>();
    var unmodelled = new JsonArray();
    for (int n = 0; n < COUNT; n++) {
      var block = STATES[n].getBlock();
      if (!overridesUpdateShape(block)) continue;
      if (blocks.contains(block)) targets.add(n);
      else if (unmodelled.size() > 0 && unmodelled.get(unmodelled.size() - 1).getAsJsonArray().get(1).getAsInt() == n - 1) {
        unmodelled.get(unmodelled.size() - 1).getAsJsonArray().set(1, new JsonPrimitive(n));
      } else {
        var run = new JsonArray(); run.add(n); run.add(n); unmodelled.add(run);
      }
    }
    var ruleOf = new Rule[COUNT][6];
    var excluded = new ConcurrentHashMap<String, Integer>();
    var probes = ThreadLocal.withInitial(Probe::new);
    var pool = Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors());
    var tasks = new ArrayList<Future<?>>();
    var done = new AtomicLong();
    for (int n : targets) {
      tasks.add(pool.submit(() -> {
        var p = probes.get();
        for (var d : DIRS) {
          try {
            ruleOf[n][d.ordinal()] = rule(p, STATES[n], d);
          } catch (Unsupported e) {
            excluded.merge(BuiltInRegistries.BLOCK.getKey(STATES[n].getBlock()) + ": " + e.getMessage(), 1, Integer::sum);
            ruleOf[n][d.ordinal()] = null;
            markExcluded(n, d);
          } catch (RuntimeException e) {
            excluded.merge(BuiltInRegistries.BLOCK.getKey(STATES[n].getBlock()) + ": " + e.getClass().getSimpleName(), 1, Integer::sum);
            markExcluded(n, d);
          }
        }
        long k = done.incrementAndGet();
        if (k % 500 == 0) System.err.println("states " + k + "/" + targets.size());
      }));
    }
    for (var task : tasks) task.get();
    pool.shutdown();
    var partitions = new SupportOracle.Partitions();
    var rules = new JsonArray();
    var ruleIndex = new HashMap<String, Integer>();
    var gson = new Gson();
    var states = new JsonArray();
    // Outcome ids in order of first use, so the output does not depend on thread timing.
    var renumber = new LinkedHashMap<Long, Integer>();
    int analyzed = 0;
    for (int n : targets) {
      var row = new JsonArray();
      row.add(n);
      boolean any = false;
      for (int d = 0; d < 6; d++) {
        var rule = ruleOf[n][d];
        if (EXCLUDED.contains((long) n * 6 + d)) { row.add(-2); continue; }
        if (rule == null) { row.add(-1); continue; }
        any = true;
        var r = new JsonObject();
        var offs = new JsonArray();
        var parts = new JsonArray();
        for (int i = 0; i < rule.offsets.length; i++) {
          offs.add(SupportOracle.json(offset(rule.offsets[i])));
          parts.add(partitions.index(rule.classes[i]));
        }
        r.add("offsets", offs);
        r.add("partitions", parts);
        var table = new JsonArray();
        for (long t : rule.table) table.add(renumber.computeIfAbsent(t, k -> renumber.size()));
        r.add("table", table);
        var key = gson.toJson(r);
        Integer id = ruleIndex.get(key);
        if (id == null) { id = rules.size(); ruleIndex.put(key, id); rules.add(r); }
        row.add(id);
      }
      if (any || row.asList().stream().anyMatch(e -> e.getAsInt() == -2)) { states.add(row); analyzed++; }
    }
    var outcomes = new JsonArray();
    for (long old : renumber.keySet()) {
      var key = key(old);
      var parts = key.split("\\|", -1);
      var o = new JsonArray();
      o.add(Integer.parseInt(parts[0]));
      var ticks = new JsonArray();
      if (!parts[1].isEmpty()) {
        for (var t : parts[1].split(";")) {
          var tick = new JsonArray();
          for (var v : t.split(",")) tick.add(Integer.parseInt(v));
          ticks.add(tick);
        }
      }
      o.add(ticks);
      outcomes.add(o);
    }
    var excludedJson = new JsonArray();
    new TreeMap<>(excluded).forEach((k, v) -> { var a = new JsonArray(); a.add(k); a.add(v); excludedJson.add(a); });
    var out = new JsonObject();
    out.addProperty("version", "26.3");
    out.addProperty("data_version", 5023);
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("state_count", COUNT);
    out.add("partitions", partitions.json());
    out.add("outcomes", outcomes);
    out.add("rules", rules);
    out.add("states", states);
    out.add("unmodelled", unmodelled);
    out.add("excluded", excludedJson);
    Files.writeString(Path.of(args[0]), gson.toJson(out) + "\n");
    System.out.println("PASS: shape updates of " + targets.size() + " states (" + analyzed + " with rules), " + rules.size()
        + " rules, " + outcomes.size() + " outcomes; excluded " + excludedJson);
  }

  static final Set<Long> EXCLUDED = ConcurrentHashMap.newKeySet();

  /** Cases per block for `code`, and the chance a neighbour cell is not air. */
  static final int CODE_CASES = 3000;
  static final double CODE_FILL = 0.55;

  static Block named(String name) {
    return BuiltInRegistries.BLOCK.getValue(net.minecraft.resources.Identifier.withDefaultNamespace(name));
  }

  static void code(Path out) throws Exception {
    var random = new Random(20261021L);
    // Neighbours those updates tell apart: flammable or not (waterlogged ones do not burn), sturdy
    // tops, soul fire bases, chorus plants and flowers and what supports them, fluids, fire.
    var pool = new ArrayList<BlockState>();
    for (var block : List.of(Blocks.AIR, Blocks.CAVE_AIR, Blocks.NETHERRACK, Blocks.BEDROCK, Blocks.SOUL_SAND, Blocks.SOUL_SOIL,
        Blocks.OBSIDIAN, Blocks.END_STONE, Blocks.OAK_PLANKS, Blocks.OAK_LOG, Blocks.OAK_LEAVES, named("white_wool"),
        named("white_carpet"), Blocks.TNT, Blocks.GLASS, Blocks.STONE, Blocks.WATER, Blocks.LAVA, Blocks.MAGMA_BLOCK,
        Blocks.GRASS_BLOCK, Blocks.FIRE, Blocks.SOUL_FIRE, Blocks.CHORUS_FLOWER, Blocks.SHORT_GRASS, Blocks.VINE)) {
      pool.add(block.defaultBlockState());
    }
    pool.add(Blocks.OAK_LEAVES.defaultBlockState().setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED, true));
    pool.add(Blocks.OAK_SLAB.defaultBlockState());
    pool.add(Blocks.OAK_SLAB.defaultBlockState().setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED, true));
    pool.add(Blocks.OAK_SLAB.defaultBlockState().setValue(net.minecraft.world.level.block.SlabBlock.TYPE,
        net.minecraft.world.level.block.state.properties.SlabType.TOP));
    for (int i = 0; i < 6; i++) pool.add(Blocks.CHORUS_PLANT.defaultBlockState());
    for (int i = 0; i < 3; i++) pool.add(Blocks.END_STONE.defaultBlockState());
    // What redstone wire connects to (VMC-025f): wire, repeaters and observers by facing, signal
    // sources, conductors and the blocks it may climb.
    for (var block : List.of(Blocks.REDSTONE_WIRE, Blocks.REDSTONE_WIRE, Blocks.REPEATER, Blocks.OBSERVER, Blocks.OAK_TRAPDOOR)) {
      pool.add(block.defaultBlockState());
    }
    for (var block : List.of(Blocks.REDSTONE_TORCH, Blocks.LEVER, Blocks.HOPPER, Blocks.REDSTONE_BLOCK)) {
      pool.add(block.defaultBlockState());
    }
    // What stairs, fences, bars, panes and walls connect to or test above them (VMC-025f).
    var connecting = List.of(Blocks.OAK_STAIRS, Blocks.COBBLESTONE_STAIRS, Blocks.OAK_FENCE, Blocks.NETHER_BRICK_FENCE,
        Blocks.OAK_FENCE_GATE, Blocks.IRON_BARS, Blocks.GLASS_PANE, Blocks.COBBLESTONE_WALL, Blocks.STONE_BRICK_WALL,
        Blocks.OAK_SLAB, Blocks.TORCH, Blocks.LANTERN, Blocks.CARVED_PUMPKIN, Blocks.BARRIER,
        Blocks.SCAFFOLDING, named("white_carpet"), Blocks.CHEST, Blocks.OAK_DOOR, Blocks.SPRUCE_DOOR, Blocks.IRON_DOOR);
    for (var block : connecting) pool.add(block.defaultBlockState());
    var p = new Probe();
    var cases = new JsonArray();
    int changed = 0, ticking = 0;
    for (var block : List.of(Blocks.FIRE, Blocks.SOUL_FIRE, Blocks.CHORUS_PLANT, Blocks.CHORUS_FLOWER, Blocks.REDSTONE_WIRE,
        Blocks.OAK_STAIRS, Blocks.COBBLESTONE_STAIRS, Blocks.OAK_FENCE, Blocks.NETHER_BRICK_FENCE, Blocks.IRON_BARS,
        Blocks.GLASS_PANE, Blocks.COBBLESTONE_WALL, Blocks.STONE_BRICK_WALL, Blocks.OAK_DOOR, Blocks.IRON_DOOR,
        Blocks.HORN_CORAL_BLOCK, Blocks.HORN_CORAL, Blocks.HORN_CORAL_FAN, Blocks.HORN_CORAL_WALL_FAN, Blocks.DEAD_HORN_CORAL,
        Blocks.DEAD_HORN_CORAL_WALL_FAN)) {
      var states = block.getStateDefinition().getPossibleStates();
      for (int k = 0; k < CODE_CASES; k++) {
        var state = states.get(random.nextInt(states.size()));
        var d = DIRS[random.nextInt(6)];
        p.clear();
        var cells = new JsonArray();
        for (int dx = -1; dx <= 1; dx++)
          for (int dy = -1; dy <= 1; dy++)
            for (int dz = -1; dz <= 1; dz++) {
              if ((dx == 0 && dy == 0 && dz == 0) || random.nextDouble() >= CODE_FILL) continue;
              var cell = pool.get(random.nextInt(pool.size()));
              if (cell.is(Blocks.CHORUS_PLANT) || cell.is(Blocks.CHORUS_FLOWER) || cell.is(Blocks.REDSTONE_WIRE)
                  || cell.is(Blocks.REPEATER) || cell.is(Blocks.OBSERVER) || cell.is(Blocks.OAK_TRAPDOOR)
                  || connecting.contains(cell.getBlock())) {
                var choices = cell.getBlock().getStateDefinition().getPossibleStates();
                cell = choices.get(random.nextInt(choices.size()));
              }
              p.put(index(dx, dy, dz), cell);
              var c = new JsonArray();
              c.add(dx);
              c.add(dy);
              c.add(dz);
              c.add(Block.getId(cell));
              cells.add(c);
            }
        p.begin();
        var neighbourPos = ORIGIN.relative(d);
        // Coral blocks draw a tick delay, which proto chunks do not keep: any random will do.
        var result = state.updateShape(p.level, p.tickAccess, ORIGIN, d, neighbourPos, p.at(neighbourPos), RandomSource.create(k));
        var row = new JsonArray();
        row.add(Block.getId(state));
        row.add(d.ordinal());
        row.add(cells);
        row.add(Block.getId(result));
        // Proto chunks keep a tick once per position and type (a live coral and its parent class
        // both schedule water).
        row.add(new Gson().toJsonTree(List.copyOf(new LinkedHashSet<>(p.ticks))));
        cases.add(row);
        if (result != state) changed++;
        if (!p.ticks.isEmpty()) ticking++;
      }
    }
    var json = new JsonObject();
    json.add("cases", cases);
    Files.writeString(out, new Gson().toJson(json) + "\n");
    System.out.println("PASS: " + cases.size() + " shape update cases of fire, soul fire, chorus, redstone wire, connecting blocks, doors and coral ("
        + changed
        + " change the state, "
        + ticking + " schedule ticks)");
  }

  static void markExcluded(int n, Direction d) { EXCLUDED.add((long) n * 6 + d.ordinal()); }
}
