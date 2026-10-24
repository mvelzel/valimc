import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.dolphin.Dolphin;
import net.minecraft.world.item.*;

/** Actual ageable ocean-mob steps and dolphin interactions, without a graphical client. */
public class WaterAgeOracle {
  static JsonObject snapshot(AgeableMob mob, net.minecraft.world.entity.player.Player player) throws Exception {
    var row = new JsonObject(); row.addProperty("age", mob.getAge());
    row.addProperty("forced_age", MobAiOracle.field(AgeableMob.class, "forcedAge").getInt(mob));
    row.addProperty("age_locked", mob.isAgeLocked());
    row.addProperty("timer", MobAiOracle.field(AgeableMob.class, "forcedAgeTimer").getInt(mob));
    row.add("dimensions", AnimalOracle.dimensions(mob));
    if (mob instanceof Dolphin d) {
      row.addProperty("got_fish", d.gotFish()); row.addProperty("can_attack", d.canAttack(player));
    }
    return row;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(
        net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      MobAiOracle.bind(resources, BuiltInRegistries.ITEM);
    }
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE, lookup));
    BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup, access, new net.minecraft.world.damagesource.DamageSources(access));
    var locked = AgeableMob.class.getDeclaredMethod("setAgeLocked", boolean.class); locked.setAccessible(true);
    var interact = Dolphin.class.getDeclaredMethod("mobInteract", net.minecraft.world.entity.player.Player.class, InteractionHand.class);
    interact.setAccessible(true);
    var cases = new JsonArray();
    for (var type : List.of("dolphin", "squid", "glow_squid"))
      for (int age : new int[] {-24000, -100, -1, 0, 1, 100})
        for (boolean lock : List.of(false, true))
          for (boolean feed : type.equals("dolphin") ? List.of(false, true) : List.of(false)) {
            var mob = (AgeableMob)MobAiOracle.mob("minecraft:" + type, level);
            mob.setPos(8.5, 64, 8.5); mob.setNoAi(true); mob.setNoGravity(true);
            mob.setAge(age); locked.invoke(mob, lock); mob.getRandom().setSeed(7);
            var row = new JsonObject(); row.addProperty("type", "minecraft:" + type);
            row.addProperty("age", age); row.addProperty("locked", lock); row.addProperty("feed", feed);
            row.addProperty("voice_pitch", Float.floatToRawIntBits(mob.getVoicePitch()));
            mob.getRandom().setSeed(7);
            var player = new MobAiOracle.Fighter(level, 1, net.minecraft.world.level.GameType.SURVIVAL);
            if (feed) {
              player.setItemInHand(InteractionHand.MAIN_HAND, new ItemStack(Items.COD, 3));
              interact.invoke(mob, player, InteractionHand.MAIN_HAND);
              row.addProperty("remaining", player.getMainHandItem().getCount());
            }
            var trace = new JsonArray(); trace.add(snapshot(mob, player));
            for (int tick = 0; tick < 41; tick++) { mob.aiStep(); trace.add(snapshot(mob, player)); }
            row.add("trace", trace); cases.add(row);
          }
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(cases) + "\n");
    System.out.println("PASS: native ocean-mob age/feed traces: " + cases.size());
  }
}
