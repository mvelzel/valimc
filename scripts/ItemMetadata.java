import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket;
import net.minecraft.world.inventory.ContainerInput;
import net.minecraft.world.inventory.Slot;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.SlotAccess;
import net.minecraft.world.inventory.ClickAction;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.core.registries.Registries;

/** Extract versioned registry/default facts, never Minecraft implementation source. */
public class ItemMetadata {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var playerType = BuiltInRegistries.ENTITY_TYPE.getOrThrow(ResourceKey.create(Registries.ENTITY_TYPE, Identifier.parse("minecraft:player")));
    Map<String, Object> items = new TreeMap<>();
    for (var item : BuiltInRegistries.ITEM) {
      Map<String, Object> facts = new TreeMap<>();
      facts.put("id", BuiltInRegistries.ITEM.getId(item));
      facts.put("max_stack_size", item.getDefaultMaxStackSize());
      Integer damage = item.components().get(DataComponents.MAX_DAMAGE);
      if (damage != null) facts.put("max_damage", damage);
      var equippable = item.components().get(DataComponents.EQUIPPABLE);
      if (equippable != null && equippable.canBeEquippedBy(playerType))
        facts.put("equipment_slot", equippable.slot().name().toLowerCase(Locale.ROOT));
      if (item.getClass().getMethod("overrideStackedOnOther", ItemStack.class, Slot.class, ClickAction.class, Player.class).getDeclaringClass() != Item.class ||
          item.getClass().getMethod("overrideOtherStackedOnMe", ItemStack.class, ItemStack.class, Slot.class, ClickAction.class, Player.class, SlotAccess.class).getDeclaringClass() != Item.class)
        facts.put("inventory_click_override", true);
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
    Map<String, Integer> inputs = new TreeMap<>();
    for (var input : ContainerInput.values()) inputs.put(input.name().toLowerCase(Locale.ROOT), input.id());
    facts.put("container_inputs", inputs);
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(facts) + "\n");
  }
}
