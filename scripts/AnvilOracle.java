import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;

/**
 * Anvils and grindstones (VMC-038b): real `AnvilMenu`s and `GrindstoneMenu`s for a probe player
 * (survival or creative) over pairs of inputs: repairs, combinations, books, incompatible and
 * unsupported enchantments, prior work, renames and stacks; the grindstone's single and merged
 * inputs. Each case records the result (item, damage, enchantments, repair cost, name), the
 * anvil's cost, used repair materials and rename-only flag, and the grindstone's experience base.
 * `check_anvil.exs` replays every case through `Valimc.Menus.Anvil`.
 * Usage: AnvilOracle CASES.json
 */
public class AnvilOracle {
  /** A level a player can be made in. */
  static class Probe extends net.minecraft.server.level.ServerLevel {
    int ids;
    private Probe() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public int getNextEntityId() { return ++ids; }
    @Override public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    static net.minecraft.world.attribute.EnvironmentAttributeSystem env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    @Override public net.minecraft.world.attribute.EnvironmentAttributeSystem environmentAttributes() { return env; }
  }

  static class Smith extends Player {
    boolean creative;
    Smith(net.minecraft.world.level.Level level, boolean creative) {
      super(level, new com.mojang.authlib.GameProfile(new UUID(7, 8), "Smith"));
      this.creative = creative;
    }
    @Override public net.minecraft.world.level.GameType gameMode() {
      return creative ? net.minecraft.world.level.GameType.CREATIVE : net.minecraft.world.level.GameType.SURVIVAL;
    }
    @Override public boolean hasInfiniteMaterials() { return creative; }
  }

  static HolderLookup.Provider lookup;
  static MappedRegistry<Enchantment> enchantments;

  static ItemStack stack(String item, int count, int damage, int repairCost, Map<String, Integer> levels, String name) {
    var s = new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(item)), count);
    if (damage > 0) s.setDamageValue(damage);
    if (repairCost > 0) s.set(DataComponents.REPAIR_COST, repairCost);
    if (name != null) s.set(DataComponents.CUSTOM_NAME, Component.literal(name));
    var mutable = new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);
    levels.forEach((e, l) -> mutable.set(enchantments.getOrThrow(ResourceKey.create(Registries.ENCHANTMENT, Identifier.parse(e))), l));
    s.set(s.is(Items.ENCHANTED_BOOK) ? DataComponents.STORED_ENCHANTMENTS : DataComponents.ENCHANTMENTS, mutable.toImmutable());
    return s;
  }

  static JsonElement describe(ItemStack s) {
    if (s.isEmpty()) return JsonNull.INSTANCE;
    var o = new JsonObject();
    o.addProperty("item", BuiltInRegistries.ITEM.getKey(s.getItem()).toString());
    o.addProperty("count", s.getCount());
    o.addProperty("damage", s.getDamageValue());
    o.addProperty("max_damage", s.getMaxDamage());
    o.addProperty("repair_cost", s.getOrDefault(DataComponents.REPAIR_COST, 0));
    var name = s.get(DataComponents.CUSTOM_NAME);
    o.addProperty("name", name == null ? null : name.getString());
    var component = s.is(Items.ENCHANTED_BOOK) ? DataComponents.STORED_ENCHANTMENTS : DataComponents.ENCHANTMENTS;
    var sorted = new TreeMap<String, Integer>();
    s.getOrDefault(component, ItemEnchantments.EMPTY).entrySet()
        .forEach(e -> sorted.put(e.getKey().unwrapKey().orElseThrow().identifier().toString(), e.getIntValue()));
    var levels = new JsonArray();
    sorted.forEach((k, v) -> { var p = new JsonArray(); p.add(k); p.add(v); levels.add(p); });
    o.add("enchantments", levels);
    return o;
  }

  static Object field(Object target, Class<?> owner, String name) throws Exception {
    var f = owner.getDeclaredField(name);
    f.setAccessible(true);
    return f.get(target);
  }

  static Map<String, Integer> l(Object... pairs) {
    var m = new LinkedHashMap<String, Integer>();
    for (int i = 0; i < pairs.length; i += 2) m.put((String) pairs[i], (Integer) pairs[i + 1]);
    return m;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var source = lookup.lookupOrThrow(Registries.ENCHANTMENT);
    enchantments = new MappedRegistry<>(Registries.ENCHANTMENT, com.mojang.serialization.Lifecycle.stable());
    for (var id : source.listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString())).toList())
      enchantments.register(id, source.getOrThrow(id).value(), RegistrationInfo.BUILT_IN);
    enchantments.freeze();
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY))
          .forEach(Registry.PendingTags::apply);
      net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, new RegistryAccess.ImmutableRegistryAccess(List.of(enchantments)).freeze())
          .forEach(Registry.PendingTags::apply);
    }
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    var level = (Probe) unsafe.allocateInstance(Probe.class);

    // {input, addition, rename} triples.
    var pairs = new ArrayList<Object[]>();
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 900, 0, l(), null), stack("minecraft:diamond", 3, 0, 0, l(), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 300, 0, l(), null), stack("minecraft:diamond", 5, 0, 0, l(), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l(), null), stack("minecraft:diamond", 1, 0, 0, l(), null), null});
    pairs.add(new Object[]{stack("minecraft:iron_pickaxe", 1, 200, 0, l("minecraft:efficiency", 3), null),
        stack("minecraft:iron_pickaxe", 1, 100, 0, l("minecraft:efficiency", 3, "minecraft:unbreaking", 2), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l("minecraft:sharpness", 4), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:sharpness", 4), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l("minecraft:sharpness", 5), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:sharpness", 5), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l("minecraft:sharpness", 3), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:smite", 3), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l("minecraft:sharpness", 3), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:smite", 3, "minecraft:looting", 2), null), null});
    pairs.add(new Object[]{stack("minecraft:iron_pickaxe", 1, 0, 0, l(), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:sharpness", 2), null), null});
    pairs.add(new Object[]{stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:protection", 3), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:protection", 3), null), null});
    pairs.add(new Object[]{stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:mending", 1), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:unbreaking", 3, "minecraft:vanishing_curse", 1), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_chestplate", 1, 50, 31, l("minecraft:protection", 4), null),
        stack("minecraft:enchanted_book", 1, 0, 7, l("minecraft:unbreaking", 3), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_chestplate", 1, 50, 63, l("minecraft:protection", 4), null),
        stack("minecraft:diamond", 1, 0, 0, l(), null), null});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l(), null), null, "Excalibur"});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l(), null), null, "Diamond Sword"});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 0, l(), "Old"), null, ""});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 0, 63, l(), null), null, "Excalibur"});
    pairs.add(new Object[]{stack("minecraft:diamond_sword", 1, 500, 0, l("minecraft:sharpness", 1), null),
        stack("minecraft:diamond", 2, 0, 0, l(), null), "Excalibur"});
    pairs.add(new Object[]{stack("minecraft:book", 2, 0, 0, l(), null), stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:sharpness", 1), null), null});
    pairs.add(new Object[]{stack("minecraft:elytra", 1, 400, 0, l(), null), stack("minecraft:phantom_membrane", 4, 0, 0, l(), null), null});
    pairs.add(new Object[]{stack("minecraft:bow", 1, 0, 0, l("minecraft:infinity", 1), null),
        stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:mending", 1), null), null});
    pairs.add(new Object[]{stack("minecraft:stick", 1, 0, 0, l(), null), stack("minecraft:stick", 1, 0, 0, l(), null), null});

    var cases = new JsonArray();
    for (var creative : List.of(false, true)) {
      for (var p : pairs) {
        var player = new Smith(level, creative);
        player.experienceLevel = 100;
        var menu = new AnvilMenu(1, player.getInventory(), ContainerLevelAccess.NULL);
        var input = (ItemStack) p[0];
        var addition = (ItemStack) p[1];
        menu.getSlot(0).set(input.copy());
        if (addition != null) menu.getSlot(1).set(addition.copy());
        if (p[2] != null) menu.setItemName((String) p[2]);
        menu.createResult();
        var o = new JsonObject();
        o.addProperty("kind", "anvil");
        o.addProperty("creative", creative);
        o.add("input", describe(input));
        o.add("addition", addition == null ? JsonNull.INSTANCE : describe(addition));
        o.addProperty("rename", (String) p[2]);
        o.add("result", describe(menu.getSlot(2).getItem()));
        o.addProperty("cost", menu.getCost());
        o.addProperty("repair_count", (int) field(menu, AnvilMenu.class, "repairItemCountCost"));
        o.addProperty("only_renaming", (boolean) field(menu, AnvilMenu.class, "onlyRenaming"));
        cases.add(o);
      }
    }

    var grinds = new ArrayList<ItemStack[]>();
    grinds.add(new ItemStack[]{stack("minecraft:diamond_sword", 1, 100, 3, l("minecraft:sharpness", 5, "minecraft:vanishing_curse", 1), null), null});
    grinds.add(new ItemStack[]{null, stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:mending", 1, "minecraft:unbreaking", 3), null)});
    grinds.add(new ItemStack[]{stack("minecraft:enchanted_book", 1, 0, 0, l("minecraft:binding_curse", 1), null), null});
    grinds.add(new ItemStack[]{stack("minecraft:iron_pickaxe", 1, 200, 0, l("minecraft:efficiency", 3), null),
        stack("minecraft:iron_pickaxe", 1, 150, 0, l("minecraft:fortune", 2, "minecraft:vanishing_curse", 1), null)});
    grinds.add(new ItemStack[]{stack("minecraft:diamond_sword", 1, 0, 0, l(), null), null});
    grinds.add(new ItemStack[]{stack("minecraft:diamond_sword", 1, 0, 0, l(), null), stack("minecraft:iron_sword", 1, 0, 0, l(), null)});
    grinds.add(new ItemStack[]{stack("minecraft:stick", 1, 0, 0, l(), null), stack("minecraft:stick", 1, 0, 0, l(), null)});
    for (var g : grinds) {
      var player = new Smith(level, false);
      var menu = new GrindstoneMenu(1, player.getInventory(), ContainerLevelAccess.NULL);
      if (g[0] != null) menu.getSlot(0).set(g[0].copy());
      if (g[1] != null) menu.getSlot(1).set(g[1].copy());
      var resultSlot = menu.getSlot(2);
      var base = 0;
      var from = resultSlot.getClass().getDeclaredMethod("getExperienceFromItem", ItemStack.class);
      from.setAccessible(true);
      for (var s : g) if (s != null) base += (int) from.invoke(resultSlot, s);
      var o = new JsonObject();
      o.addProperty("kind", "grindstone");
      o.add("input", g[0] == null ? JsonNull.INSTANCE : describe(g[0]));
      o.add("addition", g[1] == null ? JsonNull.INSTANCE : describe(g[1]));
      o.add("result", describe(resultSlot.getItem()));
      o.addProperty("experience", base);
      cases.add(o);
    }

    Files.writeString(Path.of(args[0]), new Gson().toJson(cases) + "\n");
    System.out.println("PASS: " + cases.size() + " anvil and grindstone cases");
  }
}
