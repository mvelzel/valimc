import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.SimpleContainer;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.saveddata.maps.MapId;
import net.minecraft.world.level.saveddata.maps.MapItemSavedData;
import net.minecraft.world.level.storage.loot.*;
import net.minecraft.world.level.storage.loot.parameters.*;
import net.minecraft.world.phys.Vec3;

/**
 * Vanilla's container loot tables (VMC-072a), from the vanilla data pack as a server loads them
 * (static registries' tags first, then the world registries, then the reloadable ones).
 *
 * Usage: LootOracle facts TABLES.json REGISTRIES.json — the loot tables containers name (chests,
 * barrels, dispensers, archaeology, decorated pots) and every table they nest, each as vanilla's
 * codec encodes it; and what evaluating them reads: per enchantment in registry order its weight,
 * levels, costs, supported and primary items and exclusive set (resolved), per item its stack
 * size, damage, damageability and enchantability, the instantaneous mob effects, and the
 * enchantment, instrument, biome, structure and item tags.
 *
 * The facts also hold the modelled mobs' entity tables (VMC-037n, `ENTITY_TABLES`).
 *
 * Usage: LootOracle cases OUT.json — per container table, many seeds, luck values and loot origin
 * biomes: the container vanilla's `LootTable.fill` makes (`unpackLootTable` with the stored seed;
 * 27 slots for chests and barrels, 9 for dispensers, 1 for decorated pots) or, for archaeology,
 * the items `getRandomItems` gives a brushable block. Each slot holds the item as its persistent
 * codec writes it. The level answers the loot origin's biome from the case and finds map
 * structures by a fixed rule of the case (no structure for every third seed, else a position
 * from the seed), allocating map ids from 0 per case. Per entity table, many seeds and deaths:
 * the drops `dropFromLootTable` makes (`getRandomItems` with the seed) for a victim on fire or
 * not, a baby or not, riding nothing, a zombie horse or a chicken, killed by a player or not,
 * by an attacker holding nothing or a sword with Looting or Fire Aspect.
 */
public class LootOracle {
  static final List<String> CONTAINER_DIRS = List.of("chests/", "barrels/", "dispensers/", "archaeology/", "pots/");
  static final List<String> ENTITY_TABLES = List.of("minecraft:entities/zombie");

  /** A dying mob: its flags and vehicle as the loot predicates read them. */
  static class Victim extends net.minecraft.world.entity.monster.zombie.Zombie {
    boolean fire, baby;
    net.minecraft.world.entity.Entity vehicle;
    private Victim() { super(null, null); }
    @Override public boolean isOnFire() { return fire; }
    @Override public boolean isBaby() { return baby; }
    @Override public net.minecraft.world.entity.Entity getVehicle() { return vehicle; }
    @Override public boolean isPassenger() { return vehicle != null; }
  }

  /** The killing player, holding `weapon`. */
  static class Attacker extends net.minecraft.world.entity.player.Player {
    ItemStack weapon;
    private Attacker() { super(null, null); }
    @Override public ItemStack getItemBySlot(net.minecraft.world.entity.EquipmentSlot slot) {
      return slot == net.minecraft.world.entity.EquipmentSlot.MAINHAND ? weapon : ItemStack.EMPTY;
    }
    @Override public float getLuck() { return 0.0F; }
    @Override public net.minecraft.world.level.GameType gameMode() { return net.minecraft.world.level.GameType.SURVIVAL; }
  }

  static class ProbeServer extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    @Override public ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
  }

  static class ProbeLevel extends ServerLevel {
    ProbeServer server;
    RegistryAccess access;
    Holder<Biome> biome;
    BlockPos destination;
    int nextMap;
    final Map<MapId, MapItemSavedData> maps = new HashMap<>();
    net.minecraft.world.item.crafting.RecipeManager recipes;
    @Override public net.minecraft.world.item.crafting.RecipeManager recipeAccess() { return recipes; }
    private ProbeLevel() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public MinecraftServer getServer() { return server; }
    @Override public RegistryAccess registryAccess() { return access; }
    @Override public FeatureFlagSet enabledFeatures() { return FeatureFlags.DEFAULT_FLAGS; }
    @Override public Holder<Biome> getBiome(BlockPos pos) { return biome; }
    @Override public boolean isLoaded(BlockPos pos) { return true; }
    @Override public int getSeaLevel() { return 63; }
    @Override public net.minecraft.world.level.StructureManager structureManager() {
      // Claiming a structure at the loot origin finds none.
      return new net.minecraft.world.level.StructureManager(this, null, null) {
        @Override public net.minecraft.world.level.levelgen.structure.StructureStart getStructureAt(BlockPos pos, HolderSet<Structure> structures) {
          return net.minecraft.world.level.levelgen.structure.StructureStart.INVALID_START;
        }
      };
    }
    @Override public BlockPos findNearestMapStructure(HolderSet<Structure> structures, BlockPos origin, int radius, boolean createReference) {
      return destination;
    }
    @Override public MapId getFreeMapId() { return new MapId(nextMap++); }
    @Override public MapItemSavedData getMapData(MapId id) { return maps.get(id); }
    @Override public void setMapData(MapId id, MapItemSavedData data) { maps.put(id, data); }
  }

  public static void main(String[] args) throws Exception {
    var base = MiningToolOracle.initialize();
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA, List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      // As `WorldLoader` loads them: static registries' tags, world registries, then reloadable ones.
      var layered = RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, layered.getLayer(RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(layered.getAccessForLoading(RegistryLayer.WORLD), pending);
      var world = net.minecraft.resources.RegistryDataLoader.load(resources, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(Registry.PendingTags::apply);
      var worldContext = Stream.concat(context.stream(), world.listRegistries()).toList();
      var reloadable = net.minecraft.resources.RegistryDataLoader.load(resources, worldContext,
          net.minecraft.resources.RegistryDataLoader.RELOADABLE_REGISTRIES, Runnable::run).join();
      var lookup = HolderLookup.Provider.create(Stream.concat(worldContext.stream(), reloadable.listRegistries()));
      // Item defaults bind to the loaded registries, as `ReloadableServerResources` binds them,
      // so a rolled holder equal to the default (a ponder goat horn) leaves no patch.
      BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
      var access = new RegistryAccess.ImmutableRegistryAccess(Stream.concat(
          Stream.of(BuiltInRegistries.REGISTRY).flatMap(r -> r.stream().map(x -> (Registry<?>) x)),
          Stream.concat(world.registries().map(e -> e.value()), reloadable.registries().map(e -> e.value()))).toList())
          .freeze();
      var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
      var tables = lookup.lookupOrThrow(Registries.LOOT_TABLE);
      if (args[0].equals("facts")) {
        facts(args, tables, lookup, ops);
        return;
      }
      var server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
      server.registries = new ReloadableServerRegistries.Holder(lookup);
      var level = (ProbeLevel) unsafe.allocateInstance(ProbeLevel.class);
      level.server = server;
      level.access = access;
      var maps = ProbeLevel.class.getDeclaredField("maps");
      maps.setAccessible(true);
      maps.set(level, new HashMap<MapId, MapItemSavedData>());
      // `furnace_smelt` asks the level's recipes.
      level.recipes = new net.minecraft.world.item.crafting.RecipeManager(lookup);
      cases(Path.of(args[1]), tables, lookup, ops, level);
    }
  }

  static List<ResourceKey<LootTable>> containerTables(HolderLookup.RegistryLookup<LootTable> tables) {
    return tables.listElementIds()
        .filter(k -> CONTAINER_DIRS.stream().anyMatch(d -> k.identifier().getPath().startsWith(d)))
        .sorted(Comparator.comparing(k -> k.identifier().toString())).toList();
  }

  static void facts(String[] args, HolderLookup.RegistryLookup<LootTable> tables, HolderLookup.Provider lookup,
      com.mojang.serialization.DynamicOps<JsonElement> ops) throws Exception {
    // The container tables and, transitively, the tables they name.
    var out = new TreeMap<String, JsonElement>();
    var queue = new ArrayDeque<String>();
    containerTables(tables).forEach(k -> queue.add(k.identifier().toString()));
    queue.addAll(ENTITY_TABLES);
    while (!queue.isEmpty()) {
      var id = queue.poll();
      if (out.containsKey(id)) continue;
      var table = tables.getOrThrow(ResourceKey.create(Registries.LOOT_TABLE, Identifier.parse(id))).value();
      var json = LootTable.DIRECT_CODEC.encodeStart(ops, table).getOrThrow();
      out.put(id, WorldgenFactsOracle.widenFloats(json));
      nested(json, queue);
    }
    var tablesOut = new JsonObject();
    out.forEach(tablesOut::add);
    Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(tablesOut) + "\n");

    var registries = new JsonObject();
    var enchantments = new JsonArray();
    var items = lookup.lookupOrThrow(Registries.ITEM);
    lookup.lookupOrThrow(Registries.ENCHANTMENT).listElements().forEach(holder -> {
      var e = holder.value();
      var d = e.definition();
      var row = new JsonObject();
      row.addProperty("id", holder.key().identifier().toString());
      row.addProperty("weight", d.weight());
      row.addProperty("max_level", d.maxLevel());
      row.add("min_cost", cost(d.minCost()));
      row.add("max_cost", cost(d.maxCost()));
      row.add("supported_items", itemNames(d.supportedItems()));
      d.primaryItems().ifPresent(p -> row.add("primary_items", itemNames(p)));
      var exclusive = new JsonArray();
      e.exclusiveSet().forEach(h -> exclusive.add(h.unwrapKey().orElseThrow().identifier().toString()));
      row.add("exclusive_set", exclusive);
      enchantments.add(row);
    });
    registries.add("enchantments", enchantments);
    var itemRows = new JsonArray();
    BuiltInRegistries.ITEM.forEach(item -> {
      var stack = new ItemStack(item);
      var row = new JsonArray();
      row.add(BuiltInRegistries.ITEM.getKey(item).toString());
      row.add(stack.getMaxStackSize());
      row.add(stack.getOrDefault(DataComponents.MAX_DAMAGE, 0));
      row.add(stack.isDamageableItem());
      var enchantable = stack.get(DataComponents.ENCHANTABLE);
      row.add(enchantable == null ? 0 : enchantable.value());
      itemRows.add(row);
    });
    registries.add("items", itemRows);
    var instantaneous = new JsonArray();
    BuiltInRegistries.MOB_EFFECT.forEach(effect -> {
      if (effect.isInstantaneous()) instantaneous.add(BuiltInRegistries.MOB_EFFECT.getKey(effect).toString());
    });
    registries.add("instantaneous_effects", instantaneous);
    var tags = new JsonObject();
    // Item tags in the order a tag iterates (tag entries pick from them by index).
    for (var key : List.of(Registries.ENCHANTMENT, Registries.INSTRUMENT, Registries.BIOME, Registries.STRUCTURE,
        Registries.ITEM)) {
      var byTag = new TreeMap<String, JsonArray>();
      lookup.lookupOrThrow(key).listTags().forEach(named -> {
        var list = new JsonArray();
        named.forEach(h -> list.add(h.unwrapKey().orElseThrow().identifier().toString()));
        byTag.put(named.key().location().toString(), list);
      });
      var group = new JsonObject();
      byTag.forEach(group::add);
      tags.add(key.identifier().toString(), group);
    }
    registries.add("tags", tags);
    Files.writeString(Path.of(args[2]), new GsonBuilder().create().toJson(registries) + "\n");
    System.out.println("PASS: " + out.size() + " loot tables (" + containerTables(tables).size() + " named by containers), "
        + enchantments.size() + " enchantments, " + itemRows.size() + " items");
  }

  static JsonObject cost(Enchantment.Cost cost) {
    var o = new JsonObject();
    o.addProperty("base", cost.base());
    o.addProperty("per_level_above_first", cost.perLevelAboveFirst());
    return o;
  }

  static JsonArray itemNames(HolderSet<Item> set) {
    var list = new JsonArray();
    set.forEach(h -> list.add(BuiltInRegistries.ITEM.getKey(h.value()).toString()));
    return list;
  }

  /** Tables a table's encoding names in loot table entries. */
  static void nested(JsonElement element, Deque<String> queue) {
    if (element.isJsonArray()) {
      element.getAsJsonArray().forEach(e -> nested(e, queue));
    } else if (element.isJsonObject()) {
      var o = element.getAsJsonObject();
      if (o.has("type") && o.get("type").isJsonPrimitive() && o.get("type").getAsString().equals("minecraft:loot_table")
          && o.has("value")) {
        var v = o.get("value");
        if (v.isJsonPrimitive()) queue.add(v.getAsString());
        else if (v.isJsonArray()) v.getAsJsonArray().forEach(x -> { if (x.isJsonPrimitive()) queue.add(x.getAsString()); });
      }
      o.entrySet().forEach(e -> nested(e.getValue(), queue));
    }
  }

  /** The case rule for map structure searches: none for every third seed, else from the seed. */
  static BlockPos destination(long seed) {
    if (Math.floorMod(seed, 3L) == 0) return null;
    return new BlockPos((int) Math.floorMod(seed, 4001L) - 2000, 64, (int) Math.floorMod(seed / 4001L, 4001L) - 2000);
  }

  static final List<String> BIOMES = List.of("minecraft:plains", "minecraft:sulfur_caves", "minecraft:bamboo_jungle",
      "minecraft:desert", "minecraft:deep_dark");

  static void cases(Path out, HolderLookup.RegistryLookup<LootTable> tables, HolderLookup.Provider lookup,
      com.mojang.serialization.DynamicOps<JsonElement> ops, ProbeLevel level) throws Exception {
    var biomes = lookup.lookupOrThrow(Registries.BIOME);
    var random = new Random(20261021L);
    var rows = new JsonArray();
    int fills = 0, items = 0;
    for (var key : containerTables(tables)) {
      var path = key.identifier().getPath();
      var table = tables.getOrThrow(key).value();
      int size = path.startsWith("dispensers/") || path.equals("chests/jungle_temple_dispenser") ? 9 : path.startsWith("pots/") ? 1 : 27;
      boolean brushable = path.startsWith("archaeology/");
      for (int i = 0; i < 40; i++) {
        long seed = random.nextLong();
        float luck = i < 30 ? 0.0F : (i % 2 == 0 ? 1.5F : -1.0F);
        var biome = BIOMES.get(i % BIOMES.size());
        int x = random.nextInt(2001) - 1000, y = random.nextInt(321) - 64, z = random.nextInt(2001) - 1000;
        level.biome = biomes.getOrThrow(ResourceKey.create(Registries.BIOME, Identifier.parse(biome)));
        level.destination = destination(seed);
        level.nextMap = 0;
        level.maps.clear();
        var params = new LootParams.Builder(level).withParameter(LootContextParams.ORIGIN, Vec3.atCenterOf(new BlockPos(x, y, z)))
            .withLuck(luck);
        var slots = new JsonArray();
        if (brushable) {
          // Brushing passes the player and the brush, which archaeology tables do not read; the
          // vault set takes the same origin without requiring them.
          var list = table.getRandomItems(params.create(LootContextParamSets.VAULT), seed);
          for (var stack : list) slots.add(item(stack, ops));
          items += list.size();
        } else {
          var container = new SimpleContainer(size);
          table.fill(container, params.create(LootContextParamSets.CHEST), seed);
          for (int s = 0; s < size; s++) {
            var stack = container.getItem(s);
            slots.add(stack.isEmpty() ? JsonNull.INSTANCE : item(stack, ops));
            if (!stack.isEmpty()) items++;
          }
        }
        var row = new JsonObject();
        row.addProperty("table", key.identifier().toString());
        row.addProperty("seed", Long.toString(seed));
        row.addProperty("luck", luck);
        row.addProperty("biome", biome);
        var origin = new JsonArray();
        origin.add(x);
        origin.add(y);
        origin.add(z);
        row.add("origin", origin);
        row.addProperty("size", brushable ? 0 : size);
        row.add("slots", slots);
        rows.add(row);
        fills++;
      }
    }
    // Entry kinds and modifier nesting no container table of the pack uses: synthetic tables
    // decoded by vanilla's codec, written back in the facts' form, and filled the same way.
    var synthetic = new JsonObject();
    for (var entry : SYNTHETIC.entrySet()) {
      var table = LootTable.DIRECT_CODEC.parse(ops, JsonParser.parseString(entry.getValue())).getOrThrow();
      synthetic.add(entry.getKey(), WorldgenFactsOracle.widenFloats(LootTable.DIRECT_CODEC.encodeStart(ops, table).getOrThrow()));
      for (int i = 0; i < 200; i++) {
        long seed = random.nextLong();
        float luck = i % 4 == 3 ? 2.0F : 0.0F;
        var container = new SimpleContainer(27);
        table.fill(container, new LootParams.Builder(level).withParameter(LootContextParams.ORIGIN, Vec3.ZERO)
            .withLuck(luck).create(LootContextParamSets.CHEST), seed);
        var slots = new JsonArray();
        for (int s = 0; s < 27; s++) {
          var stack = container.getItem(s);
          slots.add(stack.isEmpty() ? JsonNull.INSTANCE : item(stack, ops));
          if (!stack.isEmpty()) items++;
        }
        var row = new JsonObject();
        row.addProperty("table", entry.getKey());
        row.addProperty("seed", Long.toString(seed));
        row.addProperty("luck", luck);
        row.addProperty("biome", "minecraft:plains");
        var origin = new JsonArray();
        origin.add(-1);
        origin.add(-1);
        origin.add(-1);
        row.add("origin", origin);
        row.addProperty("size", 27);
        row.add("slots", slots);
        rows.add(row);
        fills++;
      }
    }
    var deaths = entityCases(tables, lookup, ops, level, random);
    var result = new JsonObject();
    result.add("synthetic_tables", synthetic);
    result.add("cases", rows);
    result.add("entity_cases", deaths);
    Files.writeString(out, new Gson().toJson(result));
    System.out.println("PASS: " + fills + " vanilla container fills over " + containerTables(tables).size() + " pack and "
        + SYNTHETIC.size() + " synthetic tables (" + items + " stacks)");
  }

  static JsonArray entityCases(HolderLookup.RegistryLookup<LootTable> tables, HolderLookup.Provider lookup,
      com.mojang.serialization.DynamicOps<JsonElement> ops, ProbeLevel level, Random random) throws Exception {
    var f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) f.get(null);
    var type = net.minecraft.world.entity.Entity.class.getDeclaredField("type");
    type.setAccessible(true);
    var position = net.minecraft.world.entity.Entity.class.getDeclaredField("position");
    position.setAccessible(true);
    var enchantments = lookup.lookupOrThrow(Registries.ENCHANTMENT);
    var damage = lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(net.minecraft.world.damagesource.DamageTypes.PLAYER_ATTACK);
    var vehicles = Arrays.asList(null, "minecraft:zombie_horse", "minecraft:chicken");
    var rows = new JsonArray();
    for (var id : ENTITY_TABLES) {
      var table = tables.getOrThrow(ResourceKey.create(Registries.LOOT_TABLE, Identifier.parse(id))).value();
      for (int i = 0; i < 1500; i++) {
        long seed = random.nextLong();
        var victim = (Victim) unsafe.allocateInstance(Victim.class);
        type.set(victim, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:zombie")));
        var at = new Vec3(random.nextInt(2001) - 1000.5, random.nextInt(321) - 64, random.nextInt(2001) - 1000.5);
        position.set(victim, at);
        victim.fire = random.nextInt(4) == 0;
        victim.baby = random.nextInt(4) == 0;
        var vehicleName = vehicles.get(random.nextInt(3));
        if (vehicleName != null) {
          var vehicle = (Victim) unsafe.allocateInstance(Victim.class);
          type.set(vehicle, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(vehicleName)));
          position.set(vehicle, at);
          victim.vehicle = vehicle;
        }
        boolean player = random.nextInt(3) != 0;
        var weapon = switch (random.nextInt(5)) {
          case 0 -> ItemStack.EMPTY;
          case 1 -> new ItemStack(Items.DIAMOND_SWORD);
          case 2, 3 -> enchanted(Items.IRON_SWORD, enchantments, Enchantments.LOOTING, 1 + random.nextInt(3));
          default -> enchanted(Items.GOLDEN_SWORD, enchantments, Enchantments.FIRE_ASPECT, 1 + random.nextInt(2));
        };
        var attacker = (Attacker) unsafe.allocateInstance(Attacker.class);
        type.set(attacker, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:player")));
        position.set(attacker, at);
        attacker.weapon = weapon;
        var source = new net.minecraft.world.damagesource.DamageSource(damage, attacker);
        var builder = new LootParams.Builder(level)
            .withParameter(LootContextParams.THIS_ENTITY, victim)
            .withParameter(LootContextParams.ORIGIN, at)
            .withParameter(LootContextParams.DAMAGE_SOURCE, source)
            .withOptionalParameter(LootContextParams.ATTACKING_ENTITY, attacker)
            .withOptionalParameter(LootContextParams.DIRECT_ATTACKING_ENTITY, attacker);
        if (player) builder = builder.withParameter(LootContextParams.LAST_DAMAGE_PLAYER, attacker).withLuck(0.0F);
        var drops = new JsonArray();
        table.getRandomItems(builder.create(LootContextParamSets.ENTITY), seed).forEach(stack -> { if (!stack.isEmpty()) drops.add(item(stack, ops)); });
        var row = new JsonObject();
        row.addProperty("table", id);
        row.addProperty("seed", Long.toString(seed));
        row.addProperty("on_fire", victim.fire);
        row.addProperty("baby", victim.baby);
        if (vehicleName != null) row.addProperty("vehicle", vehicleName);
        row.addProperty("killed_by_player", player);
        row.add("weapon", weapon.isEmpty() ? JsonNull.INSTANCE : item(weapon, ops));
        var origin = new JsonArray();
        origin.add(at.x);
        origin.add(at.y);
        origin.add(at.z);
        row.add("origin", origin);
        row.add("drops", drops);
        rows.add(row);
      }
    }
    return rows;
  }

  static ItemStack enchanted(Item item, HolderLookup.RegistryLookup<Enchantment> enchantments,
      ResourceKey<Enchantment> enchantment, int level) {
    var stack = new ItemStack(item);
    stack.enchant(enchantments.getOrThrow(enchantment), level);
    return stack;
  }

  static final Map<String, String> SYNTHETIC = new LinkedHashMap<>();
  static {
    SYNTHETIC.put("valimc:test/tags", """
      {"pools": [{"rolls": {"type": "minecraft:uniform", "min": 2, "max": 6}, "entries": [
        {"type": "minecraft:tag", "items": "#minecraft:planks", "expand": true, "weight": 2, "quality": 1,
         "modifier": {"type": "minecraft:set_count", "count": {"type": "minecraft:uniform", "min": 1, "max": 5}}},
        {"type": "minecraft:tag", "items": "#minecraft:wool", "weight": 1, "quality": -1},
        {"type": "minecraft:tag", "items": ["minecraft:stone", "minecraft:dirt"], "expand": true, "weight": 3}]}]}
      """);
    SYNTHETIC.put("valimc:test/composites", """
      {"pools": [{"rolls": {"type": "minecraft:uniform", "min": 3, "max": 8}, "bonus_rolls": 1.5, "entries": [
        {"type": "minecraft:alternatives",
         "modifier": {"type": "minecraft:set_count", "count": 3, "add": true},
         "children": [
           {"type": "minecraft:item", "name": "minecraft:diamond",
            "condition": {"type": "minecraft:random_chance", "chance": 0.3},
            "modifier": {"type": "minecraft:set_count", "count": 2}},
           {"type": "minecraft:item", "name": "minecraft:emerald",
            "condition": {"type": "minecraft:inverted", "term": {"type": "minecraft:random_chance", "chance": 0.5}}},
           {"type": "minecraft:tag", "items": "#minecraft:logs", "expand": true, "weight": 2}]},
        {"type": "minecraft:sequence", "children": [
           {"type": "minecraft:item", "name": "minecraft:apple", "condition": {"type": "minecraft:random_chance", "chance": 0.7}},
           {"type": "minecraft:item", "name": "minecraft:bread", "condition": {"type": "minecraft:random_chance", "chance": 0.6}},
           {"type": "minecraft:item", "name": "minecraft:cake"}]},
        {"type": "minecraft:group",
         "condition": {"type": "minecraft:any_of", "terms": [
           {"type": "minecraft:random_chance", "chance": 0.4},
           {"type": "minecraft:all_of", "terms": [{"type": "minecraft:random_chance", "chance": 0.5},
             {"type": "minecraft:random_chance", "chance": 0.5}]}]},
         "children": [
           {"type": "minecraft:item", "name": "minecraft:arrow", "weight": 2,
            "modifier": {"type": "minecraft:set_count", "count": {"type": "minecraft:uniform", "min": 10, "max": 70}}},
           {"type": "minecraft:dynamic", "name": "minecraft:contents"},
           {"type": "minecraft:group", "children": [
             {"type": "minecraft:sequence", "children": [
               {"type": "minecraft:alternatives", "children": [
                 {"type": "minecraft:item", "name": "minecraft:bone", "quality": 3,
                  "condition": {"type": "minecraft:random_chance", "chance": 0.5}},
                 {"type": "minecraft:empty", "weight": 2}]},
               {"type": "minecraft:loot_table", "value": "minecraft:chests/simple_dungeon", "weight": 1}]}]}]},
        {"type": "minecraft:alternatives", "children": []},
        {"type": "minecraft:empty", "weight": 1}]}]}
      """);
  }

  static JsonElement item(ItemStack stack, com.mojang.serialization.DynamicOps<JsonElement> ops) {
    return ItemStack.CODEC.encodeStart(ops, stack).getOrThrow();
  }
}
