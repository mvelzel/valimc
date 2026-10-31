import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.world.effect.*;

/**
 * Original extraction of every built-in status effect's static facts, without a gameplay server.
 * Attribute modifiers come from `HostileOracle facts` (`priv/registry/hostile_facts.json`).
 */
public class EffectMetadata {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    Field sound = MobEffect.class.getDeclaredField("soundOnAdded"); sound.setAccessible(true);
    var effects = new JsonArray();
    for (var effect : BuiltInRegistries.MOB_EFFECT) {
      int id = BuiltInRegistries.MOB_EFFECT.getId(effect);
      if (effects.size() != id) throw new AssertionError("Non-contiguous native effects");
      var holder = BuiltInRegistries.MOB_EFFECT.wrapAsHolder(effect);
      var row = new JsonObject();
      row.addProperty("name", BuiltInRegistries.MOB_EFFECT.getKey(effect).toString());
      row.addProperty("category", effect.getCategory().name().toLowerCase(Locale.ROOT));
      row.addProperty("color", effect.getColor());
      row.addProperty("instantaneous", effect.isInstantaneous());
      var plain = effect.createParticleOptions(new MobEffectInstance(holder, 1, 0, false, true, true));
      // `entity_effect` is the default factory's: coloured by the effect, fainter when ambient.
      row.addProperty("particle", BuiltInRegistries.PARTICLE_TYPE.getKey(plain.getType()).toString());
      row.addProperty("particle_id", BuiltInRegistries.PARTICLE_TYPE.getId(plain.getType()));
      var blend = new JsonArray();
      blend.add(effect.getBlendInDurationTicks()); blend.add(effect.getBlendOutDurationTicks()); blend.add(effect.getBlendOutAdvanceTicks());
      row.add("blend", blend);
      var added = (Optional<?>) sound.get(effect);
      if (added.isPresent()) {
        var event = (SoundEvent) added.get();
        var pair = new JsonArray(); pair.add(event.location().toString()); pair.add(BuiltInRegistries.SOUND_EVENT.getId(event));
        row.add("sound_on_added", pair);
      } else row.add("sound_on_added", JsonNull.INSTANCE);
      effects.add(row);
    }
    var out = new JsonObject();
    out.addProperty("version", "26.3"); out.addProperty("data_version", 5023);
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.add("effects", effects);
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().serializeNulls().create().toJson(out) + "\n");
  }
}
