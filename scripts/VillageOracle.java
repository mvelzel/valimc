import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.attribute.EnvironmentAttributeSystem;
import net.minecraft.world.attribute.EnvironmentAttributes;
import net.minecraft.world.entity.ai.village.poi.PoiType;
import net.minecraft.world.entity.npc.villager.VillagerProfession;
import net.minecraft.world.entity.npc.villager.VillagerType;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.memory.MemoryModuleType;
import net.minecraft.world.phys.Vec3;
import java.lang.reflect.*;

/**
 * The village (VMC-044a). `facts OUT` writes what the villager family reads
 * of vanilla: every point-of-interest type with its block states, tickets
 * and valid range, and the POI type tags; each profession's held and
 * acquirable job sites, secondary POI blocks and work sound, in registry
 * order; the villager type each biome gives; the villager and baby schedule
 * (the `villager_activity` attributes) of every dimension over a day as
 * runs of `[from tick, activity]`; and the sound ids the family plays.
 * `cases OUT` ticks vanilla villagers with their own brains over block
 * scenes holding beds, job sites and bells (vanilla's `PoiManager` over
 * them), from a day tick on, the schedule from the overworld's timelines:
 * every tick each mob's motion, rotations, random, running behaviours,
 * activity, POI and walk memories, profession, sleeping place, path, the
 * level random and the tickets taken of each POI.
 */
public class VillageOracle {
  static final List<String> SOUNDS = List.of(
      "minecraft:entity.villager.ambient", "minecraft:entity.villager.trade", "minecraft:entity.villager.no",
      "minecraft:entity.villager.yes", "minecraft:entity.villager.hurt", "minecraft:entity.villager.death",
      "minecraft:entity.villager.celebrate", "minecraft:entity.iron_golem.attack", "minecraft:entity.iron_golem.damage",
      "minecraft:entity.iron_golem.repair", "minecraft:entity.iron_golem.step");

  static String name(Holder<?> holder) { return holder.unwrapKey().orElseThrow().identifier().toString(); }

  static JsonObject facts(HolderLookup.Provider lookup) throws Exception {
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var pois = new JsonObject();
    var poiHolders = BuiltInRegistries.POINT_OF_INTEREST_TYPE.listElements()
        .sorted(Comparator.comparing(h -> name(h))).toList();
    for (var h : poiHolders) {
      PoiType type = h.value();
      var o = new JsonObject();
      var states = new TreeSet<Integer>();
      for (var s : type.matchingStates()) states.add(net.minecraft.world.level.block.Block.getId(s));
      var a = new JsonArray(); states.forEach(a::add); o.add("states", a);
      o.addProperty("max_tickets", type.maxTickets()); o.addProperty("valid_range", type.validRange());
      var tags = new JsonArray(); h.tags().map(t -> t.location().toString()).sorted().forEach(tags::add);
      o.add("tags", tags);
      pois.add(name(h), o);
    }
    out.add("poi_types", pois);
    var professions = new JsonArray();
    for (var p : BuiltInRegistries.VILLAGER_PROFESSION.listElements().toList()) {
      VillagerProfession v = p.value();
      var o = new JsonObject(); o.addProperty("name", name(p)); o.addProperty("id", BuiltInRegistries.VILLAGER_PROFESSION.getId(v));
      var held = new JsonArray(); var acquirable = new JsonArray();
      for (var h : poiHolders) {
        if (v.heldJobSite().test(h)) held.add(name(h));
        if (v.acquirableJobSite().test(h)) acquirable.add(name(h));
      }
      o.add("held", held); o.add("acquirable", acquirable);
      var secondary = new JsonArray(); v.secondaryPoi().stream().map(b -> BuiltInRegistries.BLOCK.getKey(b).toString()).sorted().forEach(secondary::add);
      o.add("secondary_poi", secondary);
      var requested = new JsonArray(); v.requestedItems().stream().map(i -> BuiltInRegistries.ITEM.getKey(i).toString()).sorted().forEach(requested::add);
      o.add("requested_items", requested);
      o.addProperty("work_sound", v.workSound() == null ? null : v.workSound().location().toString());
      professions.add(o);
    }
    out.add("professions", professions);
    var types = new JsonArray();
    for (var t : BuiltInRegistries.VILLAGER_TYPE.listElements().toList()) {
      var o = new JsonObject(); o.addProperty("name", name(t)); o.addProperty("id", BuiltInRegistries.VILLAGER_TYPE.getId(t.value())); types.add(o);
    }
    out.add("villager_types", types);
    var byBiome = new JsonObject();
    lookup.lookupOrThrow(Registries.BIOME).listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString()))
        .forEach(k -> byBiome.addProperty(k.identifier().toString(), VillagerType.byBiome(lookup.lookupOrThrow(Registries.BIOME).getOrThrow(k)).identifier().toString()));
    out.add("villager_type_by_biome", byBiome);
    out.add("schedules", schedules(lookup));
    var sounds = new JsonObject();
    var names = new TreeSet<String>(SOUNDS);
    for (var p : BuiltInRegistries.VILLAGER_PROFESSION) if (p.workSound() != null) names.add(p.workSound().location().toString());
    for (var n : names) sounds.addProperty(n, BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(n))));
    out.add("sounds", sounds);
    return out;
  }

  /** Each dimension type's villager and baby villager activity over a day, as change points. */
  static JsonObject schedules(HolderLookup.Provider lookup) {
    var out = new JsonObject();
    var dims = lookup.lookupOrThrow(Registries.DIMENSION_TYPE);
    for (var key : dims.listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString())).toList()) {
      var dim = dims.getOrThrow(key);
      long[] ticks = {0};
      net.minecraft.world.clock.ClockManager clocks = clock -> new net.minecraft.world.clock.ClockInstance() {
        public long totalTicks() { return ticks[0]; }
        public float partialTick() { return 0; }
        public float rate() { return 1; }
        public boolean isPaused() { return false; }
      };
      var builder = EnvironmentAttributeSystem.builder().addConstantLayer(dim.value().attributes());
      for (var t : dim.value().timelines()) builder.addTimelineLayer(t, clocks);
      var system = builder.build();
      var o = new JsonObject();
      for (var attribute : List.of(EnvironmentAttributes.VILLAGER_ACTIVITY, EnvironmentAttributes.BABY_VILLAGER_ACTIVITY)) {
        var runs = new JsonArray(); String last = null;
        for (long t = 0; t < 24000; t++) {
          ticks[0] = t + 24000L * 5;
          system.invalidateTickCache();
          var value = system.getDimensionValue(attribute).getName();
          if (!value.equals(last)) { var r = new JsonArray(); r.add(t); r.add(value); runs.add(r); last = value; }
        }
        o.add(attribute == EnvironmentAttributes.VILLAGER_ACTIVITY ? "adult" : "baby", runs);
      }
      out.add(key.identifier().toString(), o);
    }
    return out;
  }


  // ---- cases ----

  static sun.misc.Unsafe unsafe() { return MobAiOracle.unsafe; }

  static void setFinal(Class<?> c, String n, Object o, Object v) throws Exception { MobAiOracle.setFinal(c, n, o, v); }

  /** Vanilla's `PoiManager`, in memory: every section of the scene's chunks loaded and empty. */
  static net.minecraft.world.entity.ai.village.poi.PoiManager poiManager(MobAiOracle.Probe level) throws Exception {
    var u = unsafe();
    var poi = (net.minecraft.world.entity.ai.village.poi.PoiManager)u.allocateInstance(net.minecraft.world.entity.ai.village.poi.PoiManager.class);
    var storage = net.minecraft.world.level.chunk.storage.SectionStorage.class;
    var map = new it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap<Optional<Object>>();
    for (int cx = -8; cx <= 8; cx++) for (int cz = -8; cz <= 8; cz++) for (int sy = -4; sy < 20; sy++)
      map.put(SectionPos.asLong(cx, sy, cz), Optional.empty());
    setFinal(storage, "storage", poi, map);
    setFinal(storage, "dirtyChunks", poi, new it.unimi.dsi.fastutil.longs.LongLinkedOpenHashSet());
    setFinal(storage, "loadedChunks", poi, new it.unimi.dsi.fastutil.longs.LongOpenHashSet());
    setFinal(storage, "pendingLoads", poi, new it.unimi.dsi.fastutil.longs.Long2ObjectOpenHashMap<>());
    setFinal(storage, "loadLock", poi, new Object());
    java.util.function.Function<Runnable, net.minecraft.world.entity.ai.village.poi.PoiSection> factory = net.minecraft.world.entity.ai.village.poi.PoiSection::new;
    setFinal(storage, "factory", poi, factory);
    setFinal(storage, "levelHeightAccessor", poi, level);
    setFinal(net.minecraft.world.entity.ai.village.poi.PoiManager.class, "loadedChunks", poi, new it.unimi.dsi.fastutil.longs.LongOpenHashSet());
    var trackerClass = Class.forName("net.minecraft.world.entity.ai.village.poi.PoiManager$DistanceTracker");
    var make = trackerClass.getDeclaredConstructor(net.minecraft.world.entity.ai.village.poi.PoiManager.class);
    make.setAccessible(true);
    setFinal(net.minecraft.world.entity.ai.village.poi.PoiManager.class, "distanceTracker", poi, make.newInstance(poi));
    return poi;
  }

  /** A level debug synchronizer that sends nothing. */
  static class NoDebug extends net.minecraft.util.debug.LevelDebugSynchronizers {
    private NoDebug() { super(null); }
    public void updatePoi(BlockPos p) {}
    public void registerPoi(net.minecraft.world.entity.ai.village.poi.PoiRecord r) {}
    public void dropPoi(BlockPos p) {}
    public <T> void sendEntityValue(Entity e, net.minecraft.util.debug.DebugSubscription<T> s, T v) {}
    public <T> void clearEntityValue(Entity e, net.minecraft.util.debug.DebugSubscription<T> s) {}
    public <T> void sendBlockValue(BlockPos p, net.minecraft.util.debug.DebugSubscription<T> s, T v) {}
    public <T> void clearBlockValue(BlockPos p, net.minecraft.util.debug.DebugSubscription<T> s) {}
    public <T> void broadcastEventToTracking(BlockPos p, net.minecraft.util.debug.DebugSubscription<T> s, T v) {}
    public boolean hasAnySubscriberFor(net.minecraft.util.debug.DebugSubscription<?> s) { return false; }
  }

  /** A villager whose brain's gates (`ShufflingList`s) are seeded alike on every refresh. */
  static class Villager extends net.minecraft.world.entity.npc.villager.Villager {
    long gateSeed; int refreshes; JsonArray reseeded;
    Villager(MobAiOracle.Probe level) { super(EntityTypes.VILLAGER, level); }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
    // No drawn trades: a trade set draws on its own random sequence only. A
    // shop scene sets its offers (VMC-044b3).
    net.minecraft.world.item.trading.MerchantOffers none = new net.minecraft.world.item.trading.MerchantOffers();
    public net.minecraft.world.item.trading.MerchantOffers getOffers() { return offers != null ? offers : none; }
    public void refreshBrain(net.minecraft.server.level.ServerLevel level) {
      super.refreshBrain(level);
      try { reseeded = seedGates(this, gateSeed + 1000L * ++refreshes); } catch (Exception e) { throw new RuntimeException(e); }
    }
  }

  static net.minecraft.world.entity.Mob mob(String type, MobAiOracle.Probe level) {
    return switch (type) {
      case "minecraft:villager" -> new Villager(level);
      default -> MobAiOracle.mob(type, level);
    };
  }

  static void shuffling(Object o, List<Object> out, Set<Object> seen, int depth) throws Exception {
    if (o == null || depth > 12 || !seen.add(o)) return;
    if (o instanceof net.minecraft.world.entity.ai.behavior.ShufflingList<?> list) {
      out.add(list);
      for (var entry : (List<?>)MobAiOracle.field(net.minecraft.world.entity.ai.behavior.ShufflingList.class, "entries").get(list))
        shuffling(MobAiOracle.field(entry.getClass(), "data").get(entry), out, seen, depth + 1);
      return;
    }
    var name = o.getClass().getName();
    if (o instanceof Collection<?> c) { for (var e : c) shuffling(e, out, seen, depth + 1); return; }
    if (o instanceof com.mojang.datafixers.util.Pair<?, ?> pair) { shuffling(pair.getFirst(), out, seen, depth + 1); shuffling(pair.getSecond(), out, seen, depth + 1); return; }
    if (!(name.startsWith("net.minecraft.world.entity.ai.behavior") || name.contains("$$Lambda"))) return;
    for (Class<?> c = o.getClass(); c != null && c != Object.class; c = c.getSuperclass())
      for (var f : c.getDeclaredFields()) {
        if (Modifier.isStatic(f.getModifiers()) || f.getType().isPrimitive()) continue;
        Object v;
        try { f.setAccessible(true); v = f.get(o); } catch (Exception e) { continue; }
        shuffling(v, out, seen, depth + 1);
      }
  }

  /**
   * Seed every `ShufflingList` of the mob's brain, in the order of its
   * behaviours (priority, activity, place) and depth first within each:
   * `[key, seed]` rows, the key `priority:activity:index` of the behaviour.
   */
  @SuppressWarnings("unchecked")
  static JsonArray seedGates(net.minecraft.world.entity.Mob m, long seed) throws Exception {
    var out = new JsonArray();
    var byPriority = (Map<Integer, Map<net.minecraft.world.entity.schedule.Activity, Set<Object>>>)
        MobAiOracle.field(net.minecraft.world.entity.ai.Brain.class, "availableBehaviorsByPriority").get(m.getBrain());
    long k = 0;
    var keys = new ArrayList<String>(); var lists = new ArrayList<Object>();
    for (var e : byPriority.entrySet())
      for (var a : e.getValue().entrySet()) {
        int index = 0;
        for (var b : a.getValue()) {
          var found = new ArrayList<Object>();
          shuffling(b, found, Collections.newSetFromMap(new IdentityHashMap<>()), 0);
          for (int j = 0; j < found.size(); j++) { keys.add(e.getKey() + ":" + a.getKey().getName() + ":" + index + ":" + j); lists.add(found.get(j)); }
          index++;
        }
      }
    for (int i = 0; i < keys.size(); i++) {
      var random = (net.minecraft.util.RandomSource)MobAiOracle.field(net.minecraft.world.entity.ai.behavior.ShufflingList.class, "random").get(lists.get(i));
      long s = seed + 101 * ++k;
      random.setSeed(s);
      var row = new JsonArray(); row.add(keys.get(i)); row.add(s); out.add(row);
    }
    if (m instanceof Villager) {
      // InsideBrownianWalk uses JDK Collections.shuffle's separate random.
      // Seed it for this probe just as the independent brain gates above.
      long s = seed + 101 * ++k;
      var f = Collections.class.getDeclaredField("r");
      unsafe().putObject(unsafe().staticFieldBase(f), unsafe().staticFieldOffset(f), new Random(s));
      var row = new JsonArray(); row.add("inside_brownian_walk"); row.add(s); out.add(row);
    }
    return out;
  }

  /** For debugging: each gate's children, in their shuffled order, by weight and status. */
  @SuppressWarnings("unchecked")
  static JsonObject gateOrders(net.minecraft.world.entity.Mob m) throws Exception {
    var out = new JsonObject();
    var byPriority = (Map<Integer, Map<net.minecraft.world.entity.schedule.Activity, Set<Object>>>)
        MobAiOracle.field(net.minecraft.world.entity.ai.Brain.class, "availableBehaviorsByPriority").get(m.getBrain());
    for (var e : byPriority.entrySet())
      for (var a : e.getValue().entrySet()) {
        int index = 0;
        for (var b : a.getValue()) {
          if (b instanceof net.minecraft.world.entity.ai.behavior.GateBehavior<?> g) {
            var list = MobAiOracle.field(net.minecraft.world.entity.ai.behavior.GateBehavior.class, "behaviors").get(g);
            var rows = new JsonArray();
            for (var entry : (List<?>)MobAiOracle.field(net.minecraft.world.entity.ai.behavior.ShufflingList.class, "entries").get(list)) {
              var data = (net.minecraft.world.entity.ai.behavior.BehaviorControl<?>)MobAiOracle.field(entry.getClass(), "data").get(entry);
              rows.add(MobAiOracle.field(entry.getClass(), "weight").getInt(entry) + ":" + data.getStatus());
            }
            out.add(e.getKey() + ":" + a.getKey().getName() + ":" + index, rows);
          }
          index++;
        }
      }
    return out;
  }

  /** Per priority, the brain's activities in the order it walks them. */
  @SuppressWarnings("unchecked")
  static JsonObject order(net.minecraft.world.entity.Mob m) throws Exception {
    var byPriority = (Map<Integer, Map<net.minecraft.world.entity.schedule.Activity, Set<Object>>>)
        MobAiOracle.field(net.minecraft.world.entity.ai.Brain.class, "availableBehaviorsByPriority").get(m.getBrain());
    var out = new JsonObject();
    for (var e : byPriority.entrySet()) {
      var a = new JsonArray(); for (var act : e.getValue().keySet()) a.add(act.getName());
      out.add(Integer.toString(e.getKey()), a);
    }
    return out;
  }

  record Block(int x, int y, int z, BlockState state) {}
  /** A mob; `noAi` holds it still (a hostile the villager sees). */
  /** A mob; `noAi` holds it still, `slept` (a game time, or -1) is when a villager last slept. */
  record Spawn(String type, Vec3 position, float yaw, long seed, boolean noAi, int age, String profession, long slept) {
    Spawn(String type, Vec3 position, float yaw, long seed) { this(type, position, yaw, seed, false, 0, null, -1L); }
    Spawn(String type, Vec3 position, float yaw, long seed, boolean noAi, int age, String profession) { this(type, position, yaw, seed, noAi, age, profession, -1L); }
  }

  /**
   * A villager's offers and restocks (VMC-044b3), with 5 experience: when it
   * last restocked, how often today, and offers as `[buy, count, buy b | null, count b, sell, count,
   * uses, max uses, demand, price multiplier, xp]`.
   */
  record Shop(long lastRestock, int restocks, List<Object[]> offers) {}
  static final Map<Long, Shop> SHOPS = new HashMap<>();

  static Field villagerField(String name) throws Exception {
    var f = net.minecraft.world.entity.npc.villager.Villager.class.getDeclaredField(name); f.setAccessible(true); return f;
  }

  static net.minecraft.world.item.Item item(String name) { return BuiltInRegistries.ITEM.getValue(Identifier.parse(name)); }

  /** A wandering trader's setup (VMC-044a4): its wander target and home, despawn delay, and invisibility. */
  record Trader(BlockPos wander, int despawn, boolean invisible) {}
  static final Map<Long, Trader> TRADERS = new HashMap<>();

  static JsonArray pos(BlockPos p) { var a = new JsonArray(); a.add(p.getX()); a.add(p.getY()); a.add(p.getZ()); return a; }

  static JsonElement global(Optional<net.minecraft.core.GlobalPos> g) { return g.isEmpty() ? JsonNull.INSTANCE : pos(g.get().pos()); }

  static JsonElement tracker(net.minecraft.world.entity.ai.behavior.PositionTracker t) {
    if (t == null) return JsonNull.INSTANCE;
    var o = new JsonObject();
    if (t instanceof net.minecraft.world.entity.ai.behavior.EntityTracker e) o.addProperty("entity", e.getEntity().getId());
    else o.add("block", pos(t.currentBlockPosition()));
    return o;
  }

  static JsonObject run(MobAiOracle.Probe level, String name, List<Block> blocks, List<Spawn> spawns, long start, int ticks) throws Exception {
    level.blocks.clear(); level.entities.clear(); level.fighters.clear(); level.sounds.clear(); level.time = start; level.ids = 0;
    var levelRandom = net.minecraft.util.RandomSource.create(7L);
    unsafe().putObject(level, unsafe().objectFieldOffset(net.minecraft.world.level.Level.class.getDeclaredField("random")), levelRandom);
    level.poi = poiManager(level);
    for (var b : blocks) {
      var p = new BlockPos(b.x, b.y, b.z);
      level.blocks.put(p, b.state);
      net.minecraft.world.entity.ai.village.poi.PoiTypes.forState(b.state).ifPresent(t -> level.poi.add(p, t));
    }
    var seedField = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var timeToTick = MobAiOracle.field(net.minecraft.world.entity.ai.sensing.Sensor.class, "timeToTick");
    var sensorsField = MobAiOracle.field(net.minecraft.world.entity.ai.Brain.class, "sensors");
    var mobs = new ArrayList<net.minecraft.world.entity.Mob>();
    var gates = new JsonArray(); var sensorTimes = new JsonArray(); var orders = new JsonArray();
    for (var s : spawns) {
      net.minecraft.world.entity.Mob m = mob(s.type, level);
      if (s.age != 0 && m instanceof AgeableMob a) a.setAge(s.age);
      if (s.profession != null && m instanceof Villager v) {
        v.setVillagerData(v.getVillagerData().withProfession(level.registryAccess(),
            ResourceKey.create(Registries.VILLAGER_PROFESSION, Identifier.parse(s.profession))));
        v.refreshBrain(level);
      }
      if (m instanceof Villager v && SHOPS.containsKey(s.seed)) {
        var shop = SHOPS.get(s.seed);
        var offers = new net.minecraft.world.item.trading.MerchantOffers();
        for (var o : shop.offers) {
          var b = o[2] == null ? Optional.<net.minecraft.world.item.trading.ItemCost>empty()
              : Optional.of(new net.minecraft.world.item.trading.ItemCost(item((String)o[2]), (int)o[3]));
          offers.add(new net.minecraft.world.item.trading.MerchantOffer(new net.minecraft.world.item.trading.ItemCost(item((String)o[0]), (int)o[1]), b,
              new net.minecraft.world.item.ItemStack(item((String)o[4]), (int)o[5]), (int)o[6], (int)o[7], (int)o[10], (float)o[9], (int)o[8]));
        }
        v.setOffers(offers);
        villagerField("lastRestockGameTime").setLong(v, shop.lastRestock);
        villagerField("numberOfRestocksToday").setInt(v, shop.restocks);
        // Experience keeps its profession until it claims the lectern.
        v.setVillagerXp(5);
      }
      m.getRandom().setSeed(s.seed);
      m.setNoAi(s.noAi);
      if (s.slept >= 0) m.getBrain().setMemory(MemoryModuleType.LAST_SLEPT, s.slept);
      // Scenery: a mob held still takes no knockback either (vanilla's does not
      // travel; the owner's would be pushed by a hit).
      if (s.noAi) m.getAttribute(net.minecraft.world.entity.ai.attributes.Attributes.KNOCKBACK_RESISTANCE).setBaseValue(1.0);
      if (m instanceof Villager v) {
        v.gateSeed = s.seed;
        gates.add(seedGates(m, s.seed));
        var times = new JsonArray();
        for (var sensor : ((Map<?, ?>)sensorsField.get(m.getBrain())).values()) times.add(timeToTick.getLong(sensor));
        sensorTimes.add(times); orders.add(order(m));
      } else { gates.add(JsonNull.INSTANCE); sensorTimes.add(JsonNull.INSTANCE); orders.add(JsonNull.INSTANCE); }
      if (m instanceof net.minecraft.world.entity.npc.wanderingtrader.WanderingTrader wt && TRADERS.containsKey(s.seed)) {
        var tr = TRADERS.get(s.seed);
        wt.setDespawnDelay(tr.despawn);
        if (tr.wander != null) { wt.setWanderTarget(tr.wander); wt.setHomeTo(tr.wander, 16); }
        if (tr.invisible) {
          wt.addEffect(new net.minecraft.world.effect.MobEffectInstance(net.minecraft.world.effect.MobEffects.INVISIBILITY, 3600));
          wt.updateDataBeforeSync();
        }
      }
      m.setSilent(false);
      m.snapTo(s.position.x, s.position.y, s.position.z, s.yaw, 0);
      m.setYHeadRot(s.yaw); m.setYBodyRot(s.yaw);
      mobs.add(m); level.entities.add(m);
    }
    var moveControl = net.minecraft.world.entity.ai.control.MoveControl.class;
    var wanted = new Field[]{MobAiOracle.field(moveControl, "wantedX"), MobAiOracle.field(moveControl, "wantedY"), MobAiOracle.field(moveControl, "wantedZ"), MobAiOracle.field(moveControl, "speedModifier"), MobAiOracle.field(moveControl, "operation")};
    var ambient = MobAiOracle.field(net.minecraft.world.entity.Mob.class, "ambientSoundTime");
    var pois = new ArrayList<BlockPos>();
    for (var b : blocks) if (net.minecraft.world.entity.ai.village.poi.PoiTypes.hasPoi(b.state)) pois.add(new BlockPos(b.x, b.y, b.z));
    var trace = new JsonArray();
    level.added = new ArrayList<>();
    long summoned = 0;
    for (int t = 0; t < ticks; t++) {
      level.time++;
      level.env.invalidateTickCache();
      if (level.realSky) level.updateSkyBrightness();
      for (var m : mobs) {
        m.checkDespawn();
        m.setOldPosAndRot();
        m.tickCount++;
        level.current = m;
        m.tick();
        level.current = null;
      }
      // The tracker syncs each entity's data after the tick (`updateDataBeforeSync`:
      // a trader's invisibility).
      for (var m : mobs) m.updateDataBeforeSync();
      // What a mob summoned (a golem) ticks from the next tick, its random seeded alike.
      var spawned = new JsonArray();
      for (var e : level.added)
        if (e instanceof net.minecraft.world.entity.Mob mob) {
          long seed = 1000L + ++summoned;
          mob.getRandom().setSeed(seed);
          var o = new JsonObject(); o.addProperty("type", BuiltInRegistries.ENTITY_TYPE.getKey(mob.getType()).toString());
          o.addProperty("id", mob.getId()); o.addProperty("seed", seed);
          spawned.add(o);
          mobs.add(mob); level.entities.add(mob);
        }
      level.added.clear();
      var row = new JsonObject();
      var mrows = new JsonArray();
      for (var m : mobs) {
        var r = new JsonObject();
        r.add("position", MobAiOracle.bits(m.position())); r.add("velocity", MobAiOracle.bits(m.getDeltaMovement()));
        r.addProperty("on_ground", m.onGround());
        r.addProperty("yaw", Float.floatToRawIntBits(m.getYRot()));
        r.addProperty("head", Float.floatToRawIntBits(m.getYHeadRot()));
        r.addProperty("body", Float.floatToRawIntBits(m.yBodyRot));
        r.addProperty("pitch", Float.floatToRawIntBits(m.getXRot()));
        r.addProperty("seed", ((java.util.concurrent.atomic.AtomicLong)seedField.get(m.getRandom())).get());
        r.addProperty("ambient", ambient.getInt(m));
        if (m instanceof Villager v) {
          var brain = v.getBrain();
          r.add("behaviors", MobAiOracle.behaviors(brain));
          r.addProperty("activity", brain.getActiveNonCoreActivity().map(a -> a.getName()).orElse(null));
          r.addProperty("profession", v.getVillagerData().profession().unwrapKey().orElseThrow().identifier().toString());
          r.add("home", global(brain.getMemory(MemoryModuleType.HOME)));
          r.add("job_site", global(brain.getMemory(MemoryModuleType.JOB_SITE)));
          r.add("potential_job_site", global(brain.getMemory(MemoryModuleType.POTENTIAL_JOB_SITE)));
          r.add("meeting_point", global(brain.getMemory(MemoryModuleType.MEETING_POINT)));
          var walk = brain.getMemory(MemoryModuleType.WALK_TARGET);
          if (walk.isEmpty()) r.add("walk_target", JsonNull.INSTANCE);
          else {
            var w = new JsonObject(); w.add("target", tracker(walk.get().getTarget()));
            w.addProperty("speed", Float.floatToRawIntBits(walk.get().getSpeedModifier())); w.addProperty("close", walk.get().getCloseEnoughDist());
            r.add("walk_target", w);
          }
          r.add("look_target", tracker(brain.getMemory(MemoryModuleType.LOOK_TARGET).orElse(null)));
          var offerRows = new JsonArray();
          for (var o : v.getOffers()) { var a = new JsonArray(); a.add(o.getUses()); a.add(o.getDemand()); offerRows.add(a); }
          r.add("offers", offerRows);
          r.addProperty("restocks", villagerField("numberOfRestocksToday").getInt(v));
          r.addProperty("last_restock", villagerField("lastRestockGameTime").getLong(v));
          r.add("sleeping", v.getSleepingPos().map(VillageOracle::pos).map(a -> (JsonElement)a).orElse(JsonNull.INSTANCE));
          var hostile = brain.getMemory(MemoryModuleType.NEAREST_HOSTILE);
          r.addProperty("hostile", hostile.map(h -> h.getId()).orElse(null));
          if (v.reseeded != null) { r.add("reseeded", v.reseeded); r.add("order", order(v)); v.reseeded = null; }
          if (System.getenv("VILLAGE_GATES") != null) r.add("gate_orders", gateOrders(v));
        }
        r.addProperty("health", Float.floatToRawIntBits(m.getHealth()));
        if (m instanceof net.minecraft.world.entity.npc.wanderingtrader.WanderingTrader wt) {
          r.addProperty("mainhand", BuiltInRegistries.ITEM.getKey(wt.getMainHandItem().getItem()).toString());
          r.addProperty("using", wt.getUseItemRemainingTicks());
          var inv = wt.getEffect(net.minecraft.world.effect.MobEffects.INVISIBILITY);
          r.addProperty("invisibility", inv == null ? -1 : inv.getDuration());
          r.addProperty("invisible", wt.isInvisible()); r.addProperty("despawn", wt.getDespawnDelay());
          var target = (BlockPos)MobAiOracle.field(wt.getClass(), "wanderTarget").get(wt);
          r.add("wander", target == null ? JsonNull.INSTANCE : pos(target));
        }
        if (!(m instanceof Villager)) {
          r.addProperty("goals", MobAiOracle.running((net.minecraft.world.entity.ai.goal.GoalSelector)MobAiOracle.field(net.minecraft.world.entity.Mob.class, "goalSelector").get(m)));
          r.addProperty("targets", MobAiOracle.running((net.minecraft.world.entity.ai.goal.GoalSelector)MobAiOracle.field(net.minecraft.world.entity.Mob.class, "targetSelector").get(m)));
          var target = m.getTarget();
          r.addProperty("target", target == null ? null : target.getId());
        }
        var path = m.getNavigation().getPath();
        if (path == null || path.isDone()) r.add("path", JsonNull.INSTANCE);
        else {
          var p = new JsonArray(); var node = path.getNextNodePos();
          p.add(node.getX()); p.add(node.getY()); p.add(node.getZ()); p.add(MobAiOracle.bits(MobAiOracle.speed(m.getNavigation())));
          r.add("path", p);
        }
        var mc = m.getMoveControl();
        var w = new JsonArray(); for (int i = 0; i < 4; i++) w.add(MobAiOracle.bits(wanted[i].getDouble(mc))); w.add(wanted[4].get(mc).toString());
        r.add("move", w);
        var sounds = new JsonArray(); level.sounds.getOrDefault(m, List.of()).forEach(sounds::add);
        r.add("sounds", sounds);
        mrows.add(r);
      }
      row.add("mobs", mrows);
      row.add("spawned", spawned);
      row.addProperty("level_seed", ((java.util.concurrent.atomic.AtomicLong)seedField.get(levelRandom)).get());
      var taken = new JsonArray();
      for (var p : pois) {
        var record = level.poi.getInRange(h -> true, p, 0, net.minecraft.world.entity.ai.village.poi.PoiManager.Occupancy.ANY).findFirst();
        taken.add(record.map(rec -> {
          try { return rec.getPoiType().value().maxTickets() - MobAiOracle.field(net.minecraft.world.entity.ai.village.poi.PoiRecord.class, "freeTickets").getInt(rec); }
          catch (Exception e) { throw new RuntimeException(e); }
        }).orElse(-1));
      }
      row.add("taken", taken);
      var bed = new JsonArray();
      for (var p : pois) bed.add(net.minecraft.world.level.block.Block.getId(level.getBlockState(p)));
      row.add("states", bed);
      level.sounds.clear();
      trace.add(row);
    }
    var out = new JsonObject(); out.addProperty("name", name); out.addProperty("start", start);
    var bs = new JsonArray();
    for (var b : blocks) { var a = new JsonArray(); a.add(b.x); a.add(b.y); a.add(b.z); a.add(net.minecraft.world.level.block.Block.getId(b.state)); bs.add(a); }
    out.add("blocks", bs);
    var ps = new JsonArray(); for (var p : pois) ps.add(pos(p)); out.add("pois", ps);
    var ms = new JsonArray();
    for (int i = 0; i < spawns.size(); i++) {
      var s = spawns.get(i);
      var o = new JsonObject(); o.addProperty("type", s.type); o.add("position", MobAiOracle.bits(s.position)); o.addProperty("yaw", Float.floatToRawIntBits(s.yaw));
      o.addProperty("seed", s.seed); o.addProperty("id", mobs.get(i).getId()); o.addProperty("no_ai", s.noAi); o.addProperty("age", s.age);
      o.addProperty("profession", s.profession); o.addProperty("slept", s.slept);
      if (SHOPS.containsKey(s.seed)) {
        var shop = SHOPS.get(s.seed); var so = new JsonObject();
        so.addProperty("last_restock", shop.lastRestock); so.addProperty("restocks", shop.restocks);
        so.add("offers", new Gson().toJsonTree(shop.offers));
        o.add("shop", so);
      }
      if (s.type.equals("minecraft:wandering_trader") && TRADERS.containsKey(s.seed)) {
        var tr = TRADERS.get(s.seed); var to = new JsonObject();
        to.add("wander", tr.wander == null ? JsonNull.INSTANCE : pos(tr.wander));
        to.addProperty("despawn", tr.despawn); to.addProperty("invisible", tr.invisible);
        o.add("trader", to);
      }
      ms.add(o);
    }
    out.add("mobs", ms);
    out.addProperty("real_sky", level.realSky);
    out.add("gates", gates); out.add("sensors", sensorTimes); out.add("orders", orders);
    out.add("ticks", trace);
    return out;
  }

  static List<Block> floor(int y, int radius, BlockState state) { return MobAiOracle.floor(y, radius, state).stream().map(b -> new Block(b.x(), b.y(), b.z(), b.state())).toList(); }

  @SafeVarargs
  static List<Block> scene(List<Block>... parts) {
    var at = new LinkedHashMap<BlockPos, Block>();
    for (var part : parts) for (var b : part) at.put(new BlockPos(b.x, b.y, b.z), b);
    return new ArrayList<>(at.values());
  }

  /** A bed whose head is at (x, y, z), its foot toward `facing`'s opposite. */
  static List<Block> bed(int x, int y, int z, Direction facing) {
    var head = Blocks.BED.red().defaultBlockState().setValue(net.minecraft.world.level.block.BedBlock.FACING, facing)
        .setValue(net.minecraft.world.level.block.BedBlock.PART, net.minecraft.world.level.block.state.properties.BedPart.HEAD);
    var foot = head.setValue(net.minecraft.world.level.block.BedBlock.PART, net.minecraft.world.level.block.state.properties.BedPart.FOOT);
    var f = new BlockPos(x, y, z).relative(facing.getOpposite());
    return List.of(new Block(x, y, z, head), new Block(f.getX(), f.getY(), f.getZ(), foot));
  }

  static JsonObject cases(MobAiOracle.Probe level, HolderLookup.Provider lookup) throws Exception {
    // The overworld's timelines on a clock that reads the level's time.
    var dim = lookup.lookupOrThrow(Registries.DIMENSION_TYPE).getOrThrow(ResourceKey.create(Registries.DIMENSION_TYPE, Identifier.parse("minecraft:overworld")));
    // `isDarkOutside` reads the level's dimension type (a trader's drinks).
    unsafe().putObject(level, unsafe().objectFieldOffset(net.minecraft.world.level.Level.class.getDeclaredField("dimensionTypeRegistration")), dim);
    net.minecraft.world.clock.ClockManager clocks = clock -> new net.minecraft.world.clock.ClockInstance() {
      public long totalTicks() { return level.time; }
      public float partialTick() { return 0; }
      public float rate() { return 1; }
      public boolean isPaused() { return false; }
    };
    var builder = EnvironmentAttributeSystem.builder().addConstantLayer(dim.value().attributes());
    for (var t : dim.value().timelines()) builder.addTimelineLayer(t, clocks);
    level.env = builder.build();
    level.debug = (NoDebug)unsafe().allocateInstance(NoDebug.class);
    var stone = Blocks.STONE.defaultBlockState();
    var start = new Vec3(.5, 64, .5);
    var cases = new JsonArray();
    // An unemployed villager idles by day: it claims a bed near it and wanders.
    cases.add(run(level, "villager_idle", scene(floor(63, 12, stone), bed(4, 64, 0, Direction.EAST)),
        List.of(new Spawn("minecraft:villager", start, 0, 31L)), 1000L, 400));
    // At dusk it walks to its bed and sleeps, and wakes in the morning.
    cases.add(run(level, "villager_night", scene(floor(63, 12, stone), bed(4, 64, 0, Direction.EAST)),
        List.of(new Spawn("minecraft:villager", start, 0, 37L)), 11800L, 600));
    // No bed to claim: the rest activity tries InsideBrownianWalk below a roof.
    cases.add(run(level, "villager_roof_no_home", scene(floor(63, 12, stone), floor(67, 12, stone)),
        List.of(new Spawn("minecraft:villager", start, 0, 139L)), 13000L, 160));
    cases.add(run(level, "villager_morning", scene(floor(63, 12, stone), bed(4, 64, 0, Direction.EAST)),
        List.of(new Spawn("minecraft:villager", start, 0, 41L)), 23700L, 500));
    // A lectern makes it a librarian, which works there.
    cases.add(run(level, "villager_job", scene(floor(63, 12, stone), List.of(new Block(-4, 64, 2, Blocks.LECTERN.defaultBlockState()))),
        List.of(new Spawn("minecraft:villager", start, 0, 43L)), 1900L, 700));
    // In the evening it meets at the bell.
    // VMC-044b3: a librarian at its lectern restocks its used trades (demand
    // follows), catches up a new day's demand, or may restock no more today.
    var lectern = scene(floor(63, 12, stone), List.of(new Block(-4, 64, 2, Blocks.LECTERN.defaultBlockState())));
    List<Object[]> stock = List.of(
        new Object[]{"minecraft:paper", 24, null, 0, "minecraft:emerald", 1, 3, 16, 0, 0.05F, 2},
        new Object[]{"minecraft:emerald", 9, null, 0, "minecraft:bookshelf", 1, 12, 12, 2, 0.05F, 1},
        new Object[]{"minecraft:emerald", 5, "minecraft:book", 1, "minecraft:lantern", 1, 0, 12, -3, 0.2F, 1});
    SHOPS.put(149L, new Shop(1800L, 0, stock));
    cases.add(run(level, "librarian_restock", lectern,
        List.of(new Spawn("minecraft:villager", start, 0, 149L, false, 0, "minecraft:librarian")), 1900L, 1500));
    SHOPS.put(151L, new Shop(10000L, 1, stock));
    cases.add(run(level, "librarian_new_day", lectern,
        List.of(new Spawn("minecraft:villager", start, 0, 151L, false, 0, "minecraft:librarian")), 25900L, 1500));
    SHOPS.put(157L, new Shop(1800L, 2, stock));
    cases.add(run(level, "librarian_restocked_twice", lectern,
        List.of(new Spawn("minecraft:villager", start, 0, 157L, false, 0, "minecraft:librarian")), 1900L, 1500));

    cases.add(run(level, "villager_meet", scene(floor(63, 12, stone), List.of(new Block(0, 64, -6, Blocks.BELL.defaultBlockState()))),
        List.of(new Spawn("minecraft:villager", start, 0, 47L)), 8900L, 700));
    // An iron golem strolls where there is no village; one guards a villager
    // and kills a zombie standing near (it ticks first, as it was made first).
    cases.add(run(level, "golem_stroll", floor(63, 12, stone),
        List.of(new Spawn("minecraft:iron_golem", start, 0, 61L)), 1000L, 600));
    // (The zombie stands on a pillar: the golem reaches it without touching it.)
    cases.add(run(level, "golem_defend", scene(floor(63, 12, stone), List.of(new Block(7, 64, 3, stone), new Block(7, 65, 3, stone))),
        List.of(new Spawn("minecraft:iron_golem", start, 0, 67L), new Spawn("minecraft:villager", new Vec3(-3.5, 64, .5), 0, 71L),
            new Spawn("minecraft:zombie", new Vec3(7.5, 66, 3.5), 90, 73L, true, 0, null)), 1000L, 300));
    // Panicking at a zombie, a villager that slept lately and two that agree
    // summon an iron golem.
    cases.add(run(level, "villagers_summon_golem", floor(63, 12, stone),
        List.of(new Spawn("minecraft:villager", start, 0, 79L, false, 0, null, 800L),
            new Spawn("minecraft:villager", new Vec3(-2.5, 64, -2.5), 0, 83L, true, 0, null, 800L),
            new Spawn("minecraft:villager", new Vec3(-2.5, 64, 3.5), 0, 89L, true, 0, null, 800L),
            new Spawn("minecraft:zombie", new Vec3(4.5, 64, .5), 90, 97L, true, 0, null)), 1050L, 160));
    // A wandering trader (VMC-044a4) walks to its wander target; at dusk one
    // drinks a potion of invisibility, at dawn an invisible one milk; one
    // flees a zombie; one counts its despawn delay down.
    level.realSky = true;
    TRADERS.put(101L, new Trader(new BlockPos(11, 64, 3), 48000, false));
    cases.add(run(level, "trader_wander", floor(63, 12, stone), List.of(new Spawn("minecraft:wandering_trader", start, 0, 101L)), 1000L, 400));
    TRADERS.put(103L, new Trader(null, 48000, false));
    cases.add(run(level, "trader_dusk", floor(63, 12, stone), List.of(new Spawn("minecraft:wandering_trader", start, 0, 103L)), 13200L, 120));
    TRADERS.put(107L, new Trader(null, 48000, true));
    cases.add(run(level, "trader_dawn", floor(63, 12, stone), List.of(new Spawn("minecraft:wandering_trader", start, 0, 107L)), 1000L, 120));
    TRADERS.put(109L, new Trader(null, 48000, false));
    cases.add(run(level, "trader_flee", floor(63, 12, stone), List.of(new Spawn("minecraft:wandering_trader", start, 0, 109L),
        new Spawn("minecraft:zombie", new Vec3(4.5, 64, .5), 90, 113L, true, 0, null)), 1000L, 200));
    TRADERS.put(127L, new Trader(null, 30, false));
    cases.add(run(level, "trader_despawn", floor(63, 12, stone), List.of(new Spawn("minecraft:wandering_trader", start, 0, 127L)), 1000L, 29));
    level.realSky = false;
    // A zombie close by makes it panic and flee.
    cases.add(run(level, "villager_panic", floor(63, 12, stone),
        List.of(new Spawn("minecraft:villager", start, 0, 53L), new Spawn("minecraft:zombie", new Vec3(5.5, 64, .5), 90, 59L, true, 0, null)), 1000L, 300));
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    out.add("prices", prices(level, stock));
    return out;
  }

  /**
   * `Villager.updateSpecialPrices` (VMC-044b3) for a player under Hero of the
   * Village at each amplifier (or none): per offer its special price and its
   * first cost's count (`getCostA`).
   */
  static JsonArray prices(MobAiOracle.Probe level, List<Object[]> stock) throws Exception {
    var update = net.minecraft.world.entity.npc.villager.Villager.class.getDeclaredMethod("updateSpecialPrices", net.minecraft.world.entity.player.Player.class);
    update.setAccessible(true);
    var out = new JsonArray();
    for (Integer amplifier : new Integer[]{null, 0, 1, 2, 4, 9}) {
      var v = new Villager(level);
      var offers = new net.minecraft.world.item.trading.MerchantOffers();
      for (var o : stock) {
        var b = o[2] == null ? Optional.<net.minecraft.world.item.trading.ItemCost>empty()
            : Optional.of(new net.minecraft.world.item.trading.ItemCost(item((String)o[2]), (int)o[3]));
        offers.add(new net.minecraft.world.item.trading.MerchantOffer(new net.minecraft.world.item.trading.ItemCost(item((String)o[0]), (int)o[1]), b,
            new net.minecraft.world.item.ItemStack(item((String)o[4]), (int)o[5]), (int)o[6], (int)o[7], (int)o[10], (float)o[9], (int)o[8]));
      }
      v.setOffers(offers);
      var player = new MobAiOracle.Fighter(level, 77, net.minecraft.world.level.GameType.SURVIVAL);
      if (amplifier != null)
        player.getActiveEffectsMap().put(net.minecraft.world.effect.MobEffects.HERO_OF_THE_VILLAGE,
            new net.minecraft.world.effect.MobEffectInstance(net.minecraft.world.effect.MobEffects.HERO_OF_THE_VILLAGE, 1000, amplifier));
      update.invoke(v, player);
      var row = new JsonArray();
      row.add(amplifier == null ? JsonNull.INSTANCE : new JsonPrimitive(amplifier));
      var rs = new JsonArray();
      for (var o : v.getOffers()) { var a = new JsonArray(); a.add(o.getSpecialPriceDiff()); a.add(o.getCostA().getCount()); rs.add(a); }
      row.add(rs);
      out.add(row);
    }
    return out;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    HolderLookup.Provider lookup = WorldgenFactsOracle.loadRegistries(List.of());
    if (args[0].equals("facts")) {
      MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
      try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
          List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
        MobAiOracle.bind(resources, BuiltInRegistries.POINT_OF_INTEREST_TYPE);
      }
      Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().serializeNulls().create().toJson(facts(lookup)) + "\n");
      System.out.println("PASS: village facts written");
      return;
    }
    if (args[0].equals("cases")) {
      var out = cases(MobAiOracle.setup(), lookup);
      Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().disableHtmlEscaping().serializeNulls().create().toJson(out));
      System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla village traces (villagers idle, at night and in the morning, at a job site, meeting, panicking; golems).");
      return;
    }
    throw new IllegalArgumentException("usage: VillageOracle facts|cases OUT.json");
  }
}
