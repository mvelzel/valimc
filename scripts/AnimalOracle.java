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
import net.minecraft.sounds.SoundEvent;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.Animal;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.phys.Vec3;

/**
 * Farm animals (VMC-043c). `facts OUT` writes what the animals' modules read
 * of vanilla: per animal its baby dimensions and the items it eats
 * (`isFood`), the cow, pig and chicken variants with their spawn selectors
 * (priority and the biome tag each needs), their sound variants' sounds,
 * the types that are `Monster`s (a rabbit avoids them), the flowers a brown
 * mooshroom's stew takes effects from, and the protocol ids
 * of every sound the animals play. `cases OUT` ticks whole vanilla animals
 * as `MobAiOracle cases` does, with what happens to them between ticks
 * (falling in love, a baby fed): every tick each one's position, rotations,
 * random, running goals, age, love and own data, its sounds and entity
 * events, the blocks it ate and the children and orbs breeding added.
 */
public class AnimalOracle {
  static final List<String> ANIMALS = List.of("minecraft:cow", "minecraft:mooshroom", "minecraft:pig", "minecraft:sheep",
      "minecraft:chicken", "minecraft:rabbit");
  // Sounds the animals play beyond their sound variants' and AI facts' own.
  static final List<String> SOUNDS = List.of("minecraft:entity.cow.milk", "minecraft:entity.mooshroom.milk",
      "minecraft:entity.mooshroom.suspicious_milk", "minecraft:entity.mooshroom.shear", "minecraft:entity.mooshroom.eat",
      "minecraft:entity.mooshroom.convert", "minecraft:entity.sheep.shear", "minecraft:entity.sheep.ambient",
      "minecraft:entity.sheep.hurt", "minecraft:entity.sheep.death", "minecraft:entity.chicken.egg",
      "minecraft:entity.rabbit.jump", "minecraft:entity.rabbit.attack", "minecraft:entity.rabbit.ambient",
      "minecraft:entity.rabbit.hurt", "minecraft:entity.rabbit.death", "minecraft:entity.mooshroom.milk",
      "minecraft:item.dye.use", "minecraft:entity.leash_knot.place", "minecraft:entity.leash_knot.break",
      "minecraft:item.lead.tied", "minecraft:item.lead.untied", "minecraft:item.lead.break", "minecraft:item.shears.snip",
      "minecraft:item.golden_dandelion.use", "minecraft:item.golden_dandelion.unuse");
  static final List<ResourceKey<? extends Registry<?>>> VARIANTS = List.of(Registries.COW_VARIANT, Registries.PIG_VARIANT,
      Registries.CHICKEN_VARIANT);

  static String bits(float f) { return Integer.toString(Float.floatToRawIntBits(f)); }

  static JsonArray dimensions(Entity e) {
    var a = new JsonArray();
    a.add(Float.floatToRawIntBits(e.getBbWidth())); a.add(Float.floatToRawIntBits(e.getBbHeight()));
    a.add(Float.floatToRawIntBits(e.getEyeHeight()));
    return a;
  }

  static String sound(Holder<SoundEvent> s, Set<String> used) {
    var name = s.value().location().toString();
    used.add(name);
    return name;
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  static JsonObject facts(HolderLookup.Provider lookup, MobAiOracle.Probe level) throws Exception {
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var used = new TreeSet<String>(SOUNDS);
    var animals = new JsonObject();
    for (var name : ANIMALS) {
      var animal = (Animal)MobAiOracle.mob(name, level);
      var row = new JsonObject();
      row.add("adult", dimensions(animal));
      animal.setBaby(true);
      row.add("baby", dimensions(animal));
      var food = new JsonArray();
      BuiltInRegistries.ITEM.keySet().stream().sorted(Comparator.comparing(Identifier::toString)).forEach(id -> {
        if (animal.isFood(new ItemStack(BuiltInRegistries.ITEM.getValue(id)))) food.add(id.toString());
      });
      row.add("food", food);
      animals.add(name, row);
    }
    out.add("animals", animals);
    // The types a rabbit avoids as `Monster`s (`RabbitAvoidEntityGoal`'s class).
    var monsters = new JsonArray();
    BuiltInRegistries.ENTITY_TYPE.keySet().stream().sorted(Comparator.comparing(Identifier::toString)).forEach(id -> {
      var type = BuiltInRegistries.ENTITY_TYPE.getValue(id);
      if (type.getCategory() == MobCategory.MISC && type != EntityTypes.SHULKER) return;
      Entity e;
      try { e = type.create(level, EntitySpawnReason.COMMAND); } catch (RuntimeException ex) { return; }
      if (e instanceof net.minecraft.world.entity.monster.Monster) monsters.add(id.toString());
    });
    out.add("monsters", monsters);
    // What a brown mooshroom's stew gets from a flower it eats
    // (`SuspiciousEffectHolder`): its effects and durations.
    var flowers = new JsonObject();
    BuiltInRegistries.ITEM.keySet().stream().sorted(Comparator.comparing(Identifier::toString)).forEach(id -> {
      var holder = net.minecraft.world.level.block.SuspiciousEffectHolder.tryGet(BuiltInRegistries.ITEM.getValue(id));
      if (holder == null) return;
      var effects = new JsonArray();
      for (var e : holder.getSuspiciousEffects().effects()) {
        var a = new JsonArray(); a.add(e.effect().unwrapKey().orElseThrow().identifier().toString()); a.add(e.duration()); effects.add(a);
      }
      flowers.add(id.toString(), effects);
    });
    out.add("stew_flowers", flowers);
    var variants = new JsonObject();
    for (var key : VARIANTS) {
      var list = new JsonArray();
      var registry = lookup.lookupOrThrow((ResourceKey)key);
      registry.listElements().sorted(Comparator.comparing(h -> ((Holder.Reference)h).key().identifier().toString())).forEach(h -> {
        var holder = (Holder.Reference)h;
        var o = new JsonObject(); o.addProperty("name", holder.key().identifier().toString());
        var selectors = new JsonArray();
        for (var s : ((net.minecraft.world.entity.variant.PriorityProvider<?, ?>)holder.value()).selectors()) {
          var so = new JsonObject(); so.addProperty("priority", s.priority());
          if (s.condition().isEmpty()) so.add("biomes", JsonNull.INSTANCE);
          else if (s.condition().get() instanceof net.minecraft.world.entity.variant.BiomeCheck check)
            so.addProperty("biomes", check.requiredBiomes().unwrapKey().orElseThrow().location().toString());
          else throw new IllegalStateException("unexpected spawn condition " + s.condition().get());
          selectors.add(so);
        }
        o.add("selectors", selectors);
        list.add(o);
      });
      variants.add(key.identifier().toString(), list);
    }
    out.add("variants", variants);
    var soundVariants = new JsonObject();
    var cows = new JsonObject();
    lookup.lookupOrThrow(Registries.COW_SOUND_VARIANT).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).forEach(h -> {
      var v = h.value(); var o = new JsonObject();
      o.addProperty("ambient", sound(v.ambientSound(), used)); o.addProperty("hurt", sound(v.hurtSound(), used));
      o.addProperty("death", sound(v.deathSound(), used)); o.addProperty("step", sound(v.stepSound(), used));
      cows.add(h.key().identifier().toString(), o);
    });
    soundVariants.add("minecraft:cow_sound_variant", cows);
    var pigs = new JsonObject();
    lookup.lookupOrThrow(Registries.PIG_SOUND_VARIANT).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).forEach(h -> {
      var v = h.value();
      for (var set : List.of(Map.entry("adult", v.adultSounds()), Map.entry("baby", v.babySounds()))) {
        var s = set.getValue(); var o = new JsonObject();
        o.addProperty("ambient", sound(s.ambientSound(), used)); o.addProperty("hurt", sound(s.hurtSound(), used));
        o.addProperty("death", sound(s.deathSound(), used)); o.addProperty("step", sound(s.stepSound(), used));
        o.addProperty("eat", sound(s.eatSound(), used));
        var entry = pigs.has(h.key().identifier().toString()) ? pigs.getAsJsonObject(h.key().identifier().toString()) : new JsonObject();
        entry.add(set.getKey(), o); pigs.add(h.key().identifier().toString(), entry);
      }
    });
    soundVariants.add("minecraft:pig_sound_variant", pigs);
    var chickens = new JsonObject();
    lookup.lookupOrThrow(Registries.CHICKEN_SOUND_VARIANT).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).forEach(h -> {
      var v = h.value();
      for (var set : List.of(Map.entry("adult", v.adultSounds()), Map.entry("baby", v.babySounds()))) {
        var s = set.getValue(); var o = new JsonObject();
        o.addProperty("ambient", sound(s.ambientSound(), used)); o.addProperty("hurt", sound(s.hurtSound(), used));
        o.addProperty("death", sound(s.deathSound(), used)); o.addProperty("step", sound(s.stepSound(), used));
        var entry = chickens.has(h.key().identifier().toString()) ? chickens.getAsJsonObject(h.key().identifier().toString()) : new JsonObject();
        entry.add(set.getKey(), o); chickens.add(h.key().identifier().toString(), entry);
      }
    });
    soundVariants.add("minecraft:chicken_sound_variant", chickens);
    out.add("sound_variants", soundVariants);
    var sounds = new JsonObject();
    for (var n : used) sounds.addProperty(n, BuiltInRegistries.SOUND_EVENT.getId(BuiltInRegistries.SOUND_EVENT.getValue(Identifier.parse(n))));
    out.add("sounds", sounds);
    return out;
  }

  // ---- cases ----

  /** A probe level that records block edits, level and entity events, and entities added. */
  static class Farm extends MobAiOracle.Probe {
    List<JsonObject> edits; List<Entity> added;
    public boolean setBlock(BlockPos p, net.minecraft.world.level.block.state.BlockState state, int flags, int limit) {
      var o = new JsonObject(); o.add("at", at(p)); o.addProperty("state", net.minecraft.world.level.block.Block.getId(state));
      edits.add(o); blocks.put(p.immutable(), state); return true;
    }
    public boolean destroyBlock(BlockPos p, boolean drop, Entity breaker, int limit) {
      var state = getBlockState(p);
      if (state.isAir()) return false;
      return setBlock(p, state.getFluidState().createLegacyBlock(), 3, limit);
    }
    public void levelEvent(Entity source, int type, BlockPos p, int data) {
      var o = new JsonObject(); o.add("at", at(p)); o.addProperty("event", type); o.addProperty("data", data); edits.add(o);
    }
    public void broadcastEntityEvent(Entity e, byte event) {
      var o = new JsonObject(); o.addProperty("event", event); sounds.computeIfAbsent(e, k -> new ArrayList<>()).add(o);
    }
    public boolean addFreshEntity(Entity e) { added.add(e); return true; }
    // A lamb's colour mixes its parents' dyes by vanilla's crafting recipes.
    net.minecraft.world.item.crafting.RecipeManager recipes;
    public net.minecraft.world.item.crafting.RecipeManager recipeAccess() { return recipes; }
    // Every block is one biome (plains in the traces); the biomes registry
    // has the data pack's tags bound (spawns' variants and colours read them).
    Holder<net.minecraft.world.level.biome.Biome> biome;
    Registry<net.minecraft.world.level.biome.Biome> biomes;
    HolderLookup.RegistryLookup<net.minecraft.world.level.storage.loot.LootTable> tables;
    // The lookup the loot tables were read with (their variant predicates' holders).
    HolderLookup.Provider reloadable;
    public Holder<net.minecraft.world.level.biome.Biome> getBiome(BlockPos p) { return biome; }
  }

  /** Vanilla's reloadable registries (recipes, loot tables), loaded as the server loads them (`CraftingBulkOracle`'s way). */
  static HolderLookup.Provider reloadable() throws Exception {
    var initial = MiningToolOracle.initialize();
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, access);
      var statics = net.minecraft.tags.TagLoader.buildUpdatedLookups(access, pending);
      var staticKeys = statics.stream().map(r -> r.key()).collect(java.util.stream.Collectors.toSet());
      var base = HolderLookup.Provider.create(java.util.stream.Stream.concat(initial.listRegistries().filter(r -> !staticKeys.contains(r.key())), statics.stream()));
      var loaded = net.minecraft.resources.RegistryDataLoader.load(resources, base.listRegistries().toList(),
          net.minecraft.resources.RegistryDataLoader.RELOADABLE_REGISTRIES, Runnable::run).join();
      var keys = loaded.listRegistryKeys().collect(java.util.stream.Collectors.toSet());
      var lookup = HolderLookup.Provider.create(java.util.stream.Stream.concat(base.listRegistries().filter(r -> !keys.contains(r.key())), loaded.listRegistries()));
      for (var tags : pending) tags.apply();
      return lookup;
    }
  }

  static JsonArray at(BlockPos p) { var a = new JsonArray(); a.add(p.getX()); a.add(p.getY()); a.add(p.getZ()); return a; }

  /** An animal placed: its type, where, its yaw, random seed, age and own data (`color`, `type`). */
  record Beast(String type, Vec3 position, float yaw, long seed, int age, Map<String, Object> data) {
    Beast(String type, Vec3 position, float yaw, long seed) { this(type, position, yaw, seed, 0, Map.of()); }
  }
  /** At tick `tick`, something happens to mob `mob`: `love` (`setInLove`) or `feed` (a baby fed, `ageUp`). */
  record Act(int tick, int mob, String what) {}

  static void setup(Mob m, Beast b) throws Exception {
    for (var e : b.data.entrySet()) switch (e.getKey()) {
      case "color" -> ((net.minecraft.world.entity.animal.sheep.Sheep)m).setColor(net.minecraft.world.item.DyeColor.byId((Integer)e.getValue()));
      case "sheared" -> ((net.minecraft.world.entity.animal.sheep.Sheep)m).setSheared((Boolean)e.getValue());
      case "no_ai" -> m.setNoAi((Boolean)e.getValue());
      case "type" -> {
        if (m instanceof net.minecraft.world.entity.animal.rabbit.Rabbit r) {
          var set = r.getClass().getDeclaredMethod("setVariant", net.minecraft.world.entity.animal.rabbit.Rabbit.Variant.class); set.setAccessible(true);
          set.invoke(r, net.minecraft.world.entity.animal.rabbit.Rabbit.Variant.byId((Integer)e.getValue()));
        } else {
          var set = m.getClass().getDeclaredMethod("setVariant", net.minecraft.world.entity.animal.cow.MushroomCow.Variant.class); set.setAccessible(true);
          set.invoke(m, net.minecraft.world.entity.animal.cow.MushroomCow.Variant.valueOf(((String)e.getValue()).toUpperCase()));
        }
      }
      default -> throw new IllegalArgumentException(e.getKey());
    }
    ((net.minecraft.world.entity.AgeableMob)m).setAge(b.age);
  }

  /** What a trace shows of an animal's own data: age, love, and its type's. */
  static JsonObject data(Mob m) {
    var o = new JsonObject();
    var a = (Animal)m;
    o.addProperty("age", a.getAge()); o.addProperty("in_love", a.getInLoveTime());
    if (m instanceof net.minecraft.world.entity.animal.sheep.Sheep sh) {
      o.addProperty("color", sh.getColor().getId()); o.addProperty("sheared", sh.isSheared());
    }
    if (m instanceof net.minecraft.world.entity.animal.rabbit.Rabbit r) {
      o.addProperty("type", r.getVariant().id());
      try { o.addProperty("jumping", MobAiOracle.field(LivingEntity.class, "jumping").getBoolean(r)); }
      catch (Exception ex) { throw new RuntimeException(ex); }
    }
    if (m instanceof net.minecraft.world.entity.animal.cow.MushroomCow c) o.addProperty("type", c.getVariant().getSerializedName());
    if (m instanceof net.minecraft.world.entity.animal.chicken.Chicken c) o.addProperty("egg_time", c.eggTime);
    for (var name : List.of("variant")) {
      if (m instanceof net.minecraft.world.entity.animal.cow.Cow c) o.addProperty(name, c.getVariant().unwrapKey().orElseThrow().identifier().toString());
      if (m instanceof net.minecraft.world.entity.animal.pig.Pig c) o.addProperty(name, c.getVariant().unwrapKey().orElseThrow().identifier().toString());
      if (m instanceof net.minecraft.world.entity.animal.chicken.Chicken c) o.addProperty(name, c.getVariant().unwrapKey().orElseThrow().identifier().toString());
    }
    return o;
  }

  static long seedOf(java.lang.reflect.Field seed, Mob m) throws Exception {
    return ((java.util.concurrent.atomic.AtomicLong)seed.get(m.getRandom())).get();
  }

  static JsonObject run(Farm level, String name, List<MobAiOracle.Block> blocks, List<Beast> beasts, List<MobAiOracle.Stand> stands,
      List<Act> acts, int ticks) throws Exception {
    level.blocks.clear(); level.entities.clear(); level.fighters.clear(); level.sounds.clear(); level.time = 1000L; level.ids = 0;
    level.edits = new ArrayList<>(); level.added = new ArrayList<>();
    var levelRandom = net.minecraft.util.RandomSource.create(7L);
    MobAiOracle.unsafe.putObject(level, MobAiOracle.unsafe.objectFieldOffset(net.minecraft.world.level.Level.class.getDeclaredField("random")), levelRandom);
    for (var b : blocks) level.blocks.put(new BlockPos(b.x(), b.y(), b.z()), b.state());
    var fighters = new ArrayList<MobAiOracle.Fighter>();
    int n = 0;
    for (var s : stands) {
      var f = new MobAiOracle.Fighter(level, ++n, net.minecraft.world.level.GameType.byName(s.mode()));
      f.snapTo(s.position().x, s.position().y, s.position().z, 0, 0);
      if (s.mainhand() != null) f.setItemSlot(EquipmentSlot.MAINHAND, new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(s.mainhand()))));
      fighters.add(f); level.fighters.add(f); level.entities.add(f);
    }
    var seedField = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var mobs = new ArrayList<Mob>();
    var placed = new JsonArray();
    for (var b : beasts) {
      var m = MobAiOracle.mob(b.type, level);
      setup(m, b);
      m.getRandom().setSeed(b.seed);
      m.setSilent(false);
      m.snapTo(b.position.x, b.position.y, b.position.z, b.yaw, 0);
      m.setYHeadRot(b.yaw); m.setYBodyRot(b.yaw);
      mobs.add(m); level.entities.add(m);
      var o = new JsonObject(); o.addProperty("type", b.type); o.add("position", MobAiOracle.bits(b.position));
      o.addProperty("yaw", Float.floatToRawIntBits(b.yaw)); o.addProperty("seed", b.seed); o.addProperty("id", m.getId());
      o.add("data", data(m)); o.addProperty("no_ai", m.isNoAi()); placed.add(o);
    }
    var goalSelector = MobAiOracle.field(Mob.class, "goalSelector");
    var push = LivingEntity.class.getDeclaredMethod("pushEntities"); push.setAccessible(true);
    var trace = new JsonArray();
    var born = new JsonArray();
    for (int t = 0; t < ticks; t++) {
      level.time++;
      for (var act : acts) if (act.tick == t) {
        var a = (Animal)mobs.get(act.mob);
        switch (act.what) {
          case "love" -> a.setInLove(null);
          case "feed" -> a.ageUp(net.minecraft.world.entity.AgeableMob.getSpeedUpSecondsWhenFeeding(-a.getAge()), true);
          default -> throw new IllegalArgumentException(act.what);
        }
      }
      for (var m : List.copyOf(mobs)) {
        m.checkDespawn();
        m.setOldPosAndRot();
        m.tickCount++;
        m.tick();
      }
      for (var f : fighters) push.invoke(f);
      var row = new JsonArray();
      for (var m : mobs) {
        var r = new JsonObject();
        r.addProperty("id", m.getId());
        r.add("position", MobAiOracle.bits(m.position())); r.add("velocity", MobAiOracle.bits(m.getDeltaMovement()));
        r.addProperty("on_ground", m.onGround());
        r.addProperty("yaw", Float.floatToRawIntBits(m.getYRot()));
        r.addProperty("head", Float.floatToRawIntBits(m.getYHeadRot()));
        r.addProperty("body", Float.floatToRawIntBits(m.yBodyRot));
        r.addProperty("pitch", Float.floatToRawIntBits(m.getXRot()));
        r.addProperty("seed", seedOf(seedField, m));
        r.addProperty("goals", MobAiOracle.running((net.minecraft.world.entity.ai.goal.GoalSelector)goalSelector.get(m)));
        r.add("data", data(m));
        var sounds = new JsonArray(); level.sounds.getOrDefault(m, List.of()).forEach(sounds::add);
        r.add("sounds", sounds);
        row.add(r);
      }
      // What this tick added: a child (seeded now, it ticks from the next
      // tick) or a breeding's orb.
      for (var e : level.added) {
        var o = new JsonObject(); o.addProperty("tick", t);
        if (e instanceof Mob m) {
          m.getRandom().setSeed(9000L + m.getId());
          o.addProperty("type", BuiltInRegistries.ENTITY_TYPE.getKey(m.getType()).toString());
          o.addProperty("id", m.getId()); o.addProperty("seed", 9000L + m.getId());
          o.add("position", MobAiOracle.bits(m.position())); o.addProperty("yaw", Float.floatToRawIntBits(m.getYRot()));
          // Its head and body keep the constructor's random facing (`Math.random`).
          o.addProperty("head", Float.floatToRawIntBits(m.getYHeadRot())); o.addProperty("body", Float.floatToRawIntBits(m.yBodyRot));
          o.add("data", data(m));
          mobs.add(m); level.entities.add(m);
        } else if (e instanceof net.minecraft.world.entity.ExperienceOrb orb) {
          o.addProperty("orb", orb.getValue()); o.add("position", MobAiOracle.bits(orb.position()));
        } else {
          o.addProperty("other", BuiltInRegistries.ENTITY_TYPE.getKey(e.getType()).toString());
        }
        born.add(o);
      }
      level.added.clear();
      var tick = new JsonObject();
      tick.add("mobs", row);
      var edits = new JsonArray(); level.edits.forEach(edits::add); tick.add("edits", edits);
      tick.addProperty("level_seed", ((java.util.concurrent.atomic.AtomicLong)seedField.get(levelRandom)).get());
      level.edits.clear(); level.sounds.clear();
      trace.add(tick);
    }
    var out = new JsonObject(); out.addProperty("name", name);
    var bs = new JsonArray();
    for (var b : blocks) { var a = new JsonArray(); a.add(b.x()); a.add(b.y()); a.add(b.z()); a.add(net.minecraft.world.level.block.Block.getId(b.state())); bs.add(a); }
    out.add("blocks", bs); out.add("mobs", placed);
    var ps = new JsonArray(); int i = 0;
    for (var s : stands) {
      var o = new JsonObject(); o.addProperty("uuid", ++i); o.addProperty("id", fighters.get(i - 1).getId()); o.add("position", MobAiOracle.bits(s.position()));
      o.addProperty("mode", s.mode()); o.addProperty("mainhand", s.mainhand()); ps.add(o);
    }
    out.add("players", ps);
    var as = new JsonArray();
    for (var a : acts) { var o = new JsonObject(); o.addProperty("tick", a.tick); o.addProperty("mob", a.mob); o.addProperty("what", a.what); as.add(o); }
    out.add("acts", as); out.add("born", born); out.add("ticks", trace);
    return out;
  }

  static JsonObject cases(Farm level) throws Exception {
    var grass = net.minecraft.world.level.block.Blocks.GRASS_BLOCK.defaultBlockState();
    var mycelium = net.minecraft.world.level.block.Blocks.MYCELIUM.defaultBlockState();
    var shortGrass = net.minecraft.world.level.block.Blocks.SHORT_GRASS.defaultBlockState();
    var meadow = MobAiOracle.floor(63, 12, grass);
    var tufts = new ArrayList<>(meadow);
    for (int x = -3; x <= 3; x += 2) for (int z = -3; z <= 3; z += 2) tufts.add(new MobAiOracle.Block(x, 64, z, shortGrass));
    var creative = List.of(new MobAiOracle.Stand(new Vec3(4.5, 64, 4.5), "creative", null));
    var cases = new JsonArray();
    // Mobs here tick one after another, each reading those before it as
    // they moved this tick; ValiMC's AI reads every mob as the tick began
    // (one kernel call per section). An animal with an AI therefore only
    // reads animals that stand still (no AI) or none.
    // Each animal wanders over its ground and looks at a creative player now and then.
    cases.add(run(level, "cow_wander", meadow, List.of(new Beast("minecraft:cow", new Vec3(.5, 64, .5), 0, 5L)), creative, List.of(), 600));
    cases.add(run(level, "mooshroom_wander", MobAiOracle.floor(63, 12, mycelium),
        List.of(new Beast("minecraft:mooshroom", new Vec3(.5, 64, .5), 90, 6L, 0, Map.of("type", "brown"))), creative, List.of(), 600));
    cases.add(run(level, "chicken_wander", meadow, List.of(new Beast("minecraft:chicken", new Vec3(.5, 70, .5), 0, 7L)), creative, List.of(), 600));
    // A sheared sheep and a lamb graze: the grass they eat turns to dirt, the
    // tufts they stand in go, the wool grows back.
    cases.add(run(level, "sheep_graze", tufts, List.of(new Beast("minecraft:sheep", new Vec3(.5, 64, .5), 0, 8L, 0, Map.of("color", 15, "sheared", true))),
        creative, List.of(), 1500));
    cases.add(run(level, "lamb_graze", tufts, List.of(new Beast("minecraft:sheep", new Vec3(-2.5, 64, 2.5), 45, 9L, -24000, Map.of("color", 6))),
        creative, List.of(), 800));
    // A rabbit hops about; one flees a survival player; one is tempted by a carrot.
    cases.add(run(level, "rabbit_hop", meadow, List.of(new Beast("minecraft:rabbit", new Vec3(.5, 64, .5), 0, 10L, 0, Map.of("type", 1))), creative, List.of(), 600));
    cases.add(run(level, "rabbit_flee", meadow, List.of(new Beast("minecraft:rabbit", new Vec3(.5, 64, .5), 0, 11L)),
        List.of(new MobAiOracle.Stand(new Vec3(3.5, 64, 2.5), "survival", null)), List.of(), 300));
    cases.add(run(level, "rabbit_tempt", meadow, List.of(new Beast("minecraft:rabbit", new Vec3(.5, 64, .5), 0, 12L)),
        List.of(new MobAiOracle.Stand(new Vec3(6.5, 64, -3.5), "survival", "minecraft:carrot")), List.of(), 300));
    // A cow in love walks to a still partner in love and they breed: a calf
    // and an orb where it stood; love and age as breeding leaves them.
    cases.add(run(level, "cow_breed", meadow, List.of(new Beast("minecraft:cow", new Vec3(.5, 64, .5), 0, 13L),
        new Beast("minecraft:cow", new Vec3(5.5, 64, 3.5), 180, 14L, 0, Map.of("no_ai", true))), creative,
        List.of(new Act(0, 0, "love"), new Act(2, 1, "love")), 120));
    // A calf follows a still parent; a fed piglet grows up sooner; a cow's
    // love runs out with its hearts.
    cases.add(run(level, "calf_follow", meadow, List.of(new Beast("minecraft:cow", new Vec3(.5, 64, .5), 0, 15L, -2000, Map.of()),
        new Beast("minecraft:cow", new Vec3(6.5, 64, 4.5), 0, 16L, 0, Map.of("no_ai", true))), creative, List.of(), 400));
    cases.add(run(level, "piglet_grow", meadow, List.of(new Beast("minecraft:pig", new Vec3(.5, 64, .5), 0, 23L, -100, Map.of())), creative,
        List.of(new Act(10, 0, "feed"), new Act(30, 0, "feed")), 200));
    cases.add(run(level, "cow_love", meadow, List.of(new Beast("minecraft:cow", new Vec3(.5, 64, .5), 0, 24L)), creative,
        List.of(new Act(0, 0, "love")), 650));
    var out = new JsonObject(); out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); out.add("cases", cases);
    out.add("breeding", breeding(level));
    out.add("spawns", spawns(level));
    out.add("drops", drops(level));
    return out;
  }

  /**
   * The animals' loot tables with real animals as the entity: deaths (on
   * fire or not; sheep of each colour, sheared or not; each rabbit type and
   * mooshroom colour), shearing a sheep or mooshroom, a hen laying; each
   * with a seed: the items.
   */
  static JsonArray drops(Farm level) throws Exception {
    var out = new JsonArray();
    var pick = new java.util.Random(77L);
    var ops = level.registryAccess().createSerializationContext(com.mojang.serialization.JsonOps.INSTANCE);
    var temperatures = List.of("minecraft:cold", "minecraft:temperate", "minecraft:warm");
    for (int n = 0; n < 600; n++) {
      level.entities.clear(); level.ids = 0;
      var type = ANIMALS.get(n % ANIMALS.size());
      var d = new HashMap<String, Object>();
      switch (type) {
        case "minecraft:sheep" -> { d.put("color", pick.nextInt(16)); d.put("sheared", pick.nextInt(3) == 0); }
        case "minecraft:mooshroom" -> d.put("type", pick.nextBoolean() ? "brown" : "red");
        case "minecraft:rabbit" -> d.put("type", pick.nextInt(6));
        default -> {}
      }
      var m = MobAiOracle.mob(type, level);
      setup(m, new Beast(type, Vec3.ZERO, 0, 0, 0, d));
      if (m instanceof net.minecraft.world.entity.animal.chicken.Chicken c)
        c.setVariant(level.reloadable.lookupOrThrow(Registries.CHICKEN_VARIANT)
            .getOrThrow(ResourceKey.create(Registries.CHICKEN_VARIANT, Identifier.parse(temperatures.get(pick.nextInt(3))))));
      var at = new Vec3(pick.nextInt(201) - 100.5, 64, pick.nextInt(201) - 100.5);
      m.snapTo(at.x, at.y, at.z, 0, 0);
      boolean fire = pick.nextInt(3) == 0;
      if (fire) m.setRemainingFireTicks(100);
      String kind; String table;
      if (type.equals("minecraft:chicken") && n % 12 == 4) { kind = "gift"; table = "minecraft:gameplay/chicken_lay"; }
      else if (type.equals("minecraft:sheep") && n % 12 == 3) { kind = "shearing"; table = "minecraft:shearing/sheep"; }
      else if (type.equals("minecraft:mooshroom") && n % 12 == 1) { kind = "shearing"; table = "minecraft:shearing/mooshroom"; }
      else { kind = "death"; table = m.getLootTable().orElseThrow().identifier().toString(); }
      var builder = new net.minecraft.world.level.storage.loot.LootParams.Builder(level)
          .withParameter(net.minecraft.world.level.storage.loot.parameters.LootContextParams.THIS_ENTITY, m)
          .withParameter(net.minecraft.world.level.storage.loot.parameters.LootContextParams.ORIGIN, at);
      var params = switch (kind) {
        case "gift" -> builder.create(net.minecraft.world.level.storage.loot.parameters.LootContextParamSets.GIFT);
        case "shearing" -> builder.withParameter(net.minecraft.world.level.storage.loot.parameters.LootContextParams.TOOL,
            new ItemStack(net.minecraft.world.item.Items.SHEARS)).create(net.minecraft.world.level.storage.loot.parameters.LootContextParamSets.SHEARING);
        default -> builder.withParameter(net.minecraft.world.level.storage.loot.parameters.LootContextParams.DAMAGE_SOURCE, level.damageSources().generic())
            .create(net.minecraft.world.level.storage.loot.parameters.LootContextParamSets.ENTITY);
      };
      long seed = pick.nextLong();
      var lootTable = level.tables.getOrThrow(ResourceKey.create(Registries.LOOT_TABLE, Identifier.parse(table))).value();
      var items = new JsonArray();
      for (var stack : lootTable.getRandomItems(params, seed)) if (!stack.isEmpty()) items.add(ItemStack.CODEC.encodeStart(ops, stack).getOrThrow());
      var o = new JsonObject(); o.addProperty("type", type); o.addProperty("table", table); o.addProperty("seed", seed);
      o.add("position", MobAiOracle.bits(at)); o.addProperty("on_fire", fire); o.add("data", data(m)); o.add("items", items);
      out.add(o);
    }
    return out;
  }

  /**
   * `finalizeSpawn` of fresh animals of each type in biomes of each climate
   * (and the rabbits' snowy and desert ones), with seeded level and mob
   * randoms: the data it gave, the follow range bonus, handedness and both
   * randoms after.
   */
  static JsonArray spawns(Farm level) throws Exception {
    var out = new JsonArray();
    var biomes = List.of("minecraft:plains", "minecraft:snowy_plains", "minecraft:desert", "minecraft:jungle", "minecraft:taiga",
        "minecraft:mushroom_fields", "minecraft:snowy_taiga", "minecraft:savanna");
    var seedField = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var levelRandom = net.minecraft.util.RandomSource.create(7L);
    MobAiOracle.unsafe.putObject(level, MobAiOracle.unsafe.objectFieldOffset(net.minecraft.world.level.Level.class.getDeclaredField("random")), levelRandom);
    var pick = new java.util.Random(43L);
    var difficulty = new net.minecraft.world.DifficultyInstance(net.minecraft.world.Difficulty.NORMAL, 0L, 0L, 0.0F);
    for (var type : ANIMALS) for (var biome : biomes) for (int n = 0; n < 8; n++) {
      level.entities.clear(); level.added = new ArrayList<>(); level.ids = 0;
      level.biome = level.biomes.getOrThrow(ResourceKey.create(Registries.BIOME, Identifier.parse(biome)));
      var m = MobAiOracle.mob(type, level);
      long levelSeed = pick.nextLong(), mobSeed = pick.nextLong();
      levelRandom.setSeed(levelSeed); m.getRandom().setSeed(mobSeed);
      m.snapTo(.5, 64, .5, 0, 0);
      level.entities.add(m);
      m.finalizeSpawn(level, difficulty, EntitySpawnReason.NATURAL, null);
      var o = new JsonObject(); o.addProperty("type", type); o.addProperty("biome", biome);
      o.addProperty("level_seed", levelSeed); o.addProperty("mob_seed", mobSeed);
      o.add("data", data(m)); o.addProperty("sound_variant", soundVariant(m));
      var follow = m.getAttribute(net.minecraft.world.entity.ai.attributes.Attributes.FOLLOW_RANGE)
          .getModifier(Identifier.withDefaultNamespace("random_spawn_bonus"));
      o.addProperty("follow_bonus", follow == null ? null : MobAiOracle.bits(follow.amount()));
      o.addProperty("left_handed", m.isLeftHanded());
      o.addProperty("level_seed_after", ((java.util.concurrent.atomic.AtomicLong)seedField.get(levelRandom)).get());
      o.addProperty("mob_seed_after", seedOf(seedField, m));
      out.add(o);
    }
    return out;
  }

  static String soundVariant(Mob m) throws Exception {
    if (!(m instanceof net.minecraft.world.entity.animal.cow.Cow || m instanceof net.minecraft.world.entity.animal.pig.Pig
        || m instanceof net.minecraft.world.entity.animal.chicken.Chicken)) return null;
    var c = m instanceof net.minecraft.world.entity.animal.cow.Cow ? net.minecraft.world.entity.animal.cow.Cow.class
        : m instanceof net.minecraft.world.entity.animal.pig.Pig ? net.minecraft.world.entity.animal.pig.Pig.class
        : net.minecraft.world.entity.animal.chicken.Chicken.class;
    var get = c.getDeclaredMethod("getSoundVariant"); get.setAccessible(true);
    return ((Holder<?>)get.invoke(m)).unwrapKey().orElseThrow().identifier().toString();
  }

  /**
   * Breedings on their own (`spawnChildFromBreeding`) of pairs of each
   * animal with seeded randoms and varied colours, types and variants: the
   * child's data, the orb, what is left of the parents, and both randoms.
   */
  static JsonArray breeding(Farm level) throws Exception {
    var out = new JsonArray();
    var seedField = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var levelRandom = net.minecraft.util.RandomSource.create(7L);
    MobAiOracle.unsafe.putObject(level, MobAiOracle.unsafe.objectFieldOffset(net.minecraft.world.level.Level.class.getDeclaredField("random")), levelRandom);
    var temperatures = List.of("minecraft:cold", "minecraft:temperate", "minecraft:warm");
    for (var type : ANIMALS) for (int n = 0; n < 40; n++) {
      level.entities.clear(); level.added = new ArrayList<>(); level.ids = 0;
      var pick = new java.util.Random(n * 7919L + type.hashCode());
      var pair = new ArrayList<Mob>();
      for (int i = 0; i < 2; i++) {
        var m = MobAiOracle.mob(type, level);
        var d = new HashMap<String, Object>();
        switch (type) {
          case "minecraft:sheep" -> d.put("color", pick.nextInt(16));
          case "minecraft:mooshroom" -> d.put("type", pick.nextInt(3) == 0 ? "brown" : "red");
          case "minecraft:rabbit" -> d.put("type", pick.nextInt(6));
          default -> {}
        }
        setup(m, new Beast(type, Vec3.ZERO, 0, 0, 0, d));
        if (m instanceof net.minecraft.world.entity.animal.cow.Cow c) c.setVariant(variant(level, Registries.COW_VARIANT, temperatures.get(pick.nextInt(3))));
        if (m instanceof net.minecraft.world.entity.animal.pig.Pig c) {
          var set = net.minecraft.world.entity.animal.pig.Pig.class.getDeclaredMethod("setVariant", Holder.class); set.setAccessible(true);
          set.invoke(c, variant(level, Registries.PIG_VARIANT, temperatures.get(pick.nextInt(3))));
        }
        if (m instanceof net.minecraft.world.entity.animal.chicken.Chicken c) c.setVariant(variant(level, Registries.CHICKEN_VARIANT, temperatures.get(pick.nextInt(3))));
        m.snapTo(i * 1.5 + .5, 64, .5, 0, 0);
        ((Animal)m).setInLove(null);
        pair.add(m); level.entities.add(m);
      }
      var parent = (Animal)pair.get(0); var partner = (Animal)pair.get(1);
      parent.getRandom().setSeed(pick.nextLong()); levelRandom.setSeed(pick.nextLong());
      var o = new JsonObject(); o.addProperty("type", type);
      o.add("parent", data(parent)); o.add("partner", data(partner));
      o.addProperty("seed", seedOf(seedField, parent)); o.addProperty("level_seed", ((java.util.concurrent.atomic.AtomicLong)seedField.get(levelRandom)).get());
      parent.spawnChildFromBreeding(level, partner);
      o.addProperty("seed_after", seedOf(seedField, parent)); o.addProperty("level_seed_after", ((java.util.concurrent.atomic.AtomicLong)seedField.get(levelRandom)).get());
      o.add("parent_after", data(parent)); o.add("partner_after", data(partner));
      for (var e : level.added) {
        if (e instanceof Mob m) o.add("child", data(m));
        if (e instanceof net.minecraft.world.entity.ExperienceOrb orb) o.addProperty("orb", orb.getValue());
      }
      out.add(o);
    }
    return out;
  }

  @SuppressWarnings("unchecked")
  static <T> Holder<T> variant(Farm level, ResourceKey<? extends Registry<T>> registry, String name) {
    return level.registryAccess().lookupOrThrow(registry).getOrThrow(ResourceKey.create(registry, Identifier.parse(name)));
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    var damage = MobAiOracle.registry(Registries.DAMAGE_TYPE, lookup);
    registries.add(damage);
    for (var key : List.of(Registries.ENCHANTMENT, Registries.PIG_VARIANT, Registries.PIG_SOUND_VARIANT, Registries.COW_VARIANT,
        Registries.COW_SOUND_VARIANT, Registries.CHICKEN_VARIANT, Registries.CHICKEN_SOUND_VARIANT))
      registries.add(MobAiOracle.registry((ResourceKey)key, lookup));
    BuiltInRegistries.REGISTRY.forEach(r -> registries.add(r));
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      MobAiOracle.bind(resources, BuiltInRegistries.BLOCK);
      MobAiOracle.bind(resources, BuiltInRegistries.FLUID);
      MobAiOracle.bind(resources, BuiltInRegistries.ENTITY_TYPE);
      MobAiOracle.bind(resources, BuiltInRegistries.ITEM);
      MobAiOracle.bind(resources, damage);
    }
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(Farm.class, lookup, access, null);
    level.sources = new DamageSources(access);
    if (args[0].equals("facts")) {
      Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().serializeNulls().create().toJson(facts(lookup, level)) + "\n");
      System.out.println("PASS: animal facts written");
      return;
    }
    if (args[0].equals("cases")) {
      var reloadable = reloadable();
      level.recipes = new net.minecraft.world.item.crafting.RecipeManager(reloadable);
      level.tables = reloadable.lookupOrThrow(Registries.LOOT_TABLE);
      level.reloadable = reloadable;
      level.biomes = MobAiOracle.registry(Registries.BIOME, lookup);
      try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
          List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
        MobAiOracle.bind(resources, level.biomes);
      }
      level.biome = level.biomes.getOrThrow(net.minecraft.world.level.biome.Biomes.PLAINS);
      var out = cases(level);
      Files.writeString(java.nio.file.Path.of(args[1]), new GsonBuilder().disableHtmlEscaping().serializeNulls().create().toJson(out));
      System.out.println("PASS: " + out.getAsJsonArray("cases").size() + " vanilla animal traces (wandering, grazing, hopping, breeding, growing).");
      return;
    }
    throw new IllegalArgumentException("usage: AnimalOracle facts|cases OUT.json");
  }
}
