import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.damagesource.DamageType;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;

/**
 * Vanilla's enchantment hooks over the pinned data pack (VMC-037q): `EnchantmentHelper`'s value
 * hooks, attribute modifiers and immunity, run on real stacks against real entities in a probe
 * level, each case with the seed its draws start from. `check_enchantment_effects.exs` replays
 * every case through ValiMC's engine.
 * Usage: EnchantmentEffectOracle CASES.json
 */
public class EnchantmentEffectOracle {
  static class ProbeServer extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers debug;
    net.minecraft.server.ReloadableServerRegistries.Holder registries;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    @Override public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
    @Override public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return debug; }
  }

  /** A level with the registries, a seeded random and air everywhere. */
  static class Arena extends ServerLevel {
    ProbeServer server;
    RegistryAccess access;
    int ids;
    private Arena() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public net.minecraft.server.MinecraftServer getServer() { return server; }
    @Override public RegistryAccess registryAccess() { return access; }
    @Override public int getNextEntityId() { return ++ids; }
    @Override public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    @Override public long getGameTime() { return 1000L; }
    @Override public int getSeaLevel() { return 63; }
    static net.minecraft.world.attribute.EnvironmentAttributeSystem env = net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().build();
    @Override public net.minecraft.world.attribute.EnvironmentAttributeSystem environmentAttributes() { return env; }
    @Override public net.minecraft.world.level.block.state.BlockState getBlockState(BlockPos pos) {
      return net.minecraft.world.level.block.Blocks.AIR.defaultBlockState();
    }
    @Override public net.minecraft.world.level.material.FluidState getFluidState(BlockPos pos) {
      return net.minecraft.world.level.material.Fluids.EMPTY.defaultFluidState();
    }
  }

  static class Fighter extends Player {
    Fighter(net.minecraft.world.level.Level level) { super(level, new com.mojang.authlib.GameProfile(new UUID(1, 2), "Fighter")); }
    @Override public net.minecraft.world.level.GameType gameMode() { return net.minecraft.world.level.GameType.SURVIVAL; }
  }

  /** A body that records what post-attack effects do to it, standing in for any entity type. */
  static class Recorder extends Player {
    JsonArray actions = new JsonArray();
    Recorder(net.minecraft.world.level.Level level) { super(level, new com.mojang.authlib.GameProfile(new UUID(3, 4), "Recorder")); }
    @Override public net.minecraft.world.level.GameType gameMode() { return net.minecraft.world.level.GameType.SURVIVAL; }
    @Override public void igniteForTicks(int ticks) { var a = new JsonArray(); a.add("ignite"); a.add(ticks); actions.add(a); }
    @Override public boolean addEffect(net.minecraft.world.effect.MobEffectInstance e, Entity source) {
      var a = new JsonArray(); a.add("mob_effect"); a.add(e.getEffect().unwrapKey().orElseThrow().identifier().toString());
      a.add(e.getDuration()); a.add(e.getAmplifier()); actions.add(a); return true;
    }
    @Override public boolean hurtServer(ServerLevel level, DamageSource source, float damage) {
      var a = new JsonArray(); a.add("damage"); a.add(damage); a.add(source.typeHolder().unwrapKey().orElseThrow().identifier().toString());
      actions.add(a); return true;
    }
  }

  static Recorder recorder(String type) throws Exception {
    var r = new Recorder(level);
    var field = Entity.class.getDeclaredField("type");
    field.setAccessible(true);
    unsafe.putObject(r, unsafe.objectFieldOffset(field), BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(type)));
    return r;
  }

  /** `doPostAttackEffectsWithItemSource` with one shared random: what each party took. */
  static void postAttack() throws Exception {
    var random = new Random(37L);
    var weapons = new ArrayList<Map<String, Integer>>();
    weapons.add(Map.of());
    for (int l = 1; l <= 3; l++) weapons.add(one("minecraft:fire_aspect", l));
    for (int l = 1; l <= 5; l++) weapons.add(one("minecraft:bane_of_arthropods", l));
    weapons.add(Map.of("minecraft:fire_aspect", 2, "minecraft:bane_of_arthropods", 5));
    var armour = List.of(Map.<String, Integer>of(), one("minecraft:thorns", 1), one("minecraft:thorns", 3), one("minecraft:thorns", 10));
    for (var victimType : List.of("minecraft:zombie", "minecraft:spider", "minecraft:player")) {
      for (var w : weapons) {
        for (var a : armour) {
          for (var melee : List.of(true, false)) {
            long seed = random.nextLong();
            var shared = RandomSource.create(seed);
            var victim = recorder(victimType);
            var attacker = recorder("minecraft:player");
            var arrow = entity("minecraft:arrow");
            for (var e : List.of((Entity) victim, attacker)) {
              var field = Entity.class.getDeclaredField("random");
              field.setAccessible(true);
              unsafe.putObject(e, unsafe.objectFieldOffset(field), shared);
            }
            var lf = net.minecraft.world.level.Level.class.getDeclaredField("random");
            lf.setAccessible(true);
            unsafe.putObject(level, unsafe.objectFieldOffset(lf), shared);
            var weapon = stack("minecraft:iron_sword", w);
            attacker.setItemSlot(EquipmentSlot.MAINHAND, weapon);
            var chest = stack("minecraft:iron_chestplate", a);
            victim.setItemSlot(EquipmentSlot.CHEST, chest);
            var damage = melee ? source("minecraft:player_attack", attacker, attacker) : source("minecraft:arrow", arrow, attacker);
            EnchantmentHelper.doPostAttackEffectsWithItemSource(level, victim, damage, weapon);
            var o = new JsonObject();
            o.addProperty("hook", "post_attack");
            o.add("weapon", levels(weapon));
            o.add("armour", levels(chest));
            o.add("this", view(victim));
            o.add("attacker", view(attacker));
            o.add("direct", view(damage.getDirectEntity()));
            var d = new JsonArray();
            d.add(damage.typeHolder().unwrapKey().orElseThrow().identifier().toString());
            d.add(damage.isDirect());
            o.add("damage", d);
            o.addProperty("seed", seed);
            o.add("victim_took", victim.actions);
            o.add("attacker_took", attacker.actions);
            o.addProperty("armour_damage", chest.getDamageValue());
            cases.add(o);
          }
        }
      }
    }
  }

  static sun.misc.Unsafe unsafe;
  static Arena level;
  static HolderLookup.Provider lookup;
  static JsonArray cases = new JsonArray();

  static Entity entity(String type) throws Exception {
    if (type.equals("minecraft:player")) return new Fighter(level);
    var factory = EntityType.class.getDeclaredField("factory");
    factory.setAccessible(true);
    var entityType = BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(type));
    return ((EntityType.EntityFactory<?>) factory.get(entityType)).create((EntityType) entityType, level);
  }

  static void seed(Entity entity, long seed) throws Exception {
    var field = Entity.class.getDeclaredField("random");
    field.setAccessible(true);
    unsafe.putObject(entity, unsafe.objectFieldOffset(field), RandomSource.create(seed));
  }

  static void seed(long seed) throws Exception {
    var field = net.minecraft.world.level.Level.class.getDeclaredField("random");
    field.setAccessible(true);
    unsafe.putObject(level, unsafe.objectFieldOffset(field), RandomSource.create(seed));
  }

  static ItemStack stack(String item, Map<String, Integer> enchantments) {
    var stack = new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(item)));
    var registry = lookup.lookupOrThrow(Registries.ENCHANTMENT);
    enchantments.forEach((e, l) -> stack.enchant(registry.getOrThrow(ResourceKey.create(Registries.ENCHANTMENT, Identifier.parse(e))), l));
    return stack;
  }

  static JsonArray levels(ItemStack stack) {
    var out = new JsonArray();
    stack.getEnchantments().entrySet().forEach(e -> {
      var pair = new JsonArray();
      pair.add(e.getKey().unwrapKey().orElseThrow().identifier().toString());
      pair.add(e.getIntValue());
      out.add(pair);
    });
    return out;
  }

  static JsonElement view(Entity entity) {
    if (entity == null) return JsonNull.INSTANCE;
    var o = new JsonObject();
    o.addProperty("type", BuiltInRegistries.ENTITY_TYPE.getKey(entity.getType()).toString());
    o.addProperty("on_ground", entity.onGround());
    o.addProperty("in_water", entity.isInWater());
    o.addProperty("fall_distance", entity.fallDistance);
    o.addProperty("tick_count", entity.tickCount);
    return o;
  }

  static DamageSource source(String type, Entity direct, Entity causing) {
    Holder<DamageType> holder = level.registryAccess().lookupOrThrow(Registries.DAMAGE_TYPE)
        .getOrThrow(ResourceKey.create(Registries.DAMAGE_TYPE, Identifier.parse(type)));
    return new DamageSource(holder, direct, causing);
  }

  static void add(String hook, ItemStack stack, String tool, Entity self, DamageSource damage, long seed, float input, float output) {
    var o = new JsonObject();
    o.addProperty("hook", hook);
    o.add("enchantments", levels(stack));
    o.addProperty("item", BuiltInRegistries.ITEM.getKey(stack.getItem()).toString());
    o.addProperty("tool", tool);
    o.add("this", view(self));
    if (damage != null) {
      o.add("attacker", view(damage.getEntity()));
      o.add("direct", view(damage.getDirectEntity()));
      var d = new JsonArray();
      d.add(damage.typeHolder().unwrapKey().orElseThrow().identifier().toString());
      d.add(damage.isDirect());
      o.add("damage", d);
    }
    o.addProperty("seed", seed);
    o.addProperty("input", input);
    o.addProperty("output", output);
    cases.add(o);
  }

  static Map<String, Integer> one(String e, int l) { return Map.of(e, l); }

  static List<String> names() {
    var out = new ArrayList<String>();
    lookup.lookupOrThrow(Registries.ENCHANTMENT).listElementIds().forEach(k -> out.add(k.identifier().toString()));
    Collections.sort(out);
    return out;
  }

  static int max(String name) {
    return lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(ResourceKey.create(Registries.ENCHANTMENT, Identifier.parse(name))).value().getMaxLevel();
  }

  static void modifiers() {
    var out = new JsonArray();
    for (var name : names()) {
      for (int l = 1; l <= max(name) + 1; l++) {
        var stack = stack("minecraft:stone", one(name, l));
        for (var slot : EquipmentSlot.values()) {
          var list = new JsonArray();
          EnchantmentHelper.forEachModifier(stack, slot, (attribute, modifier) -> {
            var m = new JsonArray();
            m.add(attribute.unwrapKey().orElseThrow().identifier().toString());
            m.add(modifier.id().toString());
            m.add(modifier.amount());
            m.add(modifier.operation().id());
            list.add(m);
          });
          if (list.isEmpty()) continue;
          var o = new JsonObject();
          o.addProperty("hook", "modifiers");
          o.add("enchantments", levels(stack));
          o.addProperty("slot", slot.getSerializedName());
          o.add("modifiers", list);
          out.add(o);
        }
      }
    }
    out.forEach(cases::add);
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    // The data pack's tags: of the static registries (the entity types Smite
    // and Bane find) and of the damage types (protection's requirements).
    var damageTypes = registry(Registries.DAMAGE_TYPE);
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY));
      pending.forEach(Registry.PendingTags::apply);
      net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, new RegistryAccess.ImmutableRegistryAccess(List.of(damageTypes)).freeze())
          .forEach(Registry.PendingTags::apply);
    }
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    level = (Arena) unsafe.allocateInstance(Arena.class);
    level.server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
    level.server.debug = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    level.server.registries = new net.minecraft.server.ReloadableServerRegistries.Holder(lookup);
    var registries = new ArrayList<Registry<?>>();
    registries.add(damageTypes);
    registries.add(registry(Registries.ENCHANTMENT));
    BuiltInRegistries.REGISTRY.forEach(r -> registries.add(r));
    level.access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    seed(0L);

    modifiers();
    postAttack();
    var random = new Random(20261031L);

    // Item-filtered counts: the tool context is the stack itself, or the ammo.
    for (var item : List.of("minecraft:diamond_pickaxe", "minecraft:iron_chestplate", "minecraft:bow", "minecraft:elytra")) {
      for (int l = 0; l <= 4; l++) {
        for (int amount : new int[]{1, 3, 20, 200}) {
          var stack = stack(item, l == 0 ? Map.of() : one("minecraft:unbreaking", l));
          long s = random.nextLong();
          seed(s);
          add("item_damage", stack, item, null, null, s, amount, EnchantmentHelper.processDurabilityChange(level, stack, amount));
        }
      }
    }
    for (var e : List.of(Map.<String, Integer>of(), one("minecraft:silk_touch", 1), one("minecraft:fortune", 3))) {
      var stack = stack("minecraft:diamond_pickaxe", e);
      for (int amount : new int[]{0, 3, 7})
        add("block_experience", stack, "minecraft:diamond_pickaxe", null, null, 0L, amount, EnchantmentHelper.processBlockExperience(level, stack, amount));
    }
    for (var e : List.of(Map.<String, Integer>of(), one("minecraft:mending", 1))) {
      var stack = stack("minecraft:iron_boots", e);
      for (int amount : new int[]{1, 5, 17})
        add("repair_with_xp", stack, "minecraft:iron_boots", null, null, 0L, amount, EnchantmentHelper.modifyDurabilityToRepairFromXp(level, stack, amount));
    }
    for (var weapon : List.of("minecraft:bow", "minecraft:crossbow")) {
      for (var e : List.of(Map.<String, Integer>of(), one("minecraft:infinity", 1), one("minecraft:piercing", 1), one("minecraft:piercing", 4))) {
        var stack = stack(weapon, e);
        for (var ammo : List.of("minecraft:arrow", "minecraft:spectral_arrow", "minecraft:tipped_arrow", "minecraft:firework_rocket")) {
          var ammoStack = stack(ammo, Map.of());
          add("ammo_use", stack, ammo, null, null, 0L, 1, EnchantmentHelper.processAmmoUse(level, stack, ammoStack, 1));
          add("projectile_piercing", stack, ammo, null, null, 0L, 0, EnchantmentHelper.getPiercingCount(level, stack, ammoStack));
        }
      }
    }

    // Entity-filtered values.
    var shooter = entity("minecraft:player");
    for (var e : List.of(Map.<String, Integer>of(), one("minecraft:multishot", 1), one("minecraft:multishot", 3))) {
      var stack = stack("minecraft:crossbow", e);
      add("projectile_count", stack, null, shooter, null, 0L, 1, EnchantmentHelper.processProjectileCount(level, stack, shooter, 1));
      add("projectile_spread", stack, null, shooter, null, 0L, 0, EnchantmentHelper.processProjectileSpread(level, stack, shooter, 0.0F));
    }
    for (var l = 0; l <= 4; l++) {
      var stack = stack("minecraft:trident", l == 0 ? Map.of() : one("minecraft:loyalty", l));
      for (var type : List.of("minecraft:trident", "minecraft:arrow")) {
        var trident = entity(type);
        add("trident_return_acceleration", stack, null, trident, null, 0L, 0,
            EnchantmentHelper.getTridentReturnToOwnerAcceleration(level, stack, trident));
      }
      var rod = stack("minecraft:fishing_rod", l == 0 ? Map.of() : Map.of("minecraft:luck_of_the_sea", l, "minecraft:lure", l));
      add("fishing_luck_bonus", rod, null, shooter, null, 0L, 0, EnchantmentHelper.getFishingLuckBonus(level, rod, shooter));
      add("fishing_time_reduction", rod, null, shooter, null, 0L, 0, EnchantmentHelper.getFishingTimeReduction(level, rod, shooter));
      var crossbow = stack("minecraft:crossbow", l == 0 ? Map.of() : one("minecraft:quick_charge", l));
      add("crossbow_charge_time", crossbow, null, null, null, 0L, 1.25F,
          EnchantmentHelper.modifyCrossbowChargingTime(crossbow, (LivingEntity) shooter, 1.25F));
      var riptide = stack("minecraft:trident", l == 0 ? Map.of() : one("minecraft:riptide", l));
      add("trident_spin_attack_strength", riptide, null, null, null, 0L, 0,
          EnchantmentHelper.getTridentSpinAttackStrength(riptide, (LivingEntity) shooter));
    }

    // Damage-filtered values: victims by type, sources with their attackers.
    var victims = new ArrayList<Entity>();
    for (var type : List.of("minecraft:zombie", "minecraft:spider", "minecraft:skeleton", "minecraft:drowned", "minecraft:guardian",
        "minecraft:iron_golem", "minecraft:player", "minecraft:ender_dragon"))
      victims.add(entity(type));
    var player = entity("minecraft:player");
    var arrow = entity("minecraft:arrow");
    var trident = entity("minecraft:trident");
    var zombie = entity("minecraft:zombie");
    var sources = List.of(
        source("minecraft:player_attack", player, player),
        source("minecraft:mob_attack", zombie, zombie),
        source("minecraft:arrow", arrow, player),
        source("minecraft:trident", trident, player),
        source("minecraft:mace_smash", player, player));
    var weapons = new ArrayList<ItemStack>();
    for (var name : List.of("minecraft:sharpness", "minecraft:smite", "minecraft:bane_of_arthropods", "minecraft:impaling",
        "minecraft:power", "minecraft:knockback", "minecraft:punch", "minecraft:breach", "minecraft:density"))
      for (int l : new int[]{1, max(name)})
        weapons.add(stack("minecraft:netherite_sword", one(name, l)));
    weapons.add(stack("minecraft:netherite_sword", Map.of("minecraft:sharpness", 5, "minecraft:smite", 5, "minecraft:density", 2)));
    for (var victim : victims) {
      for (var damage : sources) {
        for (var weapon : weapons) {
          add("damage", weapon, null, victim, damage, 0L, 7.0F, EnchantmentHelper.modifyDamage(level, weapon, victim, damage, 7.0F));
          add("knockback", weapon, null, victim, damage, 0L, 0.5F, EnchantmentHelper.modifyKnockback(level, weapon, victim, damage, 0.5F));
          add("armor_effectiveness", weapon, null, victim, damage, 0L, 1.0F,
              EnchantmentHelper.modifyArmorEffectiveness(level, weapon, victim, damage, 1.0F));
          add("smash_damage_per_fallen_block", weapon, null, victim, damage, 0L, 0.0F,
              EnchantmentHelper.modifyFallBasedDamage(level, weapon, victim, damage, 0.0F));
        }
      }
    }

    // Looting's drop chance: the attacker's main hand.
    for (var l = 0; l <= 3; l++) {
      var looter = (Player) entity("minecraft:player");
      var sword = stack("minecraft:iron_sword", l == 0 ? Map.of() : one("minecraft:looting", l));
      looter.setItemSlot(EquipmentSlot.MAINHAND, sword);
      for (var killer : List.of((Entity) looter, zombie)) {
        var victim = (LivingEntity) entity("minecraft:zombie");
        var blow = source(killer == looter ? "minecraft:player_attack" : "minecraft:mob_attack", killer, killer);
        add("equipment_drops", sword, null, victim, blow, 0L, 0.085F,
            EnchantmentHelper.processEquipmentDropChance(level, victim, blow, 0.085F));
      }
    }

    // Protection and immunity of one worn piece.
    var envSources = new ArrayList<DamageSource>();
    for (var type : List.of("minecraft:fall", "minecraft:in_fire", "minecraft:hot_floor", "minecraft:explosion", "minecraft:arrow",
        "minecraft:generic", "minecraft:out_of_world", "minecraft:lava", "minecraft:mob_attack"))
      envSources.add(source(type, null, null));
    for (var name : List.of("minecraft:protection", "minecraft:fire_protection", "minecraft:blast_protection",
        "minecraft:projectile_protection", "minecraft:feather_falling", "minecraft:frost_walker")) {
      for (int l : new int[]{1, max(name)}) {
        var boots = stack("minecraft:iron_boots", one(name, l));
        for (var damage : envSources) {
          var wearer = (LivingEntity) entity("minecraft:zombie");
          wearer.setItemSlot(EquipmentSlot.FEET, boots);
          add("damage_protection", boots, null, wearer, damage, 0L, 0.0F, EnchantmentHelper.getDamageProtection(level, wearer, damage));
          add("immune", boots, null, wearer, damage, 0L, 0.0F, EnchantmentHelper.isImmuneToDamage(level, wearer, damage) ? 1.0F : 0.0F);
        }
      }
    }

    Files.writeString(Path.of(args[0]), new Gson().toJson(cases) + "\n");
    System.out.println("PASS: " + cases.size() + " enchantment effect cases");
  }

  static <T> MappedRegistry<T> registry(ResourceKey<Registry<T>> key) {
    var source = lookup.lookupOrThrow(key);
    var result = new MappedRegistry<T>(key, com.mojang.serialization.Lifecycle.stable());
    for (var id : source.listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString())).toList())
      result.register(id, source.getOrThrow(id).value(), RegistrationInfo.BUILT_IN);
    result.freeze();
    return result;
  }
}
