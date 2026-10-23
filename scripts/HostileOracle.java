import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.Stream;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.RegistryLayer;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.world.Difficulty;
import net.minecraft.world.DifficultyInstance;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.Attribute;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.Vec3;

/**
 * The overworld hostiles (VMC-043b). `facts OUT` writes what their families
 * read of vanilla beyond the AI facts: the armour `populateDefaultEquipmentSlots`
 * hands out by slot and material, the default drop chance, each family type's
 * baby dimensions, the villager type of each biome and the professions a
 * zombie villager draws from. `spawns OUT` runs `finalizeSpawn` on fresh mobs
 * over seeded level and mob randoms, at each difficulty and local difficulty,
 * spawn reason and with or without a chicken nearby: their equipment with its
 * enchantments, drop chances, flags, attribute modifiers, health, villager
 * data, the jockey they made and both randoms after. `cases OUT` ticks whole
 * vanilla mobs of the families in scenes (`MobAiOracle.run`) by night or by
 * day, with a scene light (full sky light above each column's top block),
 * the mobs prepared (equipment, babies, loot pickup, fire): each tick also
 * their fire, health, worn and held items and what their hits add.
 */
public class HostileOracle {
  static final List<String> FAMILY = List.of("minecraft:zombie", "minecraft:husk", "minecraft:zombie_villager",
      // VMC-043d.
      "minecraft:zombified_piglin");
  // VMC-043d: the Nether's mobs that spawn with gear or as babies.
  static final List<String> NETHER = List.of("minecraft:piglin");
  // VMC-043b3: the skeletons.
  static final List<String> SKELETONS = List.of("minecraft:skeleton", "minecraft:stray", "minecraft:bogged");
  // VMC-043b4: creepers and spiders.
  static final List<String> CREEPERS_SPIDERS = List.of("minecraft:creeper", "minecraft:spider", "minecraft:cave_spider");
  static final List<String> ATTRIBUTES = List.of("minecraft:follow_range", "minecraft:knockback_resistance",
      "minecraft:spawn_reinforcements", "minecraft:max_health", "minecraft:movement_speed");

  /** The probe level with a chosen difficulty and biome; spawned entities are kept, not added. */
  static class Level extends MobAiOracle.Probe {
    Difficulty difficulty = Difficulty.NORMAL;
    DifficultyInstance local;
    Holder<Biome> biome;
    List<Entity> spawned;
    Level() { }
    public Difficulty getDifficulty() { return difficulty; }
    public DifficultyInstance getCurrentDifficultyAt(BlockPos pos) { return local; }
    public Holder<Biome> getBiome(BlockPos pos) { return biome; }
    public boolean addFreshEntity(Entity e) { spawned.add(e); return true; }
    public void addFreshEntityWithPassengers(Entity e) { e.getSelfAndPassengers().forEach(spawned::add); }
    public boolean tryAddFreshEntityWithPassengers(Entity e) { addFreshEntityWithPassengers(e); return true; }
  }

  /** How a scene's mob starts: its equipment by slot, a baby, loot pickup, fire ticks. */
  record Prep(int index, Map<String, String> equipment, boolean baby, boolean loot, int fire, Set<String> flags) {
    Prep(int index, Map<String, String> equipment, boolean baby, boolean loot, int fire) { this(index, equipment, baby, loot, fire, Set.of()); }
  }

  /** The probe by night or day, lit from the sky above each column's top block. */
  static class Day extends MobAiOracle.Probe {
    boolean day;
    List<Prep> preps = List.of();
    Day() { }
    int sky(BlockPos p) {
      for (var b : blocks.keySet()) if (b.getX() == p.getX() && b.getZ() == p.getZ() && b.getY() >= p.getY()) return 0;
      return 15;
    }
    public boolean hasChunk(int x, int z) { return true; }
    public int getBrightness(net.minecraft.world.level.LightLayer layer, BlockPos p) { return layer == net.minecraft.world.level.LightLayer.SKY ? sky(p) : 0; }
    public int getRawBrightness(BlockPos p, int darken) { return Math.max(sky(p) - darken, 0); }
    public float getLightLevelDependentMagicValue(BlockPos p) { float v = getRawBrightness(p, 0) / 15.0F; return v / (4.0F - 3.0F * v); }
    public boolean canSeeSky(BlockPos p) { return sky(p) >= 15; }
    public boolean isBrightOutside() { return day; }
    // An explosion (a creeper's) is recorded, not run.
    public void explode(Entity source, net.minecraft.world.damagesource.DamageSource damage, net.minecraft.world.level.ExplosionDamageCalculator calc,
        double x, double y, double z, float radius, boolean fire, net.minecraft.world.level.Level.ExplosionInteraction interaction,
        net.minecraft.core.particles.ParticleOptions small, net.minecraft.core.particles.ParticleOptions large,
        net.minecraft.util.random.WeightedList<net.minecraft.core.particles.ExplosionParticleInfo> particles, Holder<net.minecraft.sounds.SoundEvent> sound) {
      if (current == null) return;
      var o = new JsonObject(); o.addProperty("explode", Float.floatToRawIntBits(radius));
      var at = new JsonArray(); at.add(bits(x)); at.add(bits(y)); at.add(bits(z)); o.add("at", at);
      o.addProperty("fire", fire); o.addProperty("interaction", interaction.name().toLowerCase());
      sounds.computeIfAbsent(current, k -> new ArrayList<>()).add(o);
    }
    // A converted mob is discarded, which untracks it as a waypoint.
    net.minecraft.server.waypoints.ServerWaypointManager waypoints;
    public net.minecraft.server.waypoints.ServerWaypointManager getWaypointManager() {
      if (waypoints == null) waypoints = new net.minecraft.server.waypoints.ServerWaypointManager();
      return waypoints;
    }
    void prepare(Mob m, int index) {
      for (var p : preps) if (p.index == index) {
        p.equipment.forEach((slot, item) -> m.setItemSlot(EquipmentSlot.byName(slot), new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(item)))));
        if (p.baby) m.setBaby(true);
        if (p.loot) m.setCanPickUpLoot(true);
        if (p.fire > 0) m.setRemainingFireTicks(p.fire);
        // VMC-043b4: a lit or charged creeper.
        if (m instanceof net.minecraft.world.entity.monster.Creeper c) {
          if (p.flags.contains("ignited")) c.ignite();
          if (p.flags.contains("powered")) {
            try {
              var powered = (net.minecraft.network.syncher.EntityDataAccessor<Boolean>)MobAiOracle.field(net.minecraft.world.entity.monster.Creeper.class, "DATA_IS_POWERED").get(null);
              c.getEntityData().set(powered, true);
            } catch (Exception e) { throw new RuntimeException(e); }
          }
        }
      }
    }
    void record(Mob m, JsonObject r) throws Exception {
      r.addProperty("type", BuiltInRegistries.ENTITY_TYPE.getKey(m.getType()).toString());
      r.addProperty("removed", m.isRemoved());
      r.addProperty("fire", m.getRemainingFireTicks());
      r.addProperty("health", Float.floatToRawIntBits(m.getHealth()));
      var items = new JsonObject();
      for (var slot : EquipmentSlot.VALUES) {
        var stack = m.getItemBySlot(slot);
        if (stack.isEmpty()) continue;
        var row = new JsonArray(); row.add(BuiltInRegistries.ITEM.getKey(stack.getItem()).toString()); row.add(stack.getDamageValue());
        row.add(Float.floatToRawIntBits(m.getDropChances().byEquipment(slot)));
        items.add(slot.getName(), row);
      }
      r.add("equipment", items);
      r.addProperty("can_pick_up_loot", m.canPickUpLoot());
      if (m instanceof net.minecraft.world.entity.monster.zombie.Zombie z) r.addProperty("converting", z.isUnderWaterConverting());
      if (m instanceof net.minecraft.world.entity.monster.skeleton.Skeleton s) r.addProperty("converting", s.isShaking());
      if (m instanceof net.minecraft.world.entity.monster.Creeper c) {
        r.addProperty("swell_dir", c.getSwellDir());
        r.addProperty("swell", MobAiOracle.field(net.minecraft.world.entity.monster.Creeper.class, "swell").getInt(c));
      }
      if (m instanceof net.minecraft.world.entity.monster.spider.Spider s) r.addProperty("climbing", s.isClimbing());
    }
    void scene(JsonObject out) {
      out.addProperty("day", day);
      var ps = new JsonArray();
      for (var p : preps) {
        var o = new JsonObject(); o.addProperty("index", p.index);
        var e = new JsonObject(); p.equipment.forEach(e::addProperty); o.add("equipment", e);
        o.addProperty("baby", p.baby); o.addProperty("loot", p.loot); o.addProperty("fire", p.fire);
        var f = new JsonArray(); p.flags.stream().sorted().forEach(f::add); o.add("flags", f); ps.add(o);
      }
      out.add("prepare", ps);
    }
  }

  static JsonObject run(Day level, String name, boolean day, List<Prep> preps, List<MobAiOracle.Block> blocks, List<MobAiOracle.Spawn> spawns,
      List<MobAiOracle.Stand> stands, List<MobAiOracle.Hit> hits, List<MobAiOracle.Drop> drops, int ticks) throws Exception {
    level.day = day;
    level.preps = preps;
    var env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder();
    if (day) env.addConstantLayer(net.minecraft.world.attribute.EnvironmentAttributes.MONSTERS_BURN, v -> true);
    level.env = env.build();
    return MobAiOracle.run(level, name, blocks, spawns, stands, hits, drops, ticks);
  }

  static JsonObject cases(Day level) throws Exception {
    var stone = Blocks.STONE.defaultBlockState();
    var water = Blocks.WATER.defaultBlockState();
    var floor = MobAiOracle.floor(63, 12, stone);
    var cases = new JsonArray();
    var none = List.<MobAiOracle.Hit>of();
    var noDrops = List.<MobAiOracle.Drop>of();
    // A baby zombie chases a player, faster and smaller.
    cases.add(run(level, "baby_zombie_chase", false, List.of(new Prep(0, Map.of(), true, false, 0)), floor,
        List.of(new MobAiOracle.Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 0, 73L)),
        List.of(new MobAiOracle.Stand(new Vec3(8.5, 64, 4.5), "survival", null)), none, noDrops, 200));
    // By day: one zombie burns in the open, one wears a helmet that wears down,
    // one stands under a roof; a husk never burns.
    var shade = new ArrayList<>(floor);
    shade.addAll(MobAiOracle.box(-10, 67, -10, -6, 67, -6, stone));
    cases.add(run(level, "zombie_daylight", true, List.of(new Prep(1, Map.of("head", "minecraft:iron_helmet"), false, false, 0)), shade,
        List.of(new MobAiOracle.Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 0, 79L),
            new MobAiOracle.Spawn("minecraft:zombie", new Vec3(6.5, 64, -6.5), 90, 83L),
            new MobAiOracle.Spawn("minecraft:zombie", new Vec3(-7.5, 64, -7.5), 180, 89L),
            new MobAiOracle.Spawn("minecraft:husk", new Vec3(7.5, 64, 7.5), 270, 97L)),
        List.of(), none, noDrops, 300));
    // A husk's hits make the player hungry; a burning zombie's may set it alight.
    cases.add(run(level, "husk_hunger", true, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:husk", new Vec3(.5, 64, .5), 0, 101L)),
        List.of(new MobAiOracle.Stand(new Vec3(3.5, 64, 2.5), "survival", null)), none, noDrops, 160));
    cases.add(run(level, "zombie_fire_hit", false, List.of(new Prep(0, Map.of(), false, false, 2000)), floor,
        List.of(new MobAiOracle.Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 0, 103L)),
        List.of(new MobAiOracle.Stand(new Vec3(2.5, 64, 1.5), "survival", null)), none, noDrops, 200));
    // A zombie villager chases like a zombie.
    cases.add(run(level, "zombie_villager_chase", false, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:zombie_villager", new Vec3(.5, 64, .5), 0, 107L)),
        List.of(new MobAiOracle.Stand(new Vec3(-6.5, 64, 5.5), "survival", null)), none, noDrops, 200));
    // One that picks up loot takes a sword and a helmet lying beside it.
    cases.add(run(level, "zombie_pickup", false, List.of(new Prep(0, Map.of(), false, true, 0)), floor,
        List.of(new MobAiOracle.Spawn("minecraft:zombie", new Vec3(.5, 64, .5), 0, 109L)),
        List.of(), none, List.of(new MobAiOracle.Drop(new Vec3(1.2, 64, .5), "minecraft:iron_sword", 1),
            new MobAiOracle.Drop(new Vec3(.5, 64, 1.3), "minecraft:golden_helmet", 1)), 40));
    // A husk under water turns into a zombie (as a zombie into a drowned): 600
    // ticks, then 300 more. (The probe's zombie never converts.)
    var pool = new ArrayList<>(floor);
    pool.addAll(MobAiOracle.box(-3, 63, -3, 3, 63, 3, Blocks.AIR.defaultBlockState()));
    pool.addAll(MobAiOracle.box(-3, 60, -3, 3, 60, 3, stone));
    pool.addAll(MobAiOracle.box(-3, 61, -3, 3, 64, 3, water));
    cases.add(run(level, "husk_drowning", false, List.of(), MobAiOracle.scene(pool),
        List.of(new MobAiOracle.Spawn("minecraft:husk", new Vec3(.5, 61, .5), 0, 113L)),
        List.of(), none, noDrops, 901));
    skeletons(level, cases, floor);
    creepersAndSpiders(level, cases, floor);
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    return out;
  }

  // VMC-043b3: skeletons shooting, in melee, in the sun and freezing; strays and bogged shooting.
  static void skeletons(Day level, JsonArray cases, List<MobAiOracle.Block> floor) throws Exception {
    var stone = Blocks.STONE.defaultBlockState();
    var none = List.<MobAiOracle.Hit>of();
    var noDrops = List.<MobAiOracle.Drop>of();
    var bow = Map.of("mainhand", "minecraft:bow");
    // A skeleton with a bow walks up, circles the player and shoots.
    cases.add(run(level, "skeleton_bow", false, List.of(new Prep(0, bow, false, false, 0)), floor,
        List.of(new MobAiOracle.Spawn("minecraft:skeleton", new Vec3(.5, 64, .5), 0, 127L)),
        List.of(new MobAiOracle.Stand(new Vec3(11.5, 64, 6.5), "survival", null)), none, noDrops, 320));
    // Without a bow it fights in melee.
    cases.add(run(level, "skeleton_melee", false, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:skeleton", new Vec3(.5, 64, .5), 0, 131L)),
        List.of(new MobAiOracle.Stand(new Vec3(5.5, 64, 3.5), "survival", null)), none, noDrops, 160));
    // By day a burning skeleton flees into the shade of a roof.
    var shade = new ArrayList<>(floor);
    shade.addAll(MobAiOracle.box(-9, 67, -9, -4, 67, -4, stone));
    cases.add(run(level, "skeleton_sun", true, List.of(new Prep(0, bow, false, false, 0)), shade,
        List.of(new MobAiOracle.Spawn("minecraft:skeleton", new Vec3(2.5, 64, 2.5), 0, 137L)),
        List.of(), none, noDrops, 300));
    // A stray's and a bogged's arrows; the bogged draws slower.
    cases.add(run(level, "stray_bogged_bow", false,
        List.of(new Prep(0, bow, false, false, 0), new Prep(1, bow, false, false, 0)), MobAiOracle.floor(63, 20, stone),
        List.of(new MobAiOracle.Spawn("minecraft:stray", new Vec3(-12.5, 64, .5), 0, 139L),
            new MobAiOracle.Spawn("minecraft:bogged", new Vec3(12.5, 64, .5), 0, 149L)),
        List.of(new MobAiOracle.Stand(new Vec3(-12.5, 64, 9.5), "survival", null),
            new MobAiOracle.Stand(new Vec3(12.5, 64, -9.5), "survival", null)), none, noDrops, 240));
    // In powder snow a skeleton shakes and becomes a stray.
    var snow = new ArrayList<>(floor);
    snow.addAll(MobAiOracle.box(-2, 64, -2, 2, 65, 2, Blocks.POWDER_SNOW.defaultBlockState()));
    cases.add(run(level, "skeleton_freezing", false, List.of(), MobAiOracle.scene(snow),
        List.of(new MobAiOracle.Spawn("minecraft:skeleton", new Vec3(.5, 64, .5), 0, 151L)),
        List.of(), none, noDrops, 443));
  }

  // VMC-043b4: creepers swelling and exploding (lit, charged), spiders leaping, climbing and shying from light.
  static void creepersAndSpiders(Day level, JsonArray cases, List<MobAiOracle.Block> floor) throws Exception {
    var stone = Blocks.STONE.defaultBlockState();
    var none = List.<MobAiOracle.Hit>of();
    var noDrops = List.<MobAiOracle.Drop>of();
    // A creeper walks up to the player, swells and explodes.
    cases.add(run(level, "creeper_explodes", false, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:creeper", new Vec3(.5, 64, .5), 0, 157L)),
        List.of(new MobAiOracle.Stand(new Vec3(6.5, 64, 4.5), "survival", null)), none, noDrops, 86));
    // A lit creeper and a charged one explode with no target, the charged one twice as hard.
    cases.add(run(level, "creeper_lit_charged", false,
        List.of(new Prep(0, Map.of(), false, false, 0, Set.of("ignited")), new Prep(1, Map.of(), false, false, 0, Set.of("ignited", "powered"))),
        floor, List.of(new MobAiOracle.Spawn("minecraft:creeper", new Vec3(-5.5, 64, .5), 0, 163L),
            new MobAiOracle.Spawn("minecraft:creeper", new Vec3(5.5, 64, .5), 0, 167L)),
        List.of(), none, noDrops, 30));
    // A spider runs at the player, leaps and bites; a cave spider's bite poisons.
    cases.add(run(level, "spider_leap", false, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:spider", new Vec3(.5, 64, .5), 0, 173L)),
        List.of(new MobAiOracle.Stand(new Vec3(7.5, 64, 3.5), "survival", null)), none, noDrops, 200));
    cases.add(run(level, "cave_spider_bite", false, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:cave_spider", new Vec3(.5, 64, .5), 0, 179L)),
        List.of(new MobAiOracle.Stand(new Vec3(4.5, 64, 2.5), "survival", null)), none, noDrops, 160));
    // A spider climbs a wall to the player on top of it.
    var wall = new ArrayList<>(floor);
    wall.addAll(MobAiOracle.box(4, 64, -6, 6, 67, 6, stone));
    cases.add(run(level, "spider_climbs", false, List.of(), MobAiOracle.scene(wall),
        List.of(new MobAiOracle.Spawn("minecraft:spider", new Vec3(.5, 64, .5), 270, 181L)),
        List.of(new MobAiOracle.Stand(new Vec3(5.5, 68, .5), "survival", null)), none, noDrops, 160));
    // By day a spider leaves the player alone.
    cases.add(run(level, "spider_day", true, List.of(), floor,
        List.of(new MobAiOracle.Spawn("minecraft:spider", new Vec3(.5, 64, .5), 0, 191L)),
        List.of(new MobAiOracle.Stand(new Vec3(5.5, 64, 2.5), "survival", null)), none, noDrops, 200));
  }

  static String bits(double d) { return MobAiOracle.bits(d); }

  static long seed(net.minecraft.util.RandomSource random) throws Exception {
    var field = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    return ((java.util.concurrent.atomic.AtomicLong)field.get(random)).get();
  }

  static String id(Holder<?> h) { return h.unwrapKey().orElseThrow().identifier().toString(); }

  // ---- facts ----

  static JsonObject facts(Level level, HolderLookup.Provider lookup, net.minecraft.server.packs.resources.ResourceManager resources) throws Exception {
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    // `Mob.getEquipmentForSlot` by slot and armour material (0 leather .. 5 diamond).
    var armour = new JsonObject();
    for (var slot : List.of(EquipmentSlot.HEAD, EquipmentSlot.CHEST, EquipmentSlot.LEGS, EquipmentSlot.FEET)) {
      var row = new JsonArray();
      for (int type = 0; type <= 5; type++) row.add(BuiltInRegistries.ITEM.getKey(Mob.getEquipmentForSlot(slot, type)).toString());
      armour.add(slot.getName(), row);
    }
    out.add("armour", armour);
    out.addProperty("drop_chance", Float.floatToRawIntBits(DropChances.DEFAULT_EQUIPMENT_DROP_CHANCE));
    // The spawn equipment's enchantments (`VanillaEnchantmentProviders.MOB_SPAWN_EQUIPMENT`).
    var provider = (net.minecraft.world.item.enchantment.providers.EnchantmentsByCostWithDifficulty)lookup
        .lookupOrThrow(Registries.ENCHANTMENT_PROVIDER)
        .getOrThrow(net.minecraft.world.item.enchantment.providers.VanillaEnchantmentProviders.MOB_SPAWN_EQUIPMENT).value();
    var enchanting = new JsonObject();
    enchanting.addProperty("min_cost", provider.minCost()); enchanting.addProperty("max_cost_span", provider.maxCostSpan());
    enchanting.addProperty("tag", provider.enchantments().unwrapKey().orElseThrow().location().toString());
    out.add("spawn_enchanting", enchanting);
    // A baby's dimensions (`getDefaultDimensions` while a baby).
    var babies = new JsonObject();
    var defaultDimensions = LivingEntity.class.getDeclaredMethod("getDefaultDimensions", Pose.class);
    defaultDimensions.setAccessible(true);
    for (var type : java.util.stream.Stream.concat(FAMILY.stream(), NETHER.stream()).toList()) {
      var m = MobAiOracle.mob(type, level);
      m.setBaby(true);
      var d = (net.minecraft.world.entity.EntityDimensions)defaultDimensions.invoke(m, Pose.STANDING);
      var row = new JsonArray(); row.add(Float.floatToRawIntBits(d.width())); row.add(Float.floatToRawIntBits(d.height()));
      row.add(Float.floatToRawIntBits(d.eyeHeight())); babies.add(type, row);
    }
    out.add("babies", babies);
    // The slot each equippable item goes to and the types that may wear it
    // (null: any), as a mob picking up loot reads them.
    var equippable = new JsonObject();
    BuiltInRegistries.ITEM.keySet().stream().sorted(Comparator.comparing(Identifier::toString)).forEach(id -> {
      var e = BuiltInRegistries.ITEM.getValue(id).components().get(net.minecraft.core.component.DataComponents.EQUIPPABLE);
      if (e == null) return;
      var row = new JsonArray(); row.add(e.slot().getName());
      if (e.allowedEntities().isEmpty()) row.add(JsonNull.INSTANCE);
      else { var t = new JsonArray(); e.allowedEntities().get().forEach(h -> t.add(id(h))); row.add(t); }
      row.add(e.equipSound().value().location().toString());
      equippable.add(id.toString(), row);
    });
    out.add("equippable", equippable);
    // The attribute modifiers each effect gives at amplifiers 0 to 3
    // (`MobEffect.createModifiers`): attribute, id, operation and amounts.
    var effectModifiers = new JsonObject();
    for (var effect : BuiltInRegistries.MOB_EFFECT) {
      var rows = new LinkedHashMap<String, JsonArray>();
      for (int amplifier = 0; amplifier <= 3; amplifier++) {
        final int a = amplifier;
        effect.createModifiers(a, (attribute, modifier) -> {
          var key = id(attribute) + "|" + modifier.id();
          var row = rows.computeIfAbsent(key, k -> {
            var r = new JsonArray(); r.add(id(attribute)); r.add(modifier.id().toString()); r.add(modifier.operation().getSerializedName());
            r.add(new JsonArray()); return r;
          });
          row.get(3).getAsJsonArray().add(bits(modifier.amount()));
        });
      }
      if (!rows.isEmpty()) {
        var list = new JsonArray(); rows.values().forEach(list::add);
        effectModifiers.add(BuiltInRegistries.MOB_EFFECT.getKey(effect).toString(), list);
      }
    }
    out.add("effect_modifiers", effectModifiers);
    // The ids of the sounds the hostiles play beyond the AI and combat facts'.
    var soundNames = new TreeSet<String>(List.of("minecraft:entity.creeper.primed",
        "minecraft:item.flintandsteel.use", "minecraft:item.firecharge.use"));
    for (var row : equippable.entrySet()) soundNames.add(row.getValue().getAsJsonArray().get(2).getAsString());
    var sounds = new JsonObject();
    for (var n : soundNames) sounds.addProperty(n, BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(n))));
    out.add("sounds", sounds);
    // When monsters burn (`EnvironmentAttributes.MONSTERS_BURN`): the overworld
    // day timeline's track (its keyframes over the day's period; the
    // dimension's own value is false).
    try (var reader = resources.getResourceOrThrow(Identifier.parse("minecraft:timeline/day.json")).openAsReader()) {
      var day = JsonParser.parseReader(reader).getAsJsonObject();
      var burn = new JsonObject(); burn.addProperty("period", day.get("period_ticks").getAsInt());
      burn.add("keyframes", day.getAsJsonObject("tracks").getAsJsonObject("minecraft:gameplay/monsters_burn").get("keyframes"));
      out.add("monsters_burn", burn);
    }
    // `VillagerType.byBiome`: the biomes whose villagers are not plains'.
    var byBiome = (Map<?, ?>)MobAiOracle.field(net.minecraft.world.entity.npc.villager.VillagerType.class, "BY_BIOME").get(null);
    var types = new TreeMap<String, String>();
    for (var e : byBiome.entrySet())
      types.put(((ResourceKey<?>)e.getKey()).identifier().toString(), ((ResourceKey<?>)e.getValue()).identifier().toString());
    var villagerTypes = new JsonObject(); types.forEach(villagerTypes::addProperty);
    out.add("villager_types", villagerTypes);
    out.addProperty("default_villager_type", net.minecraft.world.entity.npc.villager.VillagerData.DEFAULT_TYPE.identifier().toString());
    // The villager types in registry order (their network ids).
    var villagerTypeIds = new JsonArray();
    for (var t : BuiltInRegistries.VILLAGER_TYPE) villagerTypeIds.add(BuiltInRegistries.VILLAGER_TYPE.getKey(t).toString());
    out.add("villager_type_ids", villagerTypeIds);
    // The professions in registry order (`Registry.getRandom` draws an index; their network ids).
    var professions = new JsonArray();
    for (var p : BuiltInRegistries.VILLAGER_PROFESSION) professions.add(BuiltInRegistries.VILLAGER_PROFESSION.getKey(p).toString());
    out.add("professions", professions);
    return out;
  }

  // ---- spawns ----

  record Setting(Difficulty difficulty, long time, long inhabited, float moon) {}

  static JsonObject equipment(Mob m) {
    var out = new JsonObject();
    for (var slot : EquipmentSlot.VALUES) {
      var stack = m.getItemBySlot(slot);
      if (stack.isEmpty()) continue;
      var row = new JsonObject();
      row.addProperty("item", BuiltInRegistries.ITEM.getKey(stack.getItem()).toString());
      var enchantments = new JsonArray();
      for (var e : stack.getEnchantments().entrySet()) {
        var pair = new JsonArray(); pair.add(id(e.getKey())); pair.add(e.getIntValue()); enchantments.add(pair);
      }
      row.add("enchantments", enchantments);
      out.add(slot.getName(), row);
    }
    return out;
  }

  static JsonObject attributes(Mob m) {
    var out = new JsonObject();
    for (var name : ATTRIBUTES) {
      Holder<Attribute> holder = BuiltInRegistries.ATTRIBUTE.get(Identifier.parse(name)).orElseThrow();
      var instance = m.getAttribute(holder);
      if (instance == null) continue;
      var row = new JsonObject(); row.addProperty("base", bits(instance.getBaseValue()));
      var modifiers = new JsonArray();
      instance.getModifiers().stream().sorted(Comparator.comparing(a -> a.id().toString())).forEach(a -> {
        var mod = new JsonArray(); mod.add(a.id().toString()); mod.add(bits(a.amount())); mod.add(a.operation().getSerializedName());
        modifiers.add(mod);
      });
      row.add("modifiers", modifiers);
      out.add(name, row);
    }
    return out;
  }

  static JsonObject spawn(Level level, String type, Setting s, EntitySpawnReason reason, boolean chicken, String biome,
      long levelSeed, long mobSeed, HolderLookup.Provider lookup) throws Exception {
    level.entities.clear(); level.blocks.clear();
    level.spawned = new ArrayList<>();
    level.difficulty = s.difficulty;
    level.local = new DifficultyInstance(s.difficulty, s.time, s.inhabited, s.moon);
    level.biome = lookup.lookupOrThrow(Registries.BIOME).getOrThrow(ResourceKey.create(Registries.BIOME, Identifier.parse(biome)));
    // A floor, and a roof a camel husk would not fit under (a husk's natural
    // spawn tries for one only where it fits).
    for (int y : new int[]{63, 66})
      for (var b : MobAiOracle.floor(y, 6, Blocks.STONE.defaultBlockState())) level.blocks.put(new BlockPos(b.x(), b.y(), b.z()), b.state());
    var random = (net.minecraft.util.RandomSource)MobAiOracle.field(net.minecraft.world.level.Level.class, "random").get(level);
    random.setSeed(levelSeed);
    var m = MobAiOracle.mob(type, level);
    m.getRandom().setSeed(mobSeed);
    // A zombie villager's profession is drawn as it is made (`defineSynchedData`), from its random.
    if (m instanceof net.minecraft.world.entity.monster.zombie.ZombieVillager zv) {
      var init = zv.getClass().getDeclaredMethod("initializeZombieVillagerData", net.minecraft.util.RandomSource.class);
      init.setAccessible(true);
      var data = (net.minecraft.world.entity.npc.villager.VillagerData)init.invoke(null, zv.getRandom());
      var accessor = (net.minecraft.network.syncher.EntityDataAccessor<net.minecraft.world.entity.npc.villager.VillagerData>)
          MobAiOracle.field(zv.getClass(), "DATA_VILLAGER_DATA").get(null);
      zv.getEntityData().set(accessor, data);
    }
    m.snapTo(0.5, 64, 0.5, 0, 0);
    level.entities.add(m);
    if (chicken) {
      var c = new net.minecraft.world.entity.animal.chicken.Chicken(EntityTypes.CHICKEN, level);
      c.snapTo(2.5, 64, 1.5, 0, 0);
      level.entities.add(c);
    }
    m.finalizeSpawn(level, level.local, reason, null);
    var out = new JsonObject();
    out.addProperty("type", type); out.addProperty("difficulty", s.difficulty.getSerializedName());
    out.addProperty("time", s.time); out.addProperty("inhabited", s.inhabited); out.addProperty("moon", Float.floatToRawIntBits(s.moon));
    out.addProperty("reason", reason.name().toLowerCase()); out.addProperty("chicken", chicken); out.addProperty("biome", biome);
    out.addProperty("level_seed", levelSeed); out.addProperty("mob_seed", mobSeed);
    out.addProperty("halloween", net.minecraft.util.SpecialDates.isHalloween());
    out.add("equipment", equipment(m));
    var chances = new JsonObject();
    for (var slot : EquipmentSlot.VALUES) {
      float c = m.getDropChances().byEquipment(slot);
      if (c != DropChances.DEFAULT_EQUIPMENT_DROP_CHANCE) chances.addProperty(slot.getName(), Float.floatToRawIntBits(c));
    }
    out.add("drop_chances", chances);
    out.addProperty("left_handed", m.isLeftHanded());
    out.addProperty("can_pick_up_loot", m.canPickUpLoot());
    out.addProperty("baby", m.isBaby());
    if (m instanceof net.minecraft.world.entity.monster.zombie.Zombie z) out.addProperty("can_break_doors", z.canBreakDoors());
    // A piglin's first hunt waits (`PiglinAi.initMemories`).
    if (m instanceof net.minecraft.world.entity.monster.piglin.Piglin p)
      out.addProperty("hunted_recently", p.getBrain().getTimeUntilExpiry(net.minecraft.world.entity.ai.memory.MemoryModuleType.HUNTED_RECENTLY));
    out.add("attributes", attributes(m));
    out.addProperty("health", Float.floatToRawIntBits(m.getHealth()));
    if (m instanceof net.minecraft.world.entity.monster.zombie.ZombieVillager zv) {
      var d = zv.getVillagerData();
      var v = new JsonArray(); v.add(id(d.type())); v.add(id(d.profession())); v.add(d.level());
      out.add("villager", v);
    }
    // The vehicle it rides: a chicken that was there, or one it made.
    var vehicle = m.getVehicle();
    out.addProperty("jockey", vehicle == null ? null : level.spawned.contains(vehicle) ? "new" : "existing");
    var spawned = new JsonArray(); for (var e : level.spawned) spawned.add(BuiltInRegistries.ENTITY_TYPE.getKey(e.getType()).toString());
    out.add("spawned", spawned);
    out.addProperty("level_seed_after", seed(random));
    out.addProperty("mob_seed_after", seed(m.getRandom()));
    // Then a death (`dropCustomDeathLoot`): by a player with or without a
    // Looting sword, or by no player; what equipment drops, worn.
    var killer = new MobAiOracle.Fighter(level, 1, net.minecraft.world.level.GameType.SURVIVAL);
    int looting = (int)(Math.abs(levelSeed) % 3);
    var sword = new ItemStack(net.minecraft.world.item.Items.IRON_SWORD);
    if (looting > 0) sword.enchant(lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(net.minecraft.world.item.enchantment.Enchantments.LOOTING), looting);
    killer.setItemSlot(EquipmentSlot.MAINHAND, sword);
    boolean byPlayer = Math.abs(mobSeed) % 4 != 0;
    level.spawned.clear();
    var drop = Mob.class.getDeclaredMethod("dropCustomDeathLoot", net.minecraft.server.level.ServerLevel.class, net.minecraft.world.damagesource.DamageSource.class, boolean.class);
    drop.setAccessible(true);
    drop.invoke(m, level, level.damageSources().playerAttack(killer), byPlayer);
    var drops = new JsonArray();
    for (var e : level.spawned) if (e instanceof net.minecraft.world.entity.item.ItemEntity item) {
      var row = new JsonArray(); row.add(BuiltInRegistries.ITEM.getKey(item.getItem().getItem()).toString()); row.add(item.getItem().getDamageValue()); drops.add(row);
    }
    var death = new JsonObject(); death.addProperty("looting", looting); death.addProperty("by_player", byPlayer);
    death.add("drops", drops); death.addProperty("mob_seed_after", seed(m.getRandom()));
    out.add("death", death);
    return out;
  }

  static JsonObject spawns(Level level, HolderLookup.Provider lookup) throws Exception {
    // Local difficulty from a fresh world, a middling one and a full one (special multiplier 1).
    var settings = new ArrayList<Setting>();
    for (var d : List.of(Difficulty.EASY, Difficulty.NORMAL, Difficulty.HARD)) {
      settings.add(new Setting(d, 0L, 0L, 0.0F));
      settings.add(new Setting(d, 900_000L, 1_200_000L, 0.5F));
      settings.add(new Setting(d, 3_000_000L, 4_000_000L, 1.0F));
    }
    var biomes = List.of("minecraft:plains", "minecraft:desert", "minecraft:snowy_plains", "minecraft:swamp");
    var cases = new JsonArray();
    var picker = new Random(43L);
    for (var type : java.util.stream.Stream.of(FAMILY, NETHER, SKELETONS, CREEPERS_SPIDERS).flatMap(List::stream).toList())
      for (var s : settings)
        for (int i = 0; i < 120; i++) {
          var reason = i % 10 == 9 ? EntitySpawnReason.SPAWNER
              : i % 10 == 8 && NETHER.contains(type) ? EntitySpawnReason.STRUCTURE : EntitySpawnReason.NATURAL;
          cases.add(spawn(level, type, s, reason, i % 2 == 0, biomes.get(picker.nextInt(biomes.size())),
              picker.nextLong(), picker.nextLong(), lookup));
        }
    var out = new JsonObject(); out.addProperty("version", "26.3"); out.add("cases", cases);
    return out;
  }

  public static void main(String[] args) throws Exception {
    if (args[0].equals("cases")) {
      var level = MobAiOracle.setup(Day.class);
      var out = cases(level);
      Files.writeString(Path.of(args[1]), new GsonBuilder().disableHtmlEscaping().serializeNulls().create().toJson(out));
      System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla hostile traces (zombies: baby, daylight, husk, fire, villager, pickup, drowning; skeletons: bow, melee, sun, stray, bogged, freezing; creepers, spiders).");
      return;
    }
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA, List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      // The registries with their tags, as `WorldLoader` loads them (as `LootOracle` does).
      var layered = RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, layered.getLayer(RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(layered.getAccessForLoading(RegistryLayer.WORLD), pending);
      var world = net.minecraft.resources.RegistryDataLoader.load(resources, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(Registry.PendingTags::apply);
      var lookup = HolderLookup.Provider.create(Stream.concat(context.stream(), world.listRegistries()));
      BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
      var access = new RegistryAccess.ImmutableRegistryAccess(Stream.concat(
          Stream.of(BuiltInRegistries.REGISTRY).flatMap(r -> r.stream().map(x -> (Registry<?>)x)),
          world.registries().map(e -> e.value())).toList()).freeze();
      var level = MobAiOracle.probe(Level.class, lookup, access, null);
      level.sources = new DamageSources(access);
      var json = new GsonBuilder().disableHtmlEscaping().serializeNulls();
      switch (args[0]) {
        case "facts" -> {
          Files.writeString(Path.of(args[1]), json.setPrettyPrinting().create().toJson(facts(level, lookup, resources)) + "\n");
          System.out.println("PASS: hostile facts written");
        }
        case "spawns" -> {
          var out = spawns(level, lookup);
          Files.writeString(Path.of(args[1]), json.create().toJson(out));
          System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla finalizeSpawn results (zombie family, piglins, skeletons).");
        }
        default -> throw new IllegalArgumentException("usage: HostileOracle facts|spawns|cases OUT.json");
      }
    }
  }
}
