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
 * Usage: LootOracle facts TABLES.json REGISTRIES.json BLOCKS.json — the loot tables containers name (chests,
 * barrels, dispensers, archaeology, decorated pots) and every table they nest, each as vanilla's
 * codec encodes it; and what evaluating them reads: per enchantment in registry order its weight,
 * levels, costs, supported and primary items and exclusive set (resolved), per item its stack
 * size, damage, damageability and enchantability, the instantaneous mob effects, and the
 * enchantment, instrument, biome, structure, item and entity type tags.
 *
 * The facts also hold the modelled mobs' entity tables (VMC-037n, `ENTITY_TABLES`), every block's
 * table and the named predicates conditions refer to (VMC-029e), and the block-interaction tables
 * (`block_interact`: berries picked, a block tilled or sheared, VMC-039b). BLOCKS.json (the third facts
 * file) names each block's table in registry order and the experience a block drops when a player
 * harvests it (`spawnAfterBreak`): a sum of uniform draws, and whether Silk Touch cancels it, each
 * checked against vanilla's own drops.
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
 *
 * Usage: LootOracle blocks OUT.json — per block state with a loot table (every context for each
 * block's default state, one random context for its other states): the drops `getDrops` makes
 * (`BlockBehaviour.getDrops` with the block's random sequence seeded) for a tool (empty, tools
 * with and without Fortune and Silk Touch, shears, enchantments stored instead of applied),
 * broken by an entity or not, by an explosion of some radius or not, with the blocks above and
 * below it (location checks) and, where the block has one, its block entity as placing the
 * block's plain item makes it. And per block-interaction table, every state of the blocks vanilla
 * uses it with (`INTERACT_TABLES`), several seeds each: the drops `dropFromBlockInteractLootTable`
 * makes for a player with an empty hand or a tool.
 */
public class LootOracle {
  static final List<String> CONTAINER_DIRS = List.of("chests/", "barrels/", "dispensers/", "archaeology/", "pots/");
  static final List<String> ENTITY_TABLES = List.of("minecraft:entities/zombie", "minecraft:entities/chicken",
      "minecraft:entities/endermite", "minecraft:entities/pig", "minecraft:entities/blaze",
      "minecraft:entities/zombified_piglin", "minecraft:entities/ghast", "minecraft:entities/magma_cube",
      // VMC-043b: the overworld hostiles.
      "minecraft:entities/husk", "minecraft:entities/zombie_villager", "minecraft:entities/skeleton",
      "minecraft:entities/stray", "minecraft:entities/bogged", "minecraft:entities/creeper", "minecraft:entities/spider",
      "minecraft:entities/cave_spider", "minecraft:entities/enderman", "minecraft:entities/silverfish",
      "minecraft:entities/slime", "minecraft:entities/witch", "minecraft:entities/phantom",
      // VMC-043e: the End's mobs, fish and squid.
      "minecraft:entities/shulker", "minecraft:entities/cod", "minecraft:entities/salmon", "minecraft:entities/pufferfish",
      "minecraft:entities/tropical_fish", "minecraft:entities/squid", "minecraft:entities/glow_squid",
      "minecraft:entities/guardian", "minecraft:entities/elder_guardian", "minecraft:entities/dolphin",
      // VMC-043c: farm animals.
      "minecraft:entities/cow", "minecraft:entities/mooshroom", "minecraft:entities/sheep", "minecraft:entities/rabbit",
      // VMC-044a: villagers, iron golems, cats and wandering traders.
      "minecraft:entities/villager", "minecraft:entities/iron_golem", "minecraft:entities/cat",
      "minecraft:entities/wandering_trader");
  // VMC-043d: what a piglin gives for a gold ingot.
  static final String BARTERING = "minecraft:gameplay/piglin_bartering";
  // VMC-043c: what shearing an animal and a laying hen give (AnimalOracle checks them).
  static final List<String> ANIMAL_TABLES = List.of("minecraft:shearing/sheep", "minecraft:shearing/mooshroom",
      "minecraft:gameplay/chicken_lay");

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

  /** A dying magma cube of a size (VMC-043d: `type_specific/cube_mob`). */
  static class CubeVictim extends net.minecraft.world.entity.monster.cubemob.MagmaCube {
    boolean fire;
    int size;
    private CubeVictim() { super(null, null); }
    @Override public boolean isOnFire() { return fire; }
    @Override public int getSize() { return size; }
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
    ProbeLevel level;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    @Override public ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
    // A block table's random sequence is the case's random.
    @Override public RandomSource getRandomSequence(Identifier id) { return level.random; }
  }

  static class ProbeLevel extends ServerLevel {
    ProbeServer server;
    RegistryAccess access;
    Holder<Biome> biome;
    BlockPos destination;
    int nextMap;
    final Map<MapId, MapItemSavedData> maps = new HashMap<>();
    net.minecraft.world.item.crafting.RecipeManager recipes;
    // Block cases: the blocks around the broken one (air elsewhere), the random, and the
    // experience orbs a break pops.
    Map<BlockPos, net.minecraft.world.level.block.state.BlockState> blocks = Map.of();
    RandomSource random;
    List<Integer> orbs;
    net.minecraft.world.level.gamerules.GameRules rules;
    @Override public net.minecraft.world.level.block.state.BlockState getBlockState(BlockPos pos) {
      return blocks.getOrDefault(pos, net.minecraft.world.level.block.Blocks.AIR.defaultBlockState());
    }
    @Override public RandomSource getRandom() { return random; }
    @Override public net.minecraft.world.level.gamerules.GameRules getGameRules() { return rules; }
    @Override public int getNextEntityId() { return 1; }
    @Override public boolean noCollision(net.minecraft.world.phys.AABB box) { return true; }
    @Override public <T extends net.minecraft.world.entity.Entity> List<T> getEntities(
        net.minecraft.world.level.entity.EntityTypeTest<net.minecraft.world.entity.Entity, T> type,
        net.minecraft.world.phys.AABB box, java.util.function.Predicate<? super T> test) { return List.of(); }
    @Override public boolean addFreshEntity(net.minecraft.world.entity.Entity entity) {
      orbs.add(((net.minecraft.world.entity.ExperienceOrb) entity).getValue());
      return true;
    }
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
      var server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
      server.registries = new ReloadableServerRegistries.Holder(lookup);
      var level = (ProbeLevel) unsafe.allocateInstance(ProbeLevel.class);
      level.server = server;
      server.level = level;
      level.access = access;
      level.blocks = Map.of();
      level.rules = new net.minecraft.world.level.gamerules.GameRules(FeatureFlags.DEFAULT_FLAGS);
      if (args[0].equals("facts")) {
        facts(args, tables, lookup, ops, level);
        return;
      }
      if (args[0].equals("blocks")) {
        blockCases(Path.of(args[1]), tables, lookup, ops, level, unsafe);
        return;
      }
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
      com.mojang.serialization.DynamicOps<JsonElement> ops, ProbeLevel level) throws Exception {
    // The container, entity and block tables and, transitively, the tables they name.
    var out = new TreeMap<String, JsonElement>();
    var queue = new ArrayDeque<String>();
    containerTables(tables).forEach(k -> queue.add(k.identifier().toString()));
    queue.addAll(ENTITY_TABLES);
    tables.listElements()
        .filter(h -> h.value().getParamSet() == LootContextParamSets.BLOCK_INTERACT)
        .map(h -> h.key().identifier().toString())
        .sorted()
        .forEach(queue::add);
    queue.add(BARTERING);
    queue.addAll(ANIMAL_TABLES);
    var blockTables = new JsonArray();
    for (var block : BuiltInRegistries.BLOCK) {
      var key = block.getLootTable();
      if (key.isPresent()) {
        queue.add(key.get().identifier().toString());
        blockTables.add(key.get().identifier().toString());
      } else {
        blockTables.add(JsonNull.INSTANCE);
      }
    }
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
        Registries.ITEM, Registries.ENTITY_TYPE)) {
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
    // The named predicates (`minecraft:tool/can_silk_touch`...) conditions refer to.
    var predicates = new JsonObject();
    lookup.lookupOrThrow(Registries.PREDICATE).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString()))
        .forEach(h -> predicates.add(h.key().identifier().toString(),
            net.minecraft.world.level.storage.loot.predicates.LootItemCondition.DIRECT_CODEC.encodeStart(ops, h.value()).getOrThrow()));
    registries.add("predicates", predicates);
    Files.writeString(Path.of(args[2]), new GsonBuilder().create().toJson(registries) + "\n");
    var blocks = new JsonObject();
    blocks.add("tables", blockTables);
    blocks.add("experience", experience(lookup, level));
    Files.writeString(Path.of(args[3]), new GsonBuilder().create().toJson(blocks) + "\n");
    System.out.println("PASS: " + out.size() + " loot tables (" + containerTables(tables).size() + " named by containers), "
        + enchantments.size() + " enchantments, " + itemRows.size() + " items");
  }

  /**
   * Per block whose harvest pops experience, the draws summed (`[min, max]` each, drawn as
   * `nextInt(max - min + 1) + min`, a constant when they are equal) and whether Silk Touch cancels it (`processBlockExperience`).
   * Each is checked against `spawnAfterBreak` over many seeds, with and without Silk Touch.
   */
  static JsonObject experience(HolderLookup.Provider lookup, ProbeLevel level) throws Exception {
    var silk = enchantedStack(Items.DIAMOND_PICKAXE, lookup.lookupOrThrow(Registries.ENCHANTMENT), Enchantments.SILK_TOUCH, 1, false);
    var spawn = net.minecraft.world.level.block.state.BlockBehaviour.class.getDeclaredMethod("spawnAfterBreak",
        net.minecraft.world.level.block.state.BlockState.class, ServerLevel.class, BlockPos.class, ItemStack.class, boolean.class);
    spawn.setAccessible(true);
    var xpRange = net.minecraft.world.level.block.DropExperienceBlock.class.getDeclaredField("xpRange");
    xpRange.setAccessible(true);
    var catalystRange = net.minecraft.world.level.block.SculkCatalystBlock.class.getDeclaredField("xpRange");
    catalystRange.setAccessible(true);
    var out = new JsonObject();
    for (var block : BuiltInRegistries.BLOCK) {
      List<int[]> terms;
      boolean silkCancels = true;
      net.minecraft.util.valueproviders.IntProvider range = null;
      if (block instanceof net.minecraft.world.level.block.DropExperienceBlock) range = (net.minecraft.util.valueproviders.IntProvider) xpRange.get(block);
      else if (block instanceof net.minecraft.world.level.block.SculkCatalystBlock) range = (net.minecraft.util.valueproviders.IntProvider) catalystRange.get(block);
      if (range != null) terms = List.<int[]>of(new int[] {range.minInclusive(), range.maxInclusive()});
      else if (block instanceof net.minecraft.world.level.block.RedStoneOreBlock) terms = List.<int[]>of(new int[] {1, 5});
      else if (block instanceof net.minecraft.world.level.block.SculkSensorBlock || block instanceof net.minecraft.world.level.block.SculkShriekerBlock) terms = List.<int[]>of(new int[] {5, 5});
      else if (block instanceof net.minecraft.world.level.block.SpawnerBlock) {
        terms = List.of(new int[] {15, 15}, new int[] {0, 14}, new int[] {0, 14});
        silkCancels = false;
      } else continue;
      if (range != null && !(range instanceof net.minecraft.util.valueproviders.ConstantInt
          || range instanceof net.minecraft.util.valueproviders.UniformInt && range.minInclusive() < range.maxInclusive()))
        throw new AssertionError("Experience provider " + range + " of " + block);
      if (terms.stream().allMatch(t -> t[1] == 0)) continue;
      // Vanilla's amounts equal the terms drawn from the same random (a constant draws nothing).
      for (int i = 0; i < 400; i++) {
        var tool = i % 4 == 3 ? silk : new ItemStack(Items.DIAMOND_PICKAXE);
        level.random = RandomSource.create(i);
        level.orbs = new ArrayList<>();
        spawn.invoke(block, block.defaultBlockState(), level, BlockPos.ZERO, tool, true);
        var replay = RandomSource.create(i);
        int expected = 0;
        // A constant term draws nothing.
        for (var term : terms) expected += term[0] == term[1] ? term[0] : replay.nextInt(term[1] - term[0] + 1) + term[0];
        if (tool == silk && silkCancels) expected = 0;
        int actual = level.orbs.stream().mapToInt(Integer::intValue).sum();
        if (actual != expected) throw new AssertionError("Experience of " + block + ": " + actual + " != " + expected);
      }
      var row = new JsonObject();
      var list = new JsonArray();
      for (var term : terms) {
        var pair = new JsonArray();
        pair.add(term[0]);
        pair.add(term[1]);
        list.add(pair);
      }
      row.add("terms", list);
      row.addProperty("silk_touch_cancels", silkCancels);
      out.add(BuiltInRegistries.BLOCK.getKey(block).toString(), row);
    }
    return out;
  }

  static ItemStack enchantedStack(Item item, HolderLookup.RegistryLookup<Enchantment> enchantments,
      ResourceKey<Enchantment> enchantment, int level, boolean stored) {
    var stack = new ItemStack(item);
    var mutable = new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);
    mutable.set(enchantments.getOrThrow(enchantment), level);
    stack.set(stored ? DataComponents.STORED_ENCHANTMENTS : DataComponents.ENCHANTMENTS, mutable.toImmutable());
    return stack;
  }

  /** A break's tool and breaker: the CONTEXTS variants block cases use. */
  record Context(ItemStack tool, boolean entity, Float radius) {}

  static final int CONTEXTS = 16;

  static Context context(int variant, HolderLookup.RegistryLookup<Enchantment> e, Random random) {
    int fortune = 1 + random.nextInt(3);
    return switch (variant) {
      case 0 -> new Context(ItemStack.EMPTY, true, null);
      case 1 -> new Context(new ItemStack(Items.DIAMOND_PICKAXE), true, null);
      case 2 -> new Context(enchantedStack(Items.DIAMOND_PICKAXE, e, Enchantments.SILK_TOUCH, 1, false), true, null);
      case 3 -> new Context(enchantedStack(Items.IRON_PICKAXE, e, Enchantments.FORTUNE, fortune, false), true, null);
      case 4 -> {
        var stack = enchantedStack(Items.NETHERITE_PICKAXE, e, Enchantments.FORTUNE, 3, false);
        stack.enchant(e.getOrThrow(Enchantments.SILK_TOUCH), 1);
        yield new Context(stack, true, null);
      }
      case 5 -> new Context(new ItemStack(Items.SHEARS), true, null);
      case 6 -> new Context(enchantedStack(Items.DIAMOND_AXE, e, Enchantments.FORTUNE, fortune, false), true, null);
      case 7 -> new Context(enchantedStack(Items.DIAMOND_HOE, e, Enchantments.FORTUNE, 3, false), true, null);
      case 8 -> new Context(new ItemStack(Items.DIAMOND_SWORD), true, null);
      case 9 -> new Context(enchantedStack(Items.DIAMOND_SHOVEL, e, Enchantments.SILK_TOUCH, 1, false), true, null);
      case 10 -> new Context(enchantedStack(Items.DIAMOND_PICKAXE, e, Enchantments.SILK_TOUCH, 1, true), true, null);
      case 11 -> new Context(enchantedStack(Items.ENCHANTED_BOOK, e, Enchantments.FORTUNE, 3, true), true, null);
      case 12 -> new Context(ItemStack.EMPTY, false, null);
      case 13 -> new Context(ItemStack.EMPTY, random.nextBoolean(), 1.0F + random.nextFloat() * 7.0F);
      case 14 -> new Context(enchantedStack(Items.GOLDEN_PICKAXE, e, Enchantments.FORTUNE, 255, false), true, null);
      default -> new Context(enchantedStack(Items.SHEARS, e, Enchantments.SILK_TOUCH, 1, false), true, null);
    };
  }

  static void blockCases(Path out, HolderLookup.RegistryLookup<LootTable> tables, HolderLookup.Provider lookup,
      com.mojang.serialization.DynamicOps<JsonElement> ops, ProbeLevel level, sun.misc.Unsafe unsafe) throws Exception {
    var enchantments = lookup.lookupOrThrow(Registries.ENCHANTMENT);
    var type = net.minecraft.world.entity.Entity.class.getDeclaredField("type");
    type.setAccessible(true);
    var random = new Random(20261023L);
    var rows = new JsonArray();
    int drops = 0;
    for (var block : BuiltInRegistries.BLOCK) {
      var key = block.getLootTable();
      if (key.isEmpty()) continue;
      var states = block.getStateDefinition().getPossibleStates();
      for (var state : states) {
        boolean all = state == block.defaultBlockState();
        for (int k = 0; k < (all ? CONTEXTS : 1); k++) {
          var context = context(all ? k : random.nextInt(CONTEXTS), enchantments, random);
          long seed = random.nextLong();
          var pos = new BlockPos(random.nextInt(2001) - 1000, random.nextInt(320) - 63, random.nextInt(2001) - 1000);
          // Above and below: air, or a state of the same block (the other half of a tall plant).
          var above = random.nextInt(3) == 0 ? net.minecraft.world.level.block.Blocks.AIR.defaultBlockState() : states.get(random.nextInt(states.size()));
          var below = random.nextInt(3) == 0 ? net.minecraft.world.level.block.Blocks.AIR.defaultBlockState() : states.get(random.nextInt(states.size()));
          level.blocks = Map.of(pos, state, pos.above(), above, pos.below(), below);
          level.random = RandomSource.create(seed);
          // A block entity as placing the block's plain item makes it (`applyComponentsFromItemStack`).
          var blockEntity = block instanceof net.minecraft.world.level.block.EntityBlock entityBlock ? entityBlock.newBlockEntity(pos, state) : null;
          if (blockEntity != null && block.asItem() != Items.AIR) blockEntity.applyComponentsFromItemStack(new ItemStack(block.asItem()));
          var params = new LootParams.Builder(level)
              .withParameter(LootContextParams.ORIGIN, Vec3.atCenterOf(pos))
              .withParameter(LootContextParams.TOOL, context.tool())
              .withOptionalParameter(LootContextParams.BLOCK_ENTITY, blockEntity);
          if (context.entity()) {
            var breaker = (Attacker) unsafe.allocateInstance(Attacker.class);
            type.set(breaker, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:player")));
            breaker.weapon = context.tool();
            params = params.withParameter(LootContextParams.THIS_ENTITY, breaker);
          }
          if (context.radius() != null) params = params.withParameter(LootContextParams.EXPLOSION_RADIUS, context.radius());
          var list = new JsonArray();
          for (var stack : state.getDrops(params)) {
            if (stack.isEmpty()) continue;
            list.add(item(stack, ops));
            drops++;
          }
          var row = new JsonObject();
          row.addProperty("table", key.get().identifier().toString());
          row.addProperty("seed", Long.toString(seed));
          row.addProperty("state", net.minecraft.world.level.block.Block.getId(state));
          var origin = new JsonArray();
          origin.add(pos.getX());
          origin.add(pos.getY());
          origin.add(pos.getZ());
          row.add("origin", origin);
          row.add("tool", context.tool().isEmpty() ? JsonNull.INSTANCE : item(context.tool(), ops));
          row.addProperty("entity", context.entity());
          if (context.radius() != null) row.addProperty("radius", context.radius());
          row.addProperty("above", net.minecraft.world.level.block.Block.getId(above));
          row.addProperty("below", net.minecraft.world.level.block.Block.getId(below));
          row.add("drops", list);
          rows.add(row);
        }
      }
    }
    int breaks = rows.size();
    // Block interactions: a player picks, tills or shears the block, its state before.
    var tools = List.of(ItemStack.EMPTY, new ItemStack(Items.SHEARS), new ItemStack(Items.IRON_HOE));
    for (var entry : INTERACT_TABLES.entrySet()) {
      var table = tables.getOrThrow(ResourceKey.create(Registries.LOOT_TABLE, Identifier.parse(entry.getKey()))).value();
      for (var name : entry.getValue()) {
        var block = BuiltInRegistries.BLOCK.getValue(Identifier.parse(name));
        for (var state : block.getStateDefinition().getPossibleStates()) {
          for (int k = 0; k < 8; k++) {
            long seed = random.nextLong();
            var pos = new BlockPos(random.nextInt(2001) - 1000, random.nextInt(320) - 63, random.nextInt(2001) - 1000);
            var tool = tools.get(random.nextInt(tools.size()));
            level.blocks = Map.of(pos, state);
            level.random = RandomSource.create(seed);
            var player = (Attacker) unsafe.allocateInstance(Attacker.class);
            type.set(player, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:player")));
            player.weapon = tool;
            var params = new LootParams.Builder(level)
                .withParameter(LootContextParams.BLOCK_STATE, state)
                .withParameter(LootContextParams.ORIGIN, Vec3.atCenterOf(pos))
                .withOptionalParameter(LootContextParams.INTERACTING_ENTITY, player)
                .withOptionalParameter(LootContextParams.TOOL, tool.isEmpty() ? null : tool)
                .create(LootContextParamSets.BLOCK_INTERACT);
            var list = new JsonArray();
            for (var stack : table.getRandomItems(params)) {
              if (stack.isEmpty()) continue;
              list.add(item(stack, ops));
              drops++;
            }
            var row = new JsonObject();
            row.addProperty("table", entry.getKey());
            row.addProperty("interact", true);
            row.addProperty("seed", Long.toString(seed));
            row.addProperty("state", net.minecraft.world.level.block.Block.getId(state));
            var origin = new JsonArray();
            origin.add(pos.getX());
            origin.add(pos.getY());
            origin.add(pos.getZ());
            row.add("origin", origin);
            row.add("tool", tool.isEmpty() ? JsonNull.INSTANCE : item(tool, ops));
            row.add("drops", list);
            rows.add(row);
          }
        }
      }
    }
    Files.writeString(out, new Gson().toJson(rows));
    System.out.println("PASS: " + breaks + " vanilla block breaks and " + (rows.size() - breaks)
        + " block interactions (" + drops + " stacks)");
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
    var barters = barterCases(tables, ops, level, random);
    var result = new JsonObject();
    result.add("synthetic_tables", synthetic);
    result.add("cases", rows);
    result.add("entity_cases", deaths);
    result.add("barter_cases", barters);
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
    var fireballDamage = lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(net.minecraft.world.damagesource.DamageTypes.FIREBALL);
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
        // A magma cube's own victim, its size one to four.
        CubeVictim cube = null;
        if (id.equals("minecraft:entities/magma_cube")) {
          cube = (CubeVictim) unsafe.allocateInstance(CubeVictim.class);
          type.set(cube, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:magma_cube")));
          position.set(cube, at);
          cube.fire = victim.fire;
          cube.size = 1 + random.nextInt(4);
        }
        net.minecraft.world.entity.Entity dying = cube != null ? cube : victim;
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
        // One death in four (by the seed) is the attacker's large fireball
        // (VMC-043d: `damage_source_properties`, a ghast's music disc).
        boolean byFireball = (seed & 3) == 0;
        net.minecraft.world.entity.Entity direct = attacker;
        var source = new net.minecraft.world.damagesource.DamageSource(damage, attacker);
        if (byFireball) {
          direct = (net.minecraft.world.entity.Entity) unsafe.allocateInstance(net.minecraft.world.entity.projectile.hurtingprojectile.LargeFireball.class);
          type.set(direct, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:fireball")));
          position.set(direct, at);
          source = new net.minecraft.world.damagesource.DamageSource(fireballDamage, direct, attacker);
        }
        var builder = new LootParams.Builder(level)
            .withParameter(LootContextParams.THIS_ENTITY, dying)
            .withParameter(LootContextParams.ORIGIN, at)
            .withParameter(LootContextParams.DAMAGE_SOURCE, source)
            .withOptionalParameter(LootContextParams.ATTACKING_ENTITY, attacker)
            .withOptionalParameter(LootContextParams.DIRECT_ATTACKING_ENTITY, direct);
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
        row.addProperty("by_fireball", byFireball);
        if (cube != null) row.addProperty("size", cube.size);
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

  /** Barters (`PiglinAi.getBarterResponseItems`) from many seeds: the items, split into stacks. */
  static JsonArray barterCases(HolderLookup.RegistryLookup<LootTable> tables, com.mojang.serialization.DynamicOps<JsonElement> ops,
      ProbeLevel level, Random random) throws Exception {
    var f = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    f.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) f.get(null);
    var type = net.minecraft.world.entity.Entity.class.getDeclaredField("type");
    type.setAccessible(true);
    var table = tables.getOrThrow(ResourceKey.create(Registries.LOOT_TABLE, Identifier.parse(BARTERING))).value();
    var piglin = (Victim) unsafe.allocateInstance(Victim.class);
    type.set(piglin, BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:piglin")));
    var rows = new JsonArray();
    for (int i = 0; i < 3000; i++) {
      long seed = random.nextLong();
      var params = new LootParams.Builder(level).withParameter(LootContextParams.THIS_ENTITY, piglin).create(LootContextParamSets.PIGLIN_BARTER);
      var items = new JsonArray();
      table.getRandomItems(params, seed).forEach(stack -> { if (!stack.isEmpty()) items.add(item(stack, ops)); });
      var row = new JsonObject();
      row.addProperty("seed", Long.toString(seed));
      row.add("items", items);
      rows.add(row);
    }
    return rows;
  }

  static ItemStack enchanted(Item item, HolderLookup.RegistryLookup<Enchantment> enchantments,
      ResourceKey<Enchantment> enchantment, int level) {
    var stack = new ItemStack(item);
    stack.enchant(enchantments.getOrThrow(enchantment), level);
    return stack;
  }

  /** The block-interaction tables and the blocks vanilla uses each with. */
  static final Map<String, List<String>> INTERACT_TABLES = new LinkedHashMap<>();
  static {
    INTERACT_TABLES.put("minecraft:harvest/sweet_berry_bush", List.of("minecraft:sweet_berry_bush"));
    INTERACT_TABLES.put("minecraft:harvest/cave_vine", List.of("minecraft:cave_vines", "minecraft:cave_vines_plant"));
    INTERACT_TABLES.put("minecraft:till/rooted_dirt", List.of("minecraft:rooted_dirt"));
    INTERACT_TABLES.put("minecraft:harvest/beehive", List.of("minecraft:beehive", "minecraft:bee_nest"));
    INTERACT_TABLES.put("minecraft:carve/pumpkin", List.of("minecraft:pumpkin"));
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
