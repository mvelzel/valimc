import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.tags.ItemTags;
import net.minecraft.tags.TagLoader;
import net.minecraft.world.item.*;
import net.minecraft.world.item.alchemy.PotionContents;
import net.minecraft.world.item.component.BrewingFuel;
import net.minecraft.world.item.crafting.*;
import net.minecraft.world.level.block.BrewingStandBlock;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.BrewingStandBlockEntity;
import net.minecraft.world.level.block.state.BlockState;

/**
 * Brewing as 26.3's data gives it (VMC-034o). `facts OUT` writes the
 * `minecraft:brewing` recipes by id, no two matching one input (input item and
 * potions, reagent item, output item and potion), the reagent and potion-input
 * item sets (`brewing_reagent`, `brewing_input` and the `brewing_potion_inputs`
 * tag) and each brewing fuel's uses and speed. `tick OUT` runs
 * `BrewingStandBlockEntity.serverTick` over scripts of slot sets and ticks:
 * after each step its slots, times, ingredient, `has_bottle_*` states, drops
 * and level events.
 */
public class BrewingOracle {
  static RecipeManager manager;
  static HolderLookup.Provider lookup;
  static ResourceManager resources;

  static void load() throws Exception {
    var initial = MiningToolOracle.initialize();
    resources = new MultiPackResourceManager(PackType.SERVER_DATA, List.of(ServerPacksSource.createVanillaPackSource().fullResources()));
    var access = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var pending = TagLoader.loadTagsForExistingRegistries(resources, access);
    var statics = TagLoader.buildUpdatedLookups(access, pending);
    var staticKeys = statics.stream().map(r -> r.key()).collect(Collectors.toSet());
    var base = HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r -> !staticKeys.contains(r.key())), statics.stream()));
    var loaded = RegistryDataLoader.load(resources, base.listRegistries().toList(), RegistryDataLoader.RELOADABLE_REGISTRIES, Runnable::run).join();
    var keys = loaded.listRegistryKeys().collect(Collectors.toSet());
    lookup = HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r -> !keys.contains(r.key())), loaded.listRegistries()));
    for (var tags : pending) tags.apply();
    manager = new RecipeManager(lookup);
    manager.finalizeRecipeLoading(net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS);
  }

  static String id(Item item) { return BuiltInRegistries.ITEM.getKey(item).toString(); }

  static JsonArray items(java.util.function.Predicate<ItemStack> test) {
    var out = new JsonArray();
    for (var item : BuiltInRegistries.ITEM) if (test.test(new ItemStack(item))) out.add(id(item));
    return out;
  }

  /** A context provider that 26.3's data gives as a plain number. */
  static JsonElement constant(String kind, String key) throws Exception {
    var path = Identifier.parse(key).withPath(p -> kind + "/" + p + ".json");
    try (var reader = resources.getResourceOrThrow(path).openAsReader()) {
      var value = JsonParser.parseReader(reader);
      if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isNumber()) throw new AssertionError("Not a constant " + key + ": " + value);
      return value;
    }
  }

  static JsonObject facts() throws Exception {
    var recipes = new JsonArray();
    for (var holder : manager.getRecipes()) {
      if (!(holder.value() instanceof BrewingRecipe recipe)) continue;
      var row = new JsonObject();
      row.addProperty("id", holder.id().identifier().toString());
      var input = recipe.getInput(); var reagent = recipe.getReagent();
      var inputItems = input.ingredient().items().toList(); var reagentItems = reagent.ingredient().items().toList();
      if (inputItems.size() != 1 || reagentItems.size() != 1 || reagent.potions().isPresent() || input.potions().isEmpty())
        throw new AssertionError("Unexpected brewing ingredient shape " + holder.id());
      var predicate = input.potions().get();
      if (predicate.effects().isPresent() || predicate.potions().isEmpty()) throw new AssertionError("Unexpected potion predicate " + holder.id());
      row.addProperty("input", id(inputItems.get(0).value()));
      var potions = new JsonArray();
      for (var potion : predicate.potions().get()) potions.add(potion.unwrapKey().orElseThrow().identifier().toString());
      row.add("potions", potions);
      row.addProperty("reagent", id(reagentItems.get(0).value()));
      var output = recipe.getOutput().create();
      var patch = output.getComponentsPatch();
      var contents = output.get(DataComponents.POTION_CONTENTS);
      if (patch.size() != 1 || contents == null || contents.potion().isEmpty() || !contents.customEffects().isEmpty()
          || contents.customColor().isPresent() || contents.customName().isPresent() || output.getCount() != 1)
        throw new AssertionError("Unexpected brewing output " + holder.id());
      row.addProperty("output", id(output.getItem()));
      row.addProperty("output_potion", contents.potion().get().unwrapKey().orElseThrow().identifier().toString());
      recipes.add(row);
    }
    var out = new JsonObject();
    out.addProperty("version", "26.3"); out.addProperty("data_version", 5023);
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var seen = new HashSet<String>();
    for (var r : recipes) {
      var row = r.getAsJsonObject();
      for (var potion : row.getAsJsonArray("potions"))
        if (!seen.add(row.get("input").getAsString() + " " + potion.getAsString() + " " + row.get("reagent").getAsString()))
          throw new AssertionError("Two brewing recipes match one input: " + row.get("id"));
    }
    var sorted = new ArrayList<JsonElement>(); recipes.forEach(sorted::add);
    sorted.sort(Comparator.comparing(e -> e.getAsJsonObject().get("id").getAsString()));
    recipes = new JsonArray(); sorted.forEach(recipes::add);
    out.add("recipes", recipes);
    out.add("reagents", items(manager.propertySet(RecipePropertySet.BREWING_REAGENTS)::test));
    var inputs = manager.propertySet(RecipePropertySet.BREWING_INPUTS);
    out.add("potion_inputs", items(stack -> inputs.test(stack) || stack.is(ItemTags.BREWING_POTION_INPUTS)));
    var fuels = new JsonArray();
    var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
    for (var item : BuiltInRegistries.ITEM) {
      var fuel = new ItemStack(item).get(DataComponents.BREWING_FUEL);
      if (fuel == null) continue;
      var encoded = BrewingFuel.CODEC.encodeStart(ops, fuel).getOrThrow().getAsJsonObject();
      var row = new JsonObject(); row.addProperty("item", id(item));
      row.add("uses", constant("context_int_provider", encoded.get("uses").getAsString()));
      row.add("speed", constant("context_float_provider", encoded.get("speed_multiplier").getAsString()));
      var remainder = item.getCraftingRemainder();
      row.add("remainder", remainder == null ? JsonNull.INSTANCE : new JsonPrimitive(id(remainder.create().getItem())));
      fuels.add(row);
    }
    out.add("fuels", fuels);
    // Reagents whose use leaves something behind (`getCraftingRemainder`).
    var remainders = new JsonObject();
    for (var item : BuiltInRegistries.ITEM) {
      var remainder = item.getCraftingRemainder();
      if (remainder != null && manager.propertySet(RecipePropertySet.BREWING_REAGENTS).test(new ItemStack(item)))
        remainders.addProperty(id(item), id(remainder.create().getItem()));
    }
    out.add("reagent_remainders", remainders);
    return out;
  }

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.server.ReloadableServerRegistries.Holder registries; net.minecraft.util.RandomSource random;
    private Server() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
  }
  static class World extends net.minecraft.server.level.ServerLevel {
    Server server; BlockState state; List<ItemStack> drops; List<Integer> events; RegistryAccess access;
    private World() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    public net.minecraft.server.MinecraftServer getServer() { return server; }
    public net.minecraft.util.RandomSource getRandom() { return server.random; }
    public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    public RegistryAccess registryAccess() { return access; }
    public RecipeManager recipeAccess() { return manager; }
    public int getNextEntityId() { return 1; }
    public boolean addFreshEntity(net.minecraft.world.entity.Entity entity) { drops.add(((net.minecraft.world.entity.item.ItemEntity) entity).getItem().copy()); return true; }
    public BlockState getBlockState(BlockPos pos) { return state; }
    public boolean setBlock(BlockPos pos, BlockState next, int flags) { state = next; return true; }
    public void levelEvent(net.minecraft.world.entity.Entity source, int type, BlockPos pos, int data) { events.add(type); }
    public void blockEntityChanged(BlockPos pos) {}
    public void updateNeighbourForOutputSignal(BlockPos pos, net.minecraft.world.level.block.Block block) {}
  }

  static JsonElement spec(ItemStack stack) {
    if (stack.isEmpty()) return JsonNull.INSTANCE;
    var row = new JsonArray(); row.add(id(stack.getItem())); row.add(stack.getCount());
    var contents = stack.get(DataComponents.POTION_CONTENTS);
    var potion = contents == null ? null : contents.potion().map(h -> h.unwrapKey().orElseThrow().identifier().toString()).orElse(null);
    row.add(potion == null ? JsonNull.INSTANCE : new JsonPrimitive(potion));
    // Only the potion matters: anything else would go unseen by the checker.
    if (!ItemStack.matches(stack, stack(row))) throw new AssertionError("Unexpected brewing stack " + stack);
    return row;
  }

  static ItemStack stack(JsonElement spec) {
    if (spec.isJsonNull()) return ItemStack.EMPTY;
    var row = spec.getAsJsonArray();
    var item = BuiltInRegistries.ITEM.getValue(Identifier.parse(row.get(0).getAsString()));
    if (row.get(2).isJsonNull()) return new ItemStack(item, row.get(1).getAsInt());
    var potion = BuiltInRegistries.POTION.get(Identifier.parse(row.get(2).getAsString())).orElseThrow();
    var stack = PotionContents.createItemStack(item, potion); stack.setCount(row.get(1).getAsInt());
    return stack;
  }

  static JsonArray specs(Object... rows) {
    var out = new JsonArray();
    for (var row : rows) {
      if (row == null) { out.add(JsonNull.INSTANCE); continue; }
      var parts = (Object[]) row; var spec = new JsonArray();
      spec.add("minecraft:" + parts[0]); spec.add((Integer) parts[1]);
      spec.add(parts.length > 2 ? new JsonPrimitive("minecraft:" + parts[2]) : JsonNull.INSTANCE);
      out.add(spec);
    }
    return out;
  }

  static Object[] s(Object... parts) { return parts; }

  // `[op, ...]`: `["set", slots...]` (five specs, null for empty) or `["tick", n]`.
  static JsonArray set(Object... slots) { var op = new JsonArray(); op.add("set"); op.add(specs(slots)); return op; }
  static JsonArray tick(int n) { var op = new JsonArray(); op.add("tick"); op.add(n); return op; }
  static JsonArray script(JsonArray... ops) { var out = new JsonArray(); for (var op : ops) out.add(op); return out; }

  static JsonArray scripts() {
    var water = s("potion", 1, "water"); var awkward = s("potion", 1, "awkward");
    return script(
      // Water into awkward, then awkward into strength with the wart's last.
      script(set(water, water, water, s("nether_wart", 2), s("blaze_powder", 1)), tick(1), tick(398), tick(1), tick(1), tick(2), tick(400), tick(3)),
      // Dragon's breath: its bottle replaces the last, and drops beside a stack.
      script(set(s("splash_potion", 1, "strength"), null, s("splash_potion", 1, "awkward"), s("dragon_breath", 1), s("blaze_powder", 2)), tick(401), tick(2)),
      script(set(s("splash_potion", 1, "awkward"), s("splash_potion", 1, "water"), null, s("dragon_breath", 2), s("blaze_powder", 1)), tick(401), tick(2)),
      // A changed ingredient stops the brew; no fuel waits for some.
      script(set(awkward, awkward, null, s("sugar", 1), s("blaze_powder", 1)), tick(10), set(awkward, awkward, null, s("redstone", 1), s("blaze_powder", 1)), tick(1), tick(5)),
      script(set(water, null, null, s("nether_wart", 1), null), tick(50), set(water, null, null, s("nether_wart", 1), s("blaze_powder", 1)), tick(1), tick(399), tick(1)),
      // Bottles taken mid-brew, glass bottles and an unbrewable reagent.
      script(set(water, null, null, s("nether_wart", 1), s("blaze_powder", 1)), tick(200), set(null, null, null, s("nether_wart", 1), null), tick(1), tick(3)),
      script(set(s("glass_bottle", 1), s("glass_bottle", 1), null, s("gunpowder", 1), s("blaze_powder", 1)), tick(5)),
      script(set(water, water, water, s("stone", 1), s("blaze_powder", 1)), tick(5)),
      // Mixed bottles, a wind charge and an infestation.
      script(set(awkward, water, s("lingering_potion", 1, "awkward"), s("breeze_rod", 1), s("blaze_powder", 1)), tick(401)),
      script(set(awkward, s("potion", 1, "mundane"), awkward, s("stone", 3), s("blaze_powder", 1)), tick(401), tick(401)));
  }

  static JsonObject observe(BrewingStandBlockEntity stand, World world) throws Exception {
    var row = new JsonObject();
    for (var name : List.of("brewTime", "totalBrewTime", "fuel", "totalFuel")) {
      var f = BrewingStandBlockEntity.class.getDeclaredField(name); f.setAccessible(true); row.addProperty(name, f.getInt(stand));
    }
    var speed = BrewingStandBlockEntity.class.getDeclaredField("speedMultiplier"); speed.setAccessible(true);
    row.addProperty("speed", (double) speed.getFloat(stand));
    var ingredient = BrewingStandBlockEntity.class.getDeclaredField("ingredient"); ingredient.setAccessible(true);
    var item = (Item) ingredient.get(stand);
    row.add("ingredient", item == null ? JsonNull.INSTANCE : new JsonPrimitive(id(item)));
    var slots = new JsonArray(); for (int i = 0; i < 5; i++) slots.add(spec(stand.getItem(i))); row.add("slots", slots);
    var bits = new JsonArray(); for (var p : BrewingStandBlock.HAS_BOTTLE) bits.add(world.state.getValue(p)); row.add("bottles", bits);
    var drops = new JsonArray(); for (var d : world.drops) drops.add(spec(d)); row.add("drops", drops);
    var events = new JsonArray(); for (var e : world.events) events.add(e); row.add("events", events);
    world.drops.clear(); world.events.clear();
    return row;
  }

  static JsonArray ticks() throws Exception {
    var u = sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); u.setAccessible(true); var unsafe = (sun.misc.Unsafe) u.get(null);
    var server = (Server) unsafe.allocateInstance(Server.class);
    server.registries = new net.minecraft.server.ReloadableServerRegistries.Holder(lookup); server.random = net.minecraft.util.RandomSource.create(17);
    var cases = new JsonArray();
    for (var script : scripts()) {
      var world = (World) unsafe.allocateInstance(World.class);
      world.server = server; world.drops = new ArrayList<>(); world.events = new ArrayList<>();
      world.access = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      world.state = Blocks.BREWING_STAND.defaultBlockState();
      var stand = new BrewingStandBlockEntity(BlockPos.ZERO, world.state); stand.setLevel(world);
      var states = new JsonArray();
      for (var element : script.getAsJsonArray()) {
        var op = element.getAsJsonArray();
        if (op.get(0).getAsString().equals("set")) {
          var slots = op.get(1).getAsJsonArray();
          for (int i = 0; i < 5; i++) stand.setItem(i, stack(slots.get(i)));
        } else {
          for (int i = 0; i < op.get(1).getAsInt(); i++) BrewingStandBlockEntity.serverTick(world, BlockPos.ZERO, world.state, stand);
        }
        states.add(observe(stand, world));
      }
      var row = new JsonObject(); row.add("ops", script); row.add("states", states); cases.add(row);
    }
    return cases;
  }

  public static void main(String[] args) throws Exception {
    load();
    switch (args[0]) {
      case "facts" -> {
        var facts = facts();
        Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().serializeNulls().create().toJson(facts) + "\n");
        System.out.println("PASS: " + facts.getAsJsonArray("recipes").size() + " brewing recipes, "
            + facts.getAsJsonArray("reagents").size() + " reagents, " + facts.getAsJsonArray("potion_inputs").size() + " potion inputs, "
            + facts.getAsJsonArray("fuels").size() + " fuels.");
      }
      case "tick" -> {
        var cases = ticks();
        Files.writeString(Path.of(args[1]), new GsonBuilder().serializeNulls().create().toJson(cases));
        System.out.println("PASS: " + cases.size() + " vanilla brewing stand scripts through serverTick.");
      }
      case "colors" -> {
        // `PotionContents.getColor` of every potion, and of custom effects
        // with amplifiers and hidden particles mixed in.
        var rows = new JsonArray();
        for (var potion : BuiltInRegistries.POTION.listElements().toList()) {
          var row = new JsonObject(); row.addProperty("potion", BuiltInRegistries.POTION.getId(potion.value()));
          row.add("effects", new JsonArray()); row.addProperty("color", new PotionContents(potion).getColor()); rows.add(row);
        }
        var random = new java.util.Random(34);
        for (int n = 0; n < 200; n++) {
          var effects = new ArrayList<net.minecraft.world.effect.MobEffectInstance>(); var list = new JsonArray();
          for (int k = 0; k < 1 + random.nextInt(4); k++) {
            int id = random.nextInt(BuiltInRegistries.MOB_EFFECT.size()); int amp = random.nextInt(6); boolean visible = random.nextInt(4) != 0;
            effects.add(new net.minecraft.world.effect.MobEffectInstance(BuiltInRegistries.MOB_EFFECT.get(id).orElseThrow(), 200, amp, false, visible, true));
            var e = new JsonArray(); e.add(id); e.add(amp); e.add(visible); list.add(e);
          }
          var row = new JsonObject(); row.add("potion", JsonNull.INSTANCE); row.add("effects", list);
          row.addProperty("color", new PotionContents(Optional.empty(), Optional.empty(), effects, Optional.empty()).getColor()); rows.add(row);
        }
        Files.writeString(Path.of(args[1]), new GsonBuilder().serializeNulls().create().toJson(rows));
        System.out.println("PASS: " + rows.size() + " vanilla potion colours.");
      }
      default -> throw new IllegalArgumentException("usage: BrewingOracle facts|tick|colors OUT.json");
    }
  }
}
