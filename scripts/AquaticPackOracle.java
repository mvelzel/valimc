import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.fish.*;

/** Original ordered calls to native finalizeSpawn, retaining the returned pack object. */
public class AquaticPackOracle {
  static final List<String> TYPES = List.of("axolotl", "turtle", "cod", "salmon", "tropical_fish");
  static java.lang.reflect.Field seedField;
  // A kernel-supplied school choice replaces just that one native draw.
  // Other native draws and their state remain observable and unmodified.
  static class DecisionRandom extends net.minecraft.world.level.levelgen.LegacyRandomSource {
    Boolean school; int floats;
    DecisionRandom(long seed, Boolean school) { super(seed); this.school = school; }
    public float nextFloat() {
      if (++floats == 2 && school != null) return school ? 0F : .95F;
      return super.nextFloat();
    }
  }
  static long random(net.minecraft.util.RandomSource source) throws Exception {
    return ((java.util.concurrent.atomic.AtomicLong)seedField.get(source)).get();
  }
  static String uuid(Entity mob) {
    var u = mob.getUUID(); return String.format("%016x%016x", u.getMostSignificantBits(), u.getLeastSignificantBits());
  }
  static JsonObject snapshot(Mob mob) throws Exception {
    var row = new JsonObject(); row.addProperty("uuid", uuid(mob));
    if (mob instanceof AgeableMob ageable) row.addProperty("age", ageable.getAge());
    if (mob instanceof net.minecraft.world.entity.animal.axolotl.Axolotl)
      row.addProperty("variant", ((Enum<?>)mob.get(DataComponents.AXOLOTL_VARIANT)).ordinal());
    if (mob instanceof Salmon) row.addProperty("size", ((Enum<?>)mob.get(DataComponents.SALMON_SIZE)).ordinal());
    if (mob instanceof TropicalFish fish) {
      var packed = TropicalFish.class.getDeclaredMethod("getPackedVariant"); packed.setAccessible(true);
      row.addProperty("variant", (Integer)packed.invoke(fish));
      row.addProperty("is_school", MobAiOracle.field(TropicalFish.class, "isSchool").getBoolean(fish));
    }
    if (mob instanceof AbstractSchoolingFish fish) {
      var leader = (Entity)MobAiOracle.field(AbstractSchoolingFish.class, "leader").get(fish);
      row.add("leader", leader == null ? JsonNull.INSTANCE : new JsonPrimitive(uuid(leader)));
      row.addProperty("school", MobAiOracle.field(AbstractSchoolingFish.class, "schoolSize").getInt(fish));
    }
    row.addProperty("random_after", random(mob.getRandom())); return row;
  }
  static JsonObject run(MobAiOracle.Probe level, String type, long seed, EntitySpawnReason reason, Boolean school) throws Exception {
    var mobs = new ArrayList<Mob>();
    for (int i = 0; i < 8; i++) {
      var mob = MobAiOracle.mob("minecraft:" + type, level);
      mob.setUUID(new UUID(1, i + 1)); mob.setPos(20.5 + i * .25, 64, 8.5);
      mob.getRandom().setSeed(seed * 7919 + i * 104729); mobs.add(mob);
    }
    var levelRandom = new DecisionRandom(seed, school);
    MobAiOracle.unsafe.putObject(level, MobAiOracle.unsafe.objectFieldOffset(
      net.minecraft.world.level.Level.class.getDeclaredField("random")), levelRandom);
    var out = new JsonObject();
    out.addProperty("type", "minecraft:" + type); out.addProperty("seed", seed);
    out.addProperty("reason", reason.name().toLowerCase()); out.addProperty("random_before", random(level.getRandom()));
    if (school != null) out.addProperty("school_decision", school);
    var rows = new JsonArray(); var admitted = new ArrayList<Mob>();
    for (int pack = 0; pack < 2; pack++) {
      SpawnGroupData data = null;
      for (int i = 0; i < 4; i++) {
        var mob = mobs.get(pack * 4 + i); long before = random(mob.getRandom());
        levelRandom.floats = 0;
        data = mob.finalizeSpawn(level, level.getCurrentDifficultyAt(mob.blockPosition()), reason, data);
        var row = snapshot(mob); row.addProperty("pack", pack); row.addProperty("index", pack * 4 + i);
        row.addProperty("random_before", before); row.addProperty("level_after", random(level.getRandom()));
        rows.add(row); admitted.add(mob);
        // The native spawner ends a rare, non-schooling tropical pack immediately.
        if (mob instanceof TropicalFish && !row.get("is_school").getAsBoolean()) break;
      }
    }
    out.add("members", rows); var finals = new JsonArray();
    for (var mob : admitted) finals.add(snapshot(mob)); out.add("final", finals); return out;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    var entries = new ArrayList<Registry<?>>();
    entries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE, lookup));
    BuiltInRegistries.REGISTRY.forEach(entries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(entries).freeze();
    var level = MobAiOracle.probe(lookup, access, new net.minecraft.world.damagesource.DamageSources(access));
    seedField = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var cases = new JsonArray();
    for (String type : TYPES) for (int seed = 0; seed < 64; seed++)
      for (var reason : List.of(EntitySpawnReason.NATURAL, EntitySpawnReason.CHUNK_GENERATION))
        cases.add(run(level, type, seed * 7919L + 13, reason, null));
    for (int seed = 0; seed < 64; seed++)
      for (var reason : List.of(EntitySpawnReason.NATURAL, EntitySpawnReason.CHUNK_GENERATION))
        for (boolean school : List.of(false, true))
          cases.add(run(level, "tropical_fish", seed * 7919L + 13, reason, school));
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().serializeNulls().create().toJson(cases) + "\n");
    System.out.println("PASS: native aquatic spawn-pack traces: " + cases.size());
  }
}
