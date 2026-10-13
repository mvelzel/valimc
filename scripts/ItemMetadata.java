import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket;

/** Extract versioned registry/default facts, never Minecraft implementation source. */
public class ItemMetadata {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    Map<String, Object> items = new TreeMap<>();
    for (var item : BuiltInRegistries.ITEM) {
      Map<String, Object> facts = new TreeMap<>();
      facts.put("id", BuiltInRegistries.ITEM.getId(item));
      facts.put("max_stack_size", item.getDefaultMaxStackSize());
      Integer damage = item.components().get(DataComponents.MAX_DAMAGE);
      if (damage != null) facts.put("max_damage", damage);
      items.put(BuiltInRegistries.ITEM.getKey(item).toString(), facts);
    }
    Map<String, Integer> components = new TreeMap<>();
    for (var type : BuiltInRegistries.DATA_COMPONENT_TYPE)
      components.put(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type).toString(),
        BuiltInRegistries.DATA_COMPONENT_TYPE.getId(type));
    Map<String, Integer> actions = new TreeMap<>();
    for (var action : ServerboundPlayerActionPacket.Action.values())
      actions.put(action.name().toLowerCase(Locale.ROOT), action.ordinal());
    Map<String, Object> facts = new TreeMap<>();
    facts.put("version", "26.3"); facts.put("protocol", 777);
    facts.put("items", items); facts.put("components", components);
    facts.put("player_actions", actions);
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(facts) + "\n");
  }
}
