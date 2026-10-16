import java.nio.file.*;
import java.lang.reflect.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.syncher.EntityDataAccessor;
import net.minecraft.network.syncher.EntityDataSerializer;
import net.minecraft.network.syncher.EntityDataSerializers;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.player.Player;

/** Original extraction of versioned IDs and accessor facts, not implementation source. */
public class EntityMetadata {
  private static Map<String,Integer> accessor(Class<?> owner, String name) throws Exception {
    var field = owner.getDeclaredField(name);
    field.setAccessible(true);
    var accessor = (EntityDataAccessor<?>)field.get(null);
    var facts = new TreeMap<String,Integer>();
    facts.put("index", accessor.id());
    facts.put("serializer", EntityDataSerializers.getSerializedId(accessor.serializer()));
    return facts;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var types = new TreeMap<String,Integer>();
    for (var type : BuiltInRegistries.ENTITY_TYPE)
      types.put(BuiltInRegistries.ENTITY_TYPE.getKey(type).toString(), BuiltInRegistries.ENTITY_TYPE.getId(type));
    var serializers = new TreeMap<String,Integer>();
    for (var field : EntityDataSerializers.class.getFields())
      if (Modifier.isStatic(field.getModifiers()) && EntityDataSerializer.class.isAssignableFrom(field.getType()))
        serializers.put(field.getName().toLowerCase(Locale.ROOT), EntityDataSerializers.getSerializedId((EntityDataSerializer<?>)field.get(null)));
    var fields = new TreeMap<String,Object>();
    fields.put("shared_flags", accessor(Entity.class, "DATA_SHARED_FLAGS_ID"));
    fields.put("air_supply", accessor(Entity.class, "DATA_AIR_SUPPLY_ID"));
    fields.put("no_gravity", accessor(Entity.class, "DATA_NO_GRAVITY"));
    fields.put("item_stack", accessor(ItemEntity.class, "DATA_ITEM"));
    fields.put("pose", accessor(Entity.class, "DATA_POSE"));
    fields.put("frozen_ticks", accessor(Entity.class, "DATA_TICKS_FROZEN"));
    fields.put("health", accessor(LivingEntity.class, "DATA_HEALTH_ID"));
    fields.put("absorption", accessor(Player.class, "DATA_PLAYER_ABSORPTION_ID"));
    fields.put("living_flags", accessor(LivingEntity.class, "DATA_LIVING_ENTITY_FLAGS"));
    var facts = new TreeMap<String,Object>();
    facts.put("version", "26.3"); facts.put("protocol", 777);
    facts.put("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    facts.put("types", types); facts.put("serializers", serializers); facts.put("fields", fields);
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(facts) + "\n");
  }
}
