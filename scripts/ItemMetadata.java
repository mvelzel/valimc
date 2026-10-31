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

/**
 * Extract versioned registry/default facts, never Minecraft implementation source.
 * Usage: ItemMetadata ITEMS.json ITEM_DEFAULTS.json COMPONENT_TYPES.json BUILTIN_REGISTRIES.json
 */
public class ItemMetadata {
  // Enums that component values name: data codecs write the serialized name, stream
  // codecs the id each enum's own `STREAM_CODEC` writes (VMC-004b4).
  private static final Map<String, Class<?>> ENUMS = new TreeMap<>(Map.of(
    "dye_color", net.minecraft.world.item.DyeColor.class,
    "firework_shape", net.minecraft.world.item.component.FireworkExplosion.Shape.class,
    "swing_animation", net.minecraft.world.item.SwingAnimationType.class,
    "fox_variant", net.minecraft.world.entity.animal.fox.Fox.Variant.class,
    "parrot_variant", net.minecraft.world.entity.animal.parrot.Parrot.Variant.class,
    "mooshroom_variant", net.minecraft.world.entity.animal.cow.MushroomCow.Variant.class,
    "rabbit_variant", net.minecraft.world.entity.animal.rabbit.Rabbit.Variant.class,
    "horse_variant", net.minecraft.world.entity.animal.equine.Variant.class,
    "llama_variant", net.minecraft.world.entity.animal.equine.Llama.Variant.class,
    "map_post_processing", net.minecraft.world.item.component.MapPostProcessing.class));
  static {
    ENUMS.putAll(Map.of(
      "equipment_slot", net.minecraft.world.entity.EquipmentSlot.class,
      "equipment_slot_group", net.minecraft.world.entity.EquipmentSlotGroup.class,
      "attribute_operation", net.minecraft.world.entity.ai.attributes.AttributeModifier.Operation.class,
      "item_use_animation", net.minecraft.world.item.ItemUseAnimation.class,
      "attribute_display", net.minecraft.world.item.component.ItemAttributeModifiers.Display.Type.class));
  }
  // Built-in registries whose network ids component values carry.
  private static final List<String> BUILTIN = List.of("attribute", "block_entity_type",
    "consume_effect_type", "sound_event", "villager_type");
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
  @SuppressWarnings({"unchecked", "rawtypes"})
  private static List<Object> enumValues(Class<?> type) throws Exception {
    var field = type.getDeclaredField("STREAM_CODEC"); field.setAccessible(true);
    var codec = (net.minecraft.network.codec.StreamCodec) field.get(null);
    var values = new ArrayList<Object>();
    for (var constant : type.getEnumConstants()) {
      var buf = new net.minecraft.network.FriendlyByteBuf(Unpooled.buffer());
      try {
        codec.encode(buf, constant);
        var name = constant instanceof net.minecraft.util.StringRepresentable named
          ? named.getSerializedName() : ((Enum<?>) constant).name().toLowerCase(Locale.ROOT);
        values.add(List.of(buf.readVarInt(), name));
        if (buf.isReadable()) throw new AssertionError("Enum stream id is not one VarInt: " + type);
      } finally { buf.release(); }
    }
    return values;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var playerType = BuiltInRegistries.ENTITY_TYPE.getOrThrow(ResourceKey.create(Registries.ENTITY_TYPE, Identifier.parse("minecraft:player")));
    Map<String, Object> items = new TreeMap<>();
    Map<String, Object> defaults = new TreeMap<>();
    var registries = NetworkRegistries.load(lookup);
    // Default values, deduplicated: most items share their common components.
    var table = new ArrayList<String>();
    var indices = new HashMap<String,Integer>();
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
      var encoded = new TreeMap<String,Integer>();
      // Registry order: a component map iterates by identity hash, which varies between runs.
      for (var type : item.components().keySet().stream().sorted(Comparator.comparingInt(BuiltInRegistries.DATA_COMPONENT_TYPE::getId)).toList()) {
        var name = BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type);
        present.add(name.toString());
        var hex = encodeDefault(type, item.components().get(type), registries);
        encoded.put(name.toString(), indices.computeIfAbsent(hex, h -> { table.add(h); return table.size() - 1; }));
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
    facts.put("items", items);
    facts.put("player_actions", actions);
    Map<String, Integer> inputs = new TreeMap<>();
    for (var input : ContainerInput.values()) inputs.put(input.name().toLowerCase(Locale.ROOT), input.id());
    facts.put("container_inputs", inputs);
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(facts) + "\n");
    // Component type ids are their own facts (`Valimc.Protocol.ComponentTypes`), which the item
    // defaults' codecs need before the items exist.
    var componentFacts = new TreeMap<String,Object>();
    componentFacts.put("version", "26.3"); componentFacts.put("protocol", 777); componentFacts.put("components", components);
    var enums = new TreeMap<String,Object>();
    for (var entry : ENUMS.entrySet()) enums.put(entry.getKey(), enumValues(entry.getValue()));
    componentFacts.put("enums", enums);
    Files.writeString(Path.of(args[2]), new GsonBuilder().setPrettyPrinting().create().toJson(componentFacts) + "\n");
    var extracted = new LinkedHashMap<String,Object>();
    extracted.put("version","26.3");extracted.put("data_version",5023);extracted.put("items",defaults);
    extracted.put("values",table);
    extracted.put("protocol",777);extracted.put("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    Files.writeString(Path.of(args[1]),new GsonBuilder().setPrettyPrinting().create().toJson(extracted)+"\n");
    var builtin = new TreeMap<String,Object>();
    for (var name : BUILTIN) {
      var registry = BuiltInRegistries.REGISTRY.getValue(Identifier.withDefaultNamespace(name));
      var entries = new ArrayList<String>();
      for (int id = 0; id < registry.size(); id++) entries.add(((net.minecraft.core.Registry<?>) registry).byId(id) == null ? null
        : ((net.minecraft.core.Registry) registry).getKey(((net.minecraft.core.Registry<?>) registry).byId(id)).toString());
      builtin.put("minecraft:" + name, entries);
    }
    var builtinFacts = new LinkedHashMap<String,Object>();
    builtinFacts.put("version","26.3");builtinFacts.put("protocol",777);builtinFacts.put("registries",builtin);
    Files.writeString(Path.of(args[3]),new GsonBuilder().setPrettyPrinting().create().toJson(builtinFacts)+"\n");
  }
}
