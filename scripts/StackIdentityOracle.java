import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponentType;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.*;
import net.minecraft.world.item.alchemy.*;
import net.minecraft.world.effect.*;

/** Original fixture generator: actual Mojang codecs normalize raw patches before equality. */
public class StackIdentityOracle {
  private static RegistryAccess.Frozen registries;
  private static final List<Map<String,Object>> cases = new ArrayList<>();
  private static final Set<String> SUPPORTED = Set.of("custom_data", "max_stack_size",
    "max_damage", "damage", "repair_cost", "rarity", "unbreakable", "creative_slot_lock",
    "intangible_projectile", "enchantment_glint_override", "item_model", "tooltip_style",
    "minimum_attack_charge", "custom_name", "item_name", "lore", "enchantments", "stored_enchantments", "tooltip_display", "food", "potion_contents");

  @SuppressWarnings("unchecked")
  private static <T> byte[] value(DataComponentType<T> type, Object value) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    try {
      type.streamCodec().encode(buf,(T)value);
      var bytes=new byte[buf.readableBytes()]; buf.readBytes(bytes); return bytes;
    } finally { buf.release(); }
  }
  private static DataComponentType<?> component(String name) {
    return BuiltInRegistries.DATA_COMPONENT_TYPE.getValue(Identifier.parse("minecraft:"+name));
  }
  private static byte[] raw(Item item, int count, Map<DataComponentType<?>,byte[]> added,
      List<DataComponentType<?>> removed, boolean untrusted) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    try {
      buf.writeVarInt(count); buf.writeVarInt(BuiltInRegistries.ITEM.getId(item));
      buf.writeVarInt(added.size()); buf.writeVarInt(removed.size());
      for (var entry : added.entrySet()) {
        buf.writeVarInt(BuiltInRegistries.DATA_COMPONENT_TYPE.getId(entry.getKey()));
        if (untrusted) buf.writeVarInt(entry.getValue().length);
        buf.writeBytes(entry.getValue());
      }
      for (var type : removed) buf.writeVarInt(BuiltInRegistries.DATA_COMPONENT_TYPE.getId(type));
      var bytes=new byte[buf.readableBytes()]; buf.readBytes(bytes); return bytes;
    } finally { buf.release(); }
  }
  private static ItemStack decode(byte[] bytes) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(bytes),registries);
    try {
      var stack=ItemStack.OPTIONAL_STREAM_CODEC.decode(buf);
      if (buf.isReadable()) throw new AssertionError("Trailing fixture bytes");
      return stack;
    } finally { buf.release(); }
  }
  private static void pair(String name, Item item, Map<DataComponentType<?>,byte[]> a,
      List<DataComponentType<?>> ar, Map<DataComponentType<?>,byte[]> b,
      List<DataComponentType<?>> br) {
    var left=raw(item,1,a,ar,false); var right=raw(item,1,b,br,false);
    cases.add(Map.of("name",name,"a",HexFormat.of().formatHex(left),
      "b",HexFormat.of().formatHex(right),"a_untrusted",HexFormat.of().formatHex(raw(item,1,a,ar,true)),
      "b_untrusted",HexFormat.of().formatHex(raw(item,1,b,br,true)),
      "same",ItemStack.isSameItemSameComponents(decode(left),decode(right))));
  }
  private static void nbt(String name,String a,String b) {
    pair(name,Items.STONE,Map.of(component("custom_data"),HexFormat.of().parseHex(a)),List.of(),
      Map.of(component("custom_data"),HexFormat.of().parseHex(b)),List.of());
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    for (var item:BuiltInRegistries.ITEM) {
      var name=BuiltInRegistries.ITEM.getKey(item).toString();
      for (var type:item.components().keySet()) {
        var key=BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type);
        if (SUPPORTED.contains(key.getPath())) pair(name+"/default/"+key.getPath(),item,
          Map.of(),List.of(),Map.of(type,value(type,item.components().get(type))),List.of());
      }
      pair(name+"/remove-absent",item,Map.of(),List.of(),Map.of(),List.of(component("custom_name")));
      pair(name+"/remove-present",item,Map.of(),List.of(),Map.of(),List.of(component("item_name")));
      var glint=component("enchantment_glint_override");
      pair(name+"/explicit-false",item,Map.of(),List.of(),Map.of(glint,value(glint,false)),List.of());
    }
    pair("stone/changed-cap",Items.STONE,Map.of(),List.of(),
      Map.of(component("max_stack_size"),value(component("max_stack_size"),32)),List.of());
    pair("stone/remove-repair-cost",Items.STONE,Map.of(),List.of(),Map.of(),List.of(component("repair_cost")));
    pair("sword/signed-zero-fraction",Items.IRON_SWORD,
      Map.of(component("minimum_attack_charge"),value(component("minimum_attack_charge"),0.0f)),List.of(),
      Map.of(component("minimum_attack_charge"),value(component("minimum_attack_charge"),-0.0f)),List.of());
    nbt("nbt/float-nan","0a0500016e7f80000100","0a0500016effc0000100");
    nbt("nbt/double-nan","0a0600016e7ff000000000000100","0a0600016efff800000000000100");
    nbt("nbt/float-zero","0a0500016e0000000000","0a0500016e8000000000");
    nbt("nbt/double-zero","0a0600016e000000000000000000","0a0600016e800000000000000000");
    nbt("nbt/empty-list","0a0900016e050000000000","0a0900016e060000000000");
    nbt("nbt/typed-number","0a0100016e0000","0a0300016e0000000000");
    var fire = BuiltInRegistries.POTION.get(Identifier.withDefaultNamespace("fire_resistance")).orElseThrow();
    var type = component("potion_contents");
    var head = new MobEffectInstance(MobEffects.FIRE_RESISTANCE,200,1,false,true,true);
    var suppressed = new MobEffectInstance(MobEffects.FIRE_RESISTANCE,200,1,false,true,true);
    var hidden = MobEffectInstance.class.getDeclaredField("hiddenEffect");hidden.setAccessible(true);
    hidden.set(suppressed,new MobEffectInstance(MobEffects.FIRE_RESISTANCE,600,3,true,false,false));
    var water = new MobEffectInstance(MobEffects.WATER_BREATHING,200,1,false,true,true);
    var values = List.of(PotionContents.EMPTY,
      new PotionContents(fire),
      new PotionContents(Optional.empty(),Optional.of(0),List.of(),Optional.empty()),
      new PotionContents(Optional.empty(),Optional.of(-1),List.of(),Optional.empty()),
      new PotionContents(Optional.empty(),Optional.empty(),List.of(),Optional.of("")),
      new PotionContents(Optional.empty(),Optional.empty(),List.of(),Optional.of("custom")),
      new PotionContents(Optional.empty(),Optional.empty(),List.of(head),Optional.empty()),
      new PotionContents(Optional.empty(),Optional.empty(),List.of(suppressed),Optional.empty()),
      new PotionContents(Optional.empty(),Optional.empty(),List.of(head,water),Optional.empty()),
      new PotionContents(Optional.empty(),Optional.empty(),List.of(water,head),Optional.empty()));
    for(int a=0;a<values.size();a++)for(int b=0;b<values.size();b++)
      pair("potion/value/"+a+"/"+b,Items.POTION,Map.of(type,value(type,values.get(a))),List.of(),
        Map.of(type,value(type,values.get(b))),List.of());
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: Generated "+cases.size()+" Mojang raw-patch equality cases across all item prototypes.");
  }
}
