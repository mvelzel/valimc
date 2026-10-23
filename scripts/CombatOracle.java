import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;

/**
 * Melee combat facts (VMC-037n).
 *
 * Usage: CombatOracle facts OUT.json — per item whose defaults carry any of them, its
 * `attribute_modifiers`, `weapon`, `blocks_attacks`, `damage_type` and
 * `minimum_attack_charge` components as vanilla's codecs write them; the player's base attributes (`Player.createAttributes`); and per modelled mob type
 * its base experience reward (the `xpReward` its constructor sets), hurt and death sounds and
 * sound source; the sound event, sound source and particle type ids combat sends; and each damage
 * type's death message id and difficulty scaling.
 *
 * Usage: CombatOracle cases OUT.json — vanilla's melee on probe entities: `Player.attack` on a
 * zombie (weapons with and without enchantments, attack strengths, standing, falling and sprinting
 * attackers, armored and knockback-resistant targets, a second zombie beside it for the sweep),
 * recording the target's health and motion, the swept zombie's health, the sounds, particles and
 * critical hit animations and the weapon's wear; and `Zombie.doHurtTarget` on a player (armor sets,
 * difficulties, a zombie's sword, a shield raised long enough or not, facing the zombie or not),
 * recording the player's health and motion and the wear of its armor and shield.
 *
 * Usage: CombatOracle packets OUT.json — vanilla's wire bytes of the packets combat sends:
 * damage events with a cause and direct entity, sounds, the sweep and damage indicator
 * particles and the critical hit animations.
 */
public class CombatOracle {
  static List<DataComponentType<?>> components() {
    return List.of(DataComponents.ATTRIBUTE_MODIFIERS, DataComponents.WEAPON, DataComponents.BLOCKS_ATTACKS,
        DataComponents.DAMAGE_TYPE, DataComponents.MINIMUM_ATTACK_CHARGE);
  }
  // VMC-037o: an egg's chickens, an ender pearl's endermites; VMC-041a: pigs and piglins.
  static final List<String> MOBS = List.of("minecraft:zombie", "minecraft:chicken", "minecraft:endermite", "minecraft:pig",
      "minecraft:piglin", "minecraft:blaze", "minecraft:zombified_piglin",
      // VMC-043b: the overworld hostiles.
      "minecraft:husk", "minecraft:zombie_villager", "minecraft:drowned", "minecraft:skeleton", "minecraft:stray",
      "minecraft:bogged", "minecraft:creeper", "minecraft:spider", "minecraft:cave_spider", "minecraft:enderman",
      "minecraft:witch", "minecraft:slime", "minecraft:phantom", "minecraft:silverfish",
      // VMC-043e: the End's mobs.
      "minecraft:shulker",
      // VMC-043c: farm animals.
      "minecraft:cow", "minecraft:mooshroom", "minecraft:sheep", "minecraft:rabbit");
  static final List<String> SOUNDS = List.of("minecraft:entity.player.attack.strong",
      "minecraft:entity.player.attack.weak", "minecraft:entity.player.attack.crit",
      "minecraft:entity.player.attack.sweep", "minecraft:entity.player.attack.knockback",
      "minecraft:entity.player.attack.nodamage", "minecraft:item.shield.block", "minecraft:item.shield.break",
      "minecraft:entity.item.break", "minecraft:entity.player.hurt", "minecraft:entity.player.death",
      // VMC-037o: bows, crossbows, thrown items, ender pearls and eyes, skeletons.
      "minecraft:entity.arrow.shoot", "minecraft:entity.arrow.hit", "minecraft:entity.arrow.hit_player",
      "minecraft:item.crossbow.shoot", "minecraft:item.crossbow.hit", "minecraft:item.crossbow.loading_start",
      "minecraft:item.crossbow.loading_middle", "minecraft:item.crossbow.loading_end",
      "minecraft:entity.snowball.throw", "minecraft:entity.egg.throw", "minecraft:entity.ender_pearl.throw",
      "minecraft:entity.splash_potion.throw", "minecraft:entity.player.teleport",
      "minecraft:entity.ender_eye.launch", "minecraft:entity.ender_eye.death", "minecraft:entity.skeleton.shoot");
  static final List<String> PARTICLES = List.of("minecraft:sweep_attack", "minecraft:damage_indicator",
      "minecraft:dragon_breath");

  @SuppressWarnings({"unchecked", "rawtypes"})
  static JsonElement encode(DataComponentType type, Object value, com.mojang.serialization.DynamicOps<JsonElement> ops) {
    return (JsonElement) type.codecOrThrow().encodeStart(ops, value).getOrThrow();
  }

  static JsonObject facts(HolderLookup.Provider lookup) throws Exception {
    var levelRegistries = new ArrayList<Registry<?>>();
    levelRegistries.add(registry(Registries.CHICKEN_VARIANT, lookup));
    levelRegistries.add(registry(Registries.CHICKEN_SOUND_VARIANT, lookup));
    levelRegistries.add(registry(Registries.PIG_VARIANT, lookup));
    levelRegistries.add(registry(Registries.PIG_SOUND_VARIANT, lookup));
    levelRegistries.add(registry(Registries.COW_VARIANT, lookup));
    levelRegistries.add(registry(Registries.COW_SOUND_VARIANT, lookup));
    BuiltInRegistries.REGISTRY.forEach(r -> levelRegistries.add(r));
    Probe.access = new RegistryAccess.ImmutableRegistryAccess(levelRegistries).freeze();
    var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
    var items = new JsonObject();
    BuiltInRegistries.ITEM.keySet().stream().sorted(Comparator.comparing(Identifier::toString)).forEach(id -> {
      var item = BuiltInRegistries.ITEM.getValue(id);
      var components = new JsonObject();
      for (var type : components()) {
        var value = item.components().get(type);
        if (value == null) continue;
        if (type == DataComponents.ATTRIBUTE_MODIFIERS && ((net.minecraft.world.item.component.ItemAttributeModifiers) value).modifiers().isEmpty()) continue;
        components.add(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type).toString(), encode(type, value, ops));
      }
      if (components.size() > 0) items.add(id.toString(), components);
    });
    var attributes = new JsonObject();
    var supplier = Player.createAttributes().build();
    BuiltInRegistries.ATTRIBUTE.listElements().sorted(Comparator.comparing(h -> h.key().identifier().toString())).forEach(h -> {
      if (supplier.hasAttribute(h)) attributes.addProperty(h.key().identifier().toString(), supplier.getBaseValue(h));
    });
    var experience = new JsonObject();
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    var xp = Mob.class.getDeclaredField("xpReward");
    xp.setAccessible(true);
    var mobs = new JsonObject();
    var hurt = LivingEntity.class.getDeclaredMethod("getHurtSound", net.minecraft.world.damagesource.DamageSource.class);
    var death = LivingEntity.class.getDeclaredMethod("getDeathSound");
    hurt.setAccessible(true);
    death.setAccessible(true);
    var generic = lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(net.minecraft.world.damagesource.DamageTypes.GENERIC);
    for (var name : MOBS) {
      var type = BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(name));
      var mob = Probe.mob(type, unsafe);
      experience.addProperty(name, xp.getInt(mob));
      var row = new JsonObject();
      row.addProperty("hurt_sound", sound((net.minecraft.sounds.SoundEvent) hurt.invoke(mob, new net.minecraft.world.damagesource.DamageSource(generic))));
      row.addProperty("death_sound", sound((net.minecraft.sounds.SoundEvent) death.invoke(mob)));
      row.addProperty("sound_source", mob.getSoundSource().ordinal());
      // An animal's reward is 1 to 3 (`Animal.getBaseExperienceReward`).
      row.addProperty("animal", mob instanceof net.minecraft.world.entity.animal.Animal);
      mobs.add(name, row);
    }
    var sounds = new JsonObject();
    for (var name : SOUNDS) sounds.addProperty(name, BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(name))));
    for (var row : mobs.entrySet())
      for (var key : List.of("hurt_sound", "death_sound")) {
        var name = row.getValue().getAsJsonObject().get(key).getAsString();
        sounds.addProperty(name, BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(name))));
      }
    var sources = new JsonObject();
    for (var source : net.minecraft.sounds.SoundSource.values()) sources.addProperty(source.getName(), source.ordinal());
    var particles = new JsonObject();
    for (var name : PARTICLES) particles.addProperty(name, BuiltInRegistries.PARTICLE_TYPE.getId(BuiltInRegistries.PARTICLE_TYPE.getValue(Identifier.parse(name))));
    var out = new JsonObject();
    out.add("items", items);
    out.add("player_attributes", attributes);
    out.add("experience", experience);
    out.add("mobs", mobs);
    out.add("sounds", sounds);
    out.add("sound_sources", sources);
    out.add("particles", particles);
    var damageTypes = new JsonObject();
    lookup.lookupOrThrow(Registries.DAMAGE_TYPE).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).forEach(h -> {
          var row = new JsonObject();
          row.addProperty("message_id", h.value().msgId());
          row.addProperty("scaling", h.value().scaling().getSerializedName());
          damageTypes.add(h.key().identifier().toString(), row);
        });
    out.add("damage_types", damageTypes);
    return out;
  }

  static class ProbeServer extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers debug;
    net.minecraft.server.ReloadableServerRegistries.Holder registries;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    @Override public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
    @Override public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers() { return debug; }
  }

  /** A level no constructor reads from, for building entities outside a server. */
  static class Probe extends net.minecraft.server.level.ServerLevel {
    ProbeServer server;
    @Override public net.minecraft.server.MinecraftServer getServer() { return server; }
    private Probe() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    int ids;
    @Override public int getNextEntityId() { return ++ids; }
    @Override public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    // A drowned's goals read the sea level (VMC-043b).
    @Override public int getSeaLevel() { return 63; }
    // A chicken's and a pig's variants (VMC-037o, VMC-041a) come from the level's registries.
    static RegistryAccess access;
    @Override public RegistryAccess registryAccess() { return access; }

    static Mob mob(EntityType<?> type, sun.misc.Unsafe unsafe) throws Exception {
      var level = (Probe) unsafe.allocateInstance(Probe.class);
      level.server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
      level.server.debug = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
      // The type's own factory, without `create`'s spawn checks.
      var factory = EntityType.class.getDeclaredField("factory");
      factory.setAccessible(true);
      return (Mob) ((EntityType.EntityFactory) factory.get(type)).create(type, level);
    }
  }

  /** A level that records what melee plays and shows, and answers its difficulty. */
  static class Arena extends net.minecraft.server.level.ServerLevel {
    ProbeServer server;
    RegistryAccess access;
    net.minecraft.world.Difficulty difficulty = net.minecraft.world.Difficulty.NORMAL;
    List<String> sounds = new ArrayList<>();
    List<String> particles = new ArrayList<>();
    List<LivingEntity> around = new ArrayList<>();
    int ids;
    private Arena() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public net.minecraft.server.MinecraftServer getServer() { return server; }
    @Override public RegistryAccess registryAccess() { return access; }
    net.minecraft.world.damagesource.DamageSources sources;
    @Override public net.minecraft.world.damagesource.DamageSources damageSources() {
      if (sources == null) sources = new net.minecraft.world.damagesource.DamageSources(access);
      return sources;
    }
    @Override public int getNextEntityId() { return ++ids; }
    @Override public net.minecraft.world.flag.FeatureFlagSet enabledFeatures() { return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS; }
    @Override public net.minecraft.world.Difficulty getDifficulty() { return difficulty; }
    @Override public long getGameTime() { return 1000L; }
    net.minecraft.server.ServerScoreboard scoreboard;
    @Override public net.minecraft.server.ServerScoreboard getScoreboard() {
      if (scoreboard == null) scoreboard = new net.minecraft.server.ServerScoreboard(server);
      return scoreboard;
    }
    // Air everywhere: nothing to climb, stand in or collide with.
    @Override public net.minecraft.world.level.block.state.BlockState getBlockState(net.minecraft.core.BlockPos pos) {
      return net.minecraft.world.level.block.Blocks.AIR.defaultBlockState();
    }
    @Override public net.minecraft.world.level.material.FluidState getFluidState(net.minecraft.core.BlockPos pos) {
      return net.minecraft.world.level.material.Fluids.EMPTY.defaultFluidState();
    }
    @Override public net.minecraft.world.DifficultyInstance getCurrentDifficultyAt(net.minecraft.core.BlockPos pos) {
      return new net.minecraft.world.DifficultyInstance(difficulty, 0L, 0L, 0.0F);
    }
    @Override public void playSeededSound(Entity except, double x, double y, double z, Holder<net.minecraft.sounds.SoundEvent> sound,
        net.minecraft.sounds.SoundSource source, float volume, float pitch, long seed) {
      sounds.add(sound.value().location().toString());
    }
    @Override public void playSeededSound(Entity except, Entity at, Holder<net.minecraft.sounds.SoundEvent> sound,
        net.minecraft.sounds.SoundSource source, float volume, float pitch, long seed) {
      sounds.add(sound.value().location().toString());
    }
    @Override public <T extends net.minecraft.core.particles.ParticleOptions> int sendParticles(T type, double x, double y, double z, int count,
        double dx, double dy, double dz, double speed) {
      particles.add(BuiltInRegistries.PARTICLE_TYPE.getKey(type.getType()) + ":" + count);
      return 0;
    }
    @Override public void broadcastEntityEvent(Entity entity, byte event) {}
    @Override public void broadcastDamageEvent(Entity entity, net.minecraft.world.damagesource.DamageSource source) {}
    @Override public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event, net.minecraft.world.phys.Vec3 pos,
        net.minecraft.world.level.gameevent.GameEvent.Context context) {}
    @Override public <T extends Entity> List<T> getEntitiesOfClass(Class<T> type, net.minecraft.world.phys.AABB box, java.util.function.Predicate<? super T> predicate) {
      var out = new ArrayList<T>();
      for (var e : around) if (type.isInstance(e) && e.getBoundingBox().intersects(box) && predicate.test(type.cast(e))) out.add(type.cast(e));
      return out;
    }
  }

  /** The attacker or defender: a survival player whose known movement, speed and crits are given. */
  static class Fighter extends Player {
    net.minecraft.world.phys.Vec3 known = net.minecraft.world.phys.Vec3.ZERO;
    int crits, magic;
    Fighter(net.minecraft.world.level.Level level) { super(level, new com.mojang.authlib.GameProfile(new UUID(1, 2), "Fighter")); }
    @Override public net.minecraft.world.level.GameType gameMode() { return net.minecraft.world.level.GameType.SURVIVAL; }
    @Override public net.minecraft.world.phys.Vec3 getKnownMovement() { return known; }
    @Override public float getSpeed() { return (float) getAttributeValue(net.minecraft.world.entity.ai.attributes.Attributes.MOVEMENT_SPEED); }
    // As `ServerPlayer` does: the weapon's enchantments add their damage.
    @Override protected float getEnchantedDamage(Entity entity, float dmg, net.minecraft.world.damagesource.DamageSource source) {
      return net.minecraft.world.item.enchantment.EnchantmentHelper.modifyDamage((net.minecraft.server.level.ServerLevel) level(), getWeaponItem(), entity, source, dmg);
    }
    @Override public void crit(Entity entity) { crits++; }
    @Override public void magicCrit(Entity entity) { magic++; }
  }

  static net.minecraft.world.entity.monster.zombie.Zombie zombie(Arena level, double x, double z, float yaw, boolean ground) throws Exception {
    var zombie = (net.minecraft.world.entity.monster.zombie.Zombie) mobIn(BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:zombie")), level);
    zombie.getAttribute(net.minecraft.world.entity.ai.attributes.Attributes.MAX_HEALTH).setBaseValue(100.0);
    zombie.setHealth(100.0F);
    zombie.snapTo(x, 64.0, z, yaw, 0.0F);
    ground(zombie, ground);
    return zombie;
  }

  // `detectEquipmentUpdates` without its broadcast: the equipment's attribute
  // modifiers and enchantment attribute effects apply, as a tick applies them.
  @SuppressWarnings("unchecked")
  static void equip(LivingEntity entity) throws Exception {
    var last = LivingEntity.class.getDeclaredField("lastEquipmentItems");
    last.setAccessible(true);
    var items = (Map<EquipmentSlot, ItemStack>) last.get(entity);
    var collect = LivingEntity.class.getDeclaredMethod("collectEquipmentChanges", Map.class);
    collect.setAccessible(true);
    var changed = (Map<EquipmentSlot, ItemStack>) collect.invoke(entity, items);
    if (changed != null) changed.forEach((slot, stack) -> items.put(slot, stack.copy()));
  }

  // `onGround` without the supporting block search a probe level cannot answer.
  static void ground(Entity entity, boolean ground) throws Exception {
    var field = Entity.class.getDeclaredField("onGround");
    field.setAccessible(true);
    field.setBoolean(entity, ground);
  }

  static Mob mobIn(EntityType<?> type, net.minecraft.world.level.Level level) throws Exception {
    var factory = EntityType.class.getDeclaredField("factory");
    factory.setAccessible(true);
    return (Mob) ((EntityType.EntityFactory) factory.get(type)).create(type, level);
  }

  static ItemStack item(HolderLookup.Provider lookup, String name, Map<String, Integer> enchantments) {
    var stack = name.isEmpty() ? ItemStack.EMPTY : new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(name)));
    var registry = lookup.lookupOrThrow(Registries.ENCHANTMENT);
    enchantments.forEach((e, level) -> stack.enchant(registry.getOrThrow(ResourceKey.create(Registries.ENCHANTMENT, Identifier.parse(e))), level));
    return stack;
  }

  static JsonElement stackJson(ItemStack stack) {
    if (stack.isEmpty()) return JsonNull.INSTANCE;
    var o = new JsonObject();
    o.addProperty("item", BuiltInRegistries.ITEM.getKey(stack.getItem()).toString());
    o.addProperty("damage", stack.getDamageValue());
    var e = new JsonObject();
    stack.getEnchantments().entrySet().forEach(x -> e.addProperty(x.getKey().unwrapKey().orElseThrow().identifier().toString(), x.getIntValue()));
    o.add("enchantments", e);
    return o;
  }

  static JsonArray vec(net.minecraft.world.phys.Vec3 v) {
    var a = new JsonArray();
    a.add(v.x);
    a.add(v.y);
    a.add(v.z);
    return a;
  }

  static JsonObject cases(HolderLookup.Provider lookup) throws Exception {
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    var level = (Arena) unsafe.allocateInstance(Arena.class);
    level.server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
    level.server.debug = new net.minecraft.util.debug.ServerDebugSubscribers(level.server);
    level.server.registries = new net.minecraft.server.ReloadableServerRegistries.Holder(lookup);
    level.access = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    var registries = new ArrayList<Registry<?>>();
    registries.add(registry(Registries.DAMAGE_TYPE, lookup));
    registries.add(registry(Registries.ENCHANTMENT, lookup));
    BuiltInRegistries.REGISTRY.forEach(r -> registries.add(r));
    level.access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    for (var f : List.of("random", "soundSeedGenerator")) {
      var field = net.minecraft.world.level.Level.class.getDeclaredField(f);
      field.setAccessible(true);
      unsafe.putObject(level, unsafe.objectFieldOffset(field), net.minecraft.util.RandomSource.create(7L));
    }
    for (var f : List.of("sounds", "particles", "around")) {
      var field = Arena.class.getDeclaredField(f);
      field.setAccessible(true);
      field.set(level, new ArrayList<>());
    }
    var ticker = LivingEntity.class.getDeclaredField("attackStrengthTicker");
    ticker.setAccessible(true);
    var random = new Random(20261023L);
    var attacks = new JsonArray();
    var weapons = List.<Object[]>of(new Object[]{"", Map.of()}, new Object[]{"minecraft:wooden_sword", Map.of()},
        new Object[]{"minecraft:diamond_sword", Map.of()}, new Object[]{"minecraft:netherite_axe", Map.of()},
        new Object[]{"minecraft:iron_sword", Map.of("minecraft:sharpness", 3)},
        new Object[]{"minecraft:diamond_sword", Map.of("minecraft:knockback", 2)},
        new Object[]{"minecraft:diamond_sword", Map.of("minecraft:sweeping_edge", 3)},
        new Object[]{"minecraft:golden_sword", Map.of("minecraft:smite", 2)},
        new Object[]{"minecraft:stone_shovel", Map.of()}, new Object[]{"minecraft:trident", Map.of()});
    for (int i = 0; i < 400; i++) {
      level.sounds.clear();
      level.particles.clear();
      level.around.clear();
      var weapon = weapons.get(i % weapons.size());
      var player = new Fighter(level);
      @SuppressWarnings("unchecked")
      var stack = item(lookup, (String) weapon[0], (Map<String, Integer>) weapon[1]);
      player.setItemInHand(net.minecraft.world.InteractionHand.MAIN_HAND, stack);
      float yaw = (float) (random.nextInt(720) * 0.5 - 180.0);
      player.snapTo(0.5, 64.0, 0.5, yaw, 0.0F);
      int state = random.nextInt(4);
      boolean ground = state != 1;
      ground(player, ground);
      if (state == 1) player.fallDistance = 0.5 + random.nextInt(4);
      if (state == 2) player.setSprinting(true);
      player.known = state == 3 ? new net.minecraft.world.phys.Vec3(0.3, 0, 0.1) : new net.minecraft.world.phys.Vec3(0.05, 0, -0.02);
      int tick = new int[]{0, 3, 8, 12, 13, 25}[random.nextInt(6)];
      ticker.setInt(player, tick);
      double tx = 0.5 + Math.sin(-yaw * Math.PI / 180) * 2.0, tz = 0.5 + Math.cos(-yaw * Math.PI / 180) * 2.0;
      var target = zombie(level, tx, tz, 0.0F, random.nextBoolean());
      int armor = random.nextInt(3);
      if (armor == 1) target.setItemSlot(EquipmentSlot.CHEST, new ItemStack(net.minecraft.world.item.Items.IRON_CHESTPLATE));
      if (armor == 2) target.setItemSlot(EquipmentSlot.CHEST, new ItemStack(net.minecraft.world.item.Items.NETHERITE_CHESTPLATE));
      var beside = zombie(level, tx + 0.8, tz, 0.0F, true);
      equip(player);
      equip(target);
      equip(beside);
      level.around.add(target);
      level.around.add(beside);
      player.attack(target);
      var row = new JsonObject();
      row.add("weapon", stackJson(item(lookup, (String) weapon[0], (Map<String, Integer>) weapon[1])));
      row.addProperty("yaw", yaw);
      row.addProperty("state", state);
      row.addProperty("fall", player.fallDistance);
      row.addProperty("ticker", tick);
      row.addProperty("armor", armor);
      row.addProperty("target_ground", target.onGround());
      row.add("target", vec(target.position()));
      row.add("beside", vec(beside.position()));
      row.addProperty("health", target.getHealth());
      row.add("velocity", vec(target.getDeltaMovement()));
      row.addProperty("beside_health", beside.getHealth());
      row.add("beside_velocity", vec(beside.getDeltaMovement()));
      var sounds = new JsonArray();
      level.sounds.forEach(sounds::add);
      row.add("sounds", sounds);
      var particles = new JsonArray();
      level.particles.forEach(particles::add);
      row.add("particles", particles);
      row.addProperty("crits", player.crits);
      row.addProperty("magic", player.magic);
      row.add("weapon_after", stackJson(player.getMainHandItem()));
      attacks.add(row);
    }
    var hits = new JsonArray();
    var armors = List.<String[]>of(new String[]{}, new String[]{"minecraft:iron_helmet", "minecraft:iron_chestplate", "minecraft:iron_leggings", "minecraft:iron_boots"},
        new String[]{"minecraft:diamond_chestplate", "minecraft:netherite_leggings"}, new String[]{"minecraft:leather_boots"});
    for (int i = 0; i < 240; i++) {
      level.sounds.clear();
      level.difficulty = net.minecraft.world.Difficulty.byId(1 + random.nextInt(3));
      var player = new Fighter(level);
      float yaw = (float) (random.nextInt(8) * 45.0 - 180.0);
      player.snapTo(0.5, 64.0, 0.5, yaw, 0.0F);
      player.setYHeadRot(yaw);
      ground(player, true);
      var armor = armors.get(random.nextInt(armors.size()));
      for (var piece : armor) {
        var stack = new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(piece)));
        player.setItemSlot(stack.get(DataComponents.EQUIPPABLE).slot(), stack);
      }
      int shield = random.nextInt(3);
      int used = new int[]{0, 3, 5, 9}[random.nextInt(4)];
      if (shield > 0) {
        var offhand = new ItemStack(net.minecraft.world.item.Items.SHIELD);
        player.setItemInHand(net.minecraft.world.InteractionHand.OFF_HAND, offhand);
        // `startUsingItem` on the off hand, without its equipment broadcast.
        var flag = LivingEntity.class.getDeclaredMethod("setLivingEntityFlag", int.class, boolean.class);
        flag.setAccessible(true);
        flag.invoke(player, 1, true);
        flag.invoke(player, 2, true);
        var use = LivingEntity.class.getDeclaredField("useItem");
        use.setAccessible(true);
        use.set(player, offhand);
        var remaining = LivingEntity.class.getDeclaredField("useItemRemaining");
        remaining.setAccessible(true);
        remaining.setInt(player, offhand.getUseDuration(player) - used);
      }
      // The zombie east of the player, or behind it.
      double angle = random.nextInt(8) * 45.0;
      double zx = 0.5 + Math.cos(angle * Math.PI / 180) * 1.2, zz = 0.5 + Math.sin(angle * Math.PI / 180) * 1.2;
      var zombie = zombie(level, zx, zz, (float) (angle + 90.0), true);
      if (random.nextInt(3) == 0) zombie.setItemSlot(EquipmentSlot.MAINHAND, new ItemStack(net.minecraft.world.item.Items.IRON_SWORD));
      equip(player);
      equip(zombie);
      boolean hurt = zombie.doHurtTarget(level, player);
      var row = new JsonObject();
      row.addProperty("difficulty", level.difficulty.getId());
      row.addProperty("yaw", yaw);
      var pieces = new JsonArray();
      for (var piece : armor) pieces.add(piece);
      row.add("armor", pieces);
      row.addProperty("shield", shield > 0);
      row.addProperty("used", shield > 0 ? used : -1);
      row.add("zombie", vec(zombie.position()));
      row.addProperty("zombie_yaw", zombie.getYRot());
      row.add("zombie_weapon", stackJson(zombie.getMainHandItem()));
      row.addProperty("hurt", hurt);
      row.addProperty("health", player.getHealth());
      row.add("velocity", vec(player.getDeltaMovement()));
      var worn = new JsonObject();
      for (var slot : EquipmentSlot.values()) {
        var stack = player.getItemBySlot(slot);
        if (!stack.isEmpty()) worn.addProperty(slot.getName(), stack.getDamageValue());
      }
      row.add("worn", worn);
      var sounds = new JsonArray();
      level.sounds.forEach(sounds::add);
      row.add("sounds", sounds);
      hits.add(row);
    }
    var out = new JsonObject();
    out.add("attacks", attacks);
    out.add("hits", hits);
    return out;
  }

  static String sound(net.minecraft.sounds.SoundEvent event) {
    return BuiltInRegistries.SOUND_EVENT.getKey(event).toString();
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  static String wire(RegistryAccess access, Object packet) {
    var buf = new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.buffer(), access);
    try {
      net.minecraft.network.protocol.game.GameProtocols.CLIENTBOUND_TEMPLATE
          .bind(b -> new net.minecraft.network.RegistryFriendlyByteBuf(b, access)).codec()
          .encode(buf, (net.minecraft.network.protocol.Packet) packet);
      var bytes = new byte[buf.readableBytes()];
      buf.readBytes(bytes);
      return HexFormat.of().formatHex(bytes);
    } finally {
      buf.release();
    }
  }

  static JsonObject packets(HolderLookup.Provider lookup) throws Exception {
    var damage = registry(Registries.DAMAGE_TYPE, lookup);
    var access = new RegistryAccess.ImmutableRegistryAccess(List.of(damage, BuiltInRegistries.SOUND_EVENT, BuiltInRegistries.PARTICLE_TYPE)).freeze();
    var out = new JsonObject();
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    var zombie = Probe.mob(BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:zombie")), unsafe);
    for (var type : List.of(net.minecraft.world.damagesource.DamageTypes.PLAYER_ATTACK, net.minecraft.world.damagesource.DamageTypes.MOB_ATTACK))
      for (int[] ids : new int[][]{{7, 9, 9}, {1, 200, 300}, {65000, 2, 2}}) {
        out.addProperty("damage_" + type.identifier().getPath() + "_" + ids[0] + "_" + ids[1] + "_" + ids[2],
            wire(access, new net.minecraft.network.protocol.game.ClientboundDamageEventPacket(ids[0], damage.getOrThrow(type), ids[1], ids[2], Optional.empty())));
      }
    out.addProperty("damage_explosion_5_none_position",
        wire(access, new net.minecraft.network.protocol.game.ClientboundDamageEventPacket(5, damage.getOrThrow(net.minecraft.world.damagesource.DamageTypes.EXPLOSION), -1, -1,
            Optional.of(new net.minecraft.world.phys.Vec3(1.5, -60.25, -1000.125)))));
    long seed = 0x123456789ABCDEFL;
    for (var name : SOUNDS)
      for (var source : List.of(net.minecraft.sounds.SoundSource.PLAYERS, net.minecraft.sounds.SoundSource.HOSTILE)) {
        var holder = BuiltInRegistries.SOUND_EVENT.wrapAsHolder(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(name)));
        out.addProperty("sound_" + name + "_" + source.getName(),
            wire(access, new net.minecraft.network.protocol.game.ClientboundSoundPacket(holder, source, -12.3, 70.0, 4.9, 1.0F, 0.9F, seed)));
        seed = seed * 31 + 7;
      }
    out.addProperty("particles_sweep",
        wire(access, new net.minecraft.network.protocol.game.ClientboundLevelParticlesPacket(net.minecraft.core.particles.ParticleTypes.SWEEP_ATTACK,
            false, false, 10.25, 64.9, -3.5, -0.5F, 0.0F, 0.866F, 0.0F, 0)));
    out.addProperty("particles_damage",
        wire(access, new net.minecraft.network.protocol.game.ClientboundLevelParticlesPacket(net.minecraft.core.particles.ParticleTypes.DAMAGE_INDICATOR,
            false, false, -7.5, 65.0, 2.25, 0.1F, 0.0F, 0.1F, 0.2F, 3)));
    for (int action : new int[]{4, 5}) {
      zombie.setId(42);
      out.addProperty("animate_" + action, wire(access, new net.minecraft.network.protocol.game.ClientboundAnimatePacket(zombie, action)));
    }
    return out;
  }

  static <T> MappedRegistry<T> registry(ResourceKey<Registry<T>> key, HolderLookup.Provider lookup) {
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
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    if (args[0].equals("facts")) {
      Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(facts(lookup)) + "\n");
      System.out.println("PASS: combat facts written");
      return;
    }
    if (args[0].equals("cases")) {
      // The data pack's tags of the static registries (`#minecraft:swords`, the
      // entity types smite and bane find), as a server loads them.
      try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
          List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
        var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY));
        pending.forEach(Registry.PendingTags::apply);
      }
      Files.writeString(Path.of(args[1]), new Gson().toJson(cases(lookup)) + "\n");
      System.out.println("PASS: combat cases written");
      return;
    }
    if (args[0].equals("packets")) {
      Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(packets(lookup)) + "\n");
      System.out.println("PASS: combat packets written");
      return;
    }
    throw new IllegalArgumentException("usage: CombatOracle facts|packets OUT.json");
  }
}
