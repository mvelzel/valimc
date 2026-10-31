import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;

/**
 * The enchanting table (VMC-038a): a real `EnchantmentMenu` over a probe level holding the
 * table's bookshelves (and blocks between them), for a probe player with an enchantment seed.
 * Each case puts an item in, records the three costs and clues, then presses each button that
 * the player can afford and records the enchanted item, the lapis left, the levels and the new
 * seed. `check_enchanting_table.exs` replays every case through ValiMC's table.
 * Usage: EnchantingTableOracle CASES.json
 */
public class EnchantingTableOracle {
  static class ProbeServer extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers debug;
    net.minecraft.server.ReloadableServerRegistries.Holder registries;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    @Override public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
    @Override public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return debug; }
  }

  /** A level that holds a few blocks around the table and plays no sounds. */
  static class Arena extends ServerLevel {
    ProbeServer server;
    RegistryAccess access;
    Map<BlockPos, BlockState> blocks;
    int ids;
    private Arena() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public net.minecraft.server.MinecraftServer getServer() { return server; }
    @Override public RegistryAccess registryAccess() { return access; }
    @Override public int getNextEntityId() { return ++ids; }
    @Override public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    @Override public long getGameTime() { return 1000L; }
    static net.minecraft.world.attribute.EnvironmentAttributeSystem env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    @Override public net.minecraft.world.attribute.EnvironmentAttributeSystem environmentAttributes() { return env; }
    @Override public BlockState getBlockState(BlockPos pos) { return blocks.getOrDefault(pos, Blocks.AIR.defaultBlockState()); }
    @Override public net.minecraft.world.level.material.FluidState getFluidState(BlockPos pos) {
      return net.minecraft.world.level.material.Fluids.EMPTY.defaultFluidState();
    }
    @Override public void playSound(Entity except, BlockPos pos, net.minecraft.sounds.SoundEvent sound, net.minecraft.sounds.SoundSource source, float volume, float pitch) {}
  }

  static class Enchanter extends Player {
    Enchanter(net.minecraft.world.level.Level level) { super(level, new com.mojang.authlib.GameProfile(new UUID(5, 6), "Enchanter")); }
    @Override public net.minecraft.world.level.GameType gameMode() { return net.minecraft.world.level.GameType.SURVIVAL; }
  }

  static sun.misc.Unsafe unsafe;
  static HolderLookup.Provider lookup;

  static void put(Object target, Class<?> owner, String name, Object value) throws Exception {
    var field = owner.getDeclaredField(name);
    field.setAccessible(true);
    unsafe.putObject(target, unsafe.objectFieldOffset(field), value);
  }

  static void putInt(Object target, Class<?> owner, String name, int value) throws Exception {
    var field = owner.getDeclaredField(name);
    field.setAccessible(true);
    unsafe.putInt(target, unsafe.objectFieldOffset(field), value);
  }

  static int getInt(Object target, Class<?> owner, String name) throws Exception {
    var field = owner.getDeclaredField(name);
    field.setAccessible(true);
    return unsafe.getInt(target, unsafe.objectFieldOffset(field));
  }

  static JsonArray levels(ItemStack stack) {
    var out = new JsonArray();
    var component = stack.is(Items.ENCHANTED_BOOK)
        ? stack.getOrDefault(net.minecraft.core.component.DataComponents.STORED_ENCHANTMENTS, ItemEnchantments.EMPTY)
        : stack.getEnchantments();
    var sorted = new TreeMap<String, Integer>();
    component.entrySet().forEach(e -> sorted.put(e.getKey().unwrapKey().orElseThrow().identifier().toString(), e.getIntValue()));
    sorted.forEach((k, v) -> { var p = new JsonArray(); p.add(k); p.add(v); out.add(p); });
    return out;
  }

  static <T> MappedRegistry<T> registry(ResourceKey<Registry<T>> key) {
    var source = lookup.lookupOrThrow(key);
    var result = new MappedRegistry<T>(key, com.mojang.serialization.Lifecycle.stable());
    for (var id : source.listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString())).toList())
      result.register(id, source.getOrThrow(id).value(), RegistrationInfo.BUILT_IN);
    result.freeze();
    return result;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var enchantments = registry(Registries.ENCHANTMENT);
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY))
          .forEach(Registry.PendingTags::apply);
      net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, new RegistryAccess.ImmutableRegistryAccess(List.of(enchantments)).freeze())
          .forEach(Registry.PendingTags::apply);
    }
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    var level = (Arena) unsafe.allocateInstance(Arena.class);
    level.server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
    level.server.debug = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    level.server.registries = new net.minecraft.server.ReloadableServerRegistries.Holder(lookup);
    var registries = new ArrayList<Registry<?>>();
    registries.add(enchantments);
    BuiltInRegistries.REGISTRY.forEach(r -> registries.add(r));
    level.access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    put(level, net.minecraft.world.level.Level.class, "random", RandomSource.create(3L));

    var table = new BlockPos(0, 64, 0);
    var offsets = net.minecraft.world.level.block.EnchantingTableBlock.BOOKSHELF_OFFSETS;
    var cases = new JsonArray();
    var random = new Random(20261101L);
    var items = List.of("minecraft:book", "minecraft:diamond_sword", "minecraft:iron_pickaxe", "minecraft:bow",
        "minecraft:crossbow", "minecraft:trident", "minecraft:mace", "minecraft:fishing_rod", "minecraft:golden_helmet",
        "minecraft:leather_boots", "minecraft:netherite_chestplate", "minecraft:wooden_axe", "minecraft:stone_shovel",
        "minecraft:shears", "minecraft:carved_pumpkin", "minecraft:stick", "minecraft:iron_spear");
    for (var item : items) {
      for (int shelves : new int[]{0, 1, 4, 8, 12, 15, 20}) {
        for (int round = 0; round < 4; round++) {
          int seed = random.nextInt();
          // The first `shelves` offsets hold bookshelves; one round blocks some with stone between.
          level.blocks = new HashMap<>();
          var layout = new JsonArray();
          for (int i = 0; i < Math.min(shelves, offsets.size()); i++) {
            var offset = offsets.get(i);
            level.blocks.put(table.offset(offset), Blocks.BOOKSHELF.defaultBlockState());
            var cell = new JsonArray(); cell.add(offset.getX()); cell.add(offset.getY()); cell.add(offset.getZ()); cell.add("minecraft:bookshelf");
            layout.add(cell);
            if (round == 3 && i % 3 == 0) {
              var between = new BlockPos(offset.getX() / 2, offset.getY(), offset.getZ() / 2);
              level.blocks.put(table.offset(between), Blocks.STONE.defaultBlockState());
              var stone = new JsonArray(); stone.add(between.getX()); stone.add(between.getY()); stone.add(between.getZ()); stone.add("minecraft:stone");
              layout.add(stone);
            }
          }
          var player = new Enchanter(level);
          putInt(player, Player.class, "enchantmentSeed", seed);
          player.experienceLevel = 30;
          var menu = new EnchantmentMenu(1, player.getInventory(), ContainerLevelAccess.create(level, table));
          var stack = new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(item)));
          menu.getSlot(1).set(new ItemStack(Items.LAPIS_LAZULI, 3));
          menu.getSlot(0).set(stack);
          var o = new JsonObject();
          o.addProperty("item", item);
          o.add("layout", layout);
          o.addProperty("seed", seed);
          var offers = new JsonArray();
          for (int i = 0; i < 3; i++) {
            var offer = new JsonArray();
            offer.add(menu.costs[i]);
            offer.add(menu.enchantClue[i] < 0 ? JsonNull.INSTANCE
                : new JsonPrimitive(enchantments.getKey(enchantments.byId(menu.enchantClue[i])).toString()));
            offer.add(menu.levelClue[i]);
            offers.add(offer);
          }
          o.add("offers", offers);
          // Each affordable button, from the same state.
          var pressed = new JsonArray();
          for (int button = 0; button < 3; button++) {
            if (menu.costs[button] <= 0) continue;
            var again = new Enchanter(level);
            putInt(again, Player.class, "enchantmentSeed", seed);
            again.experienceLevel = 30;
            put(again, Entity.class, "random", RandomSource.create(seed ^ 99L));
            var m = new EnchantmentMenu(1, again.getInventory(), ContainerLevelAccess.create(level, table));
            m.getSlot(1).set(new ItemStack(Items.LAPIS_LAZULI, 3));
            m.getSlot(0).set(new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(item))));
            var done = m.clickMenuButton(again, button);
            var p = new JsonObject();
            p.addProperty("button", button);
            p.addProperty("done", done);
            var result = m.getSlot(0).getItem();
            p.addProperty("result", BuiltInRegistries.ITEM.getKey(result.getItem()).toString());
            p.add("enchantments", levels(result));
            p.addProperty("lapis", m.getSlot(1).getItem().getCount());
            p.addProperty("levels", again.experienceLevel);
            p.addProperty("new_seed", getInt(again, Player.class, "enchantmentSeed"));
            pressed.add(p);
          }
          o.add("pressed", pressed);
          cases.add(o);
        }
      }
    }
    Files.writeString(Path.of(args[0]), new Gson().toJson(cases) + "\n");
    System.out.println("PASS: " + cases.size() + " enchanting table cases");
  }
}
