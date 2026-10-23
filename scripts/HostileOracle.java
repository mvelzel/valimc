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
 * data, the jockey they made and both randoms after.
 */
public class HostileOracle {
  static final List<String> FAMILY = List.of("minecraft:zombie", "minecraft:husk", "minecraft:zombie_villager",
      // VMC-043d.
      "minecraft:zombified_piglin");
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
    for (var type : FAMILY) {
      var m = (net.minecraft.world.entity.monster.zombie.Zombie)MobAiOracle.mob(type, level);
      m.setBaby(true);
      var d = m.getDefaultDimensions(Pose.STANDING);
      var row = new JsonArray(); row.add(Float.floatToRawIntBits(d.width())); row.add(Float.floatToRawIntBits(d.height()));
      row.add(Float.floatToRawIntBits(d.eyeHeight())); babies.add(type, row);
    }
    out.add("babies", babies);
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
    if (m instanceof net.minecraft.world.entity.monster.zombie.Zombie z) {
      out.addProperty("baby", z.isBaby());
      out.addProperty("can_break_doors", z.canBreakDoors());
    }
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
    for (var type : FAMILY)
      for (var s : settings)
        for (int i = 0; i < 120; i++) {
          var reason = i % 10 == 9 ? EntitySpawnReason.SPAWNER : EntitySpawnReason.NATURAL;
          cases.add(spawn(level, type, s, reason, i % 2 == 0, biomes.get(picker.nextInt(biomes.size())),
              picker.nextLong(), picker.nextLong(), lookup));
        }
    var out = new JsonObject(); out.addProperty("version", "26.3"); out.add("cases", cases);
    return out;
  }

  public static void main(String[] args) throws Exception {
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
          System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla finalizeSpawn results (zombie family).");
        }
        default -> throw new IllegalArgumentException("usage: HostileOracle facts|spawns OUT.json");
      }
    }
  }
}
