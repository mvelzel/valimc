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
 * its base experience reward (the `xpReward` its constructor sets).
 */
public class CombatOracle {
  static List<DataComponentType<?>> components() {
    return List.of(DataComponents.ATTRIBUTE_MODIFIERS, DataComponents.WEAPON, DataComponents.BLOCKS_ATTACKS,
        DataComponents.DAMAGE_TYPE, DataComponents.MINIMUM_ATTACK_CHARGE);
  }
  static final List<String> MOBS = List.of("minecraft:zombie");

  @SuppressWarnings({"unchecked", "rawtypes"})
  static JsonElement encode(DataComponentType type, Object value, com.mojang.serialization.DynamicOps<JsonElement> ops) {
    return (JsonElement) type.codecOrThrow().encodeStart(ops, value).getOrThrow();
  }

  static JsonObject facts(HolderLookup.Provider lookup) throws Exception {
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
    for (var name : MOBS) {
      var type = BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse(name));
      experience.addProperty(name, xp.getInt(Probe.mob(type, unsafe)));
    }
    var out = new JsonObject();
    out.add("items", items);
    out.add("player_attributes", attributes);
    out.add("experience", experience);
    return out;
  }

  static class ProbeServer extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.util.debug.ServerDebugSubscribers debug;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
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
    throw new IllegalArgumentException("usage: CombatOracle facts OUT.json");
  }
}
