import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.component.DataComponentType;
import net.minecraft.core.RegistryAccess;
import net.minecraft.network.RegistryFriendlyByteBuf;
import io.netty.buffer.Unpooled;
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
  private static final Set<String> SUPPORTED = Set.of("custom_data", "max_stack_size",
    "max_damage", "damage", "repair_cost", "rarity", "unbreakable", "creative_slot_lock",
    "intangible_projectile", "enchantment_glint_override", "item_model", "tooltip_style",
    "minimum_attack_charge", "custom_name", "item_name", "lore", "enchantments", "stored_enchantments", "tooltip_display", "food", "potion_contents",
    "suspicious_stew_effects", "instrument", "ominous_bottle_amplifier", "map_id");
  @SuppressWarnings("unchecked")
  private static <T> String encodeDefault(DataComponentType<T> type, Object value,
      RegistryAccess.Frozen registries) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      type.streamCodec().encode(buf, (T)value);
      var bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes);
      return HexFormat.of().formatHex(bytes);
    } finally { buf.release(); }
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var playerType = BuiltInRegistries.ENTITY_TYPE.getOrThrow(ResourceKey.create(Registries.ENTITY_TYPE, Identifier.parse("minecraft:player")));
    Map<String, Object> items = new TreeMap<>();
    Map<String, Object> defaults = new TreeMap<>();
    var registries = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
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
      var present = new TreeSet<String>();
      var encoded = new TreeMap<String,String>();
      for (var type : item.components().keySet()) {
        var name = BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type);
        present.add(name.toString());
        if (type == DataComponents.INSTRUMENT) {
          // A data-driven holder: the network id is its index in the loaded
          // registry, which a data pack lists in identifier order.
          var key = ((net.minecraft.world.item.component.InstrumentComponent) item.components().get(type))
            .instrument().unwrapKey().orElseThrow().identifier().toString();
          var keys = lookup.lookupOrThrow(Registries.INSTRUMENT).listElementIds()
            .map(k -> k.identifier().toString()).sorted().toList();
          encoded.put(name.toString(), HexFormat.of().formatHex(new byte[] {(byte) (keys.indexOf(key) + 1)}));
        } else if (name.getNamespace().equals("minecraft") && SUPPORTED.contains(name.getPath()))
          encoded.put(name.toString(), encodeDefault(type, item.components().get(type), registries));
      }
      var prototype = new LinkedHashMap<String,Object>();
      prototype.put("values",encoded);prototype.put("present",present);
      defaults.put(Integer.toString(BuiltInRegistries.ITEM.getId(item)),prototype);
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
    if (args.length > 1) {
      var extracted = new LinkedHashMap<String,Object>();
      extracted.put("version","26.3");extracted.put("data_version",5023);extracted.put("items",defaults);
      extracted.put("protocol",777);extracted.put("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
      Files.writeString(Path.of(args[1]),new GsonBuilder().setPrettyPrinting().create().toJson(extracted)+"\n");
    }
  }
}
