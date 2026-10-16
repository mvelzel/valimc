import com.google.gson.*;
import com.mojang.serialization.*;
import io.netty.buffer.Unpooled;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.nbt.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.*;
import net.minecraft.network.protocol.game.*;
import net.minecraft.resources.RegistryOps;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.Unit;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.effect.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.alchemy.PotionContents;
import net.minecraft.world.item.enchantment.Enchantment;
import net.minecraft.world.level.GameType;

/** Original data-format/hover fixtures for already supported stack components. */
public class ItemHoverOracle {
  static RegistryAccess.Frozen access;
  static HolderLookup.Provider lookup;
  static final Map<String,ItemStack> cases=new LinkedHashMap<>();
  static class Body extends Player {
    ItemStack hand;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public Component getDisplayName(){return Component.literal("ValiMCTest");}
    public ItemStack getMainHandItem(){return hand;}
  }
  static void add(String name,String item,int count,String patch) {
    var row=new JsonObject();row.addProperty("id","minecraft:"+item);row.addProperty("count",count);
    row.add("components",JsonParser.parseString(patch));
    cases.put(name,ItemStack.CODEC.parse(RegistryOps.create(JsonOps.INSTANCE,lookup),row).getOrThrow());
  }
  static void generate() throws Exception {
    add("plain","potion",1,"{}");
    add("name_only","potion",1,"{\"minecraft:item_name\":\"Type name\"}");
    for(int rarity=0;rarity<4;rarity++)for(String enchant:List.of("none","active","stored","glint")){
      var patch=new JsonObject();patch.addProperty("minecraft:custom_name","Unsafe brew é😀");
      patch.addProperty("minecraft:rarity",List.of("common","uncommon","rare","epic").get(rarity));
      if(enchant.equals("active"))patch.add("minecraft:enchantments",JsonParser.parseString("{\"minecraft:protection\":4}"));
      if(enchant.equals("stored"))patch.add("minecraft:stored_enchantments",JsonParser.parseString("{\"minecraft:protection\":4}"));
      if(enchant.equals("glint"))patch.addProperty("minecraft:enchantment_glint_override",true);
      add("rarity_"+rarity+"_"+enchant,"potion",1,patch.toString());
    }
    add("styled","stone",17,"{\"minecraft:custom_name\":{\"text\":\"Cold\",\"italic\":false,\"color\":\"#123456\",\"extra\":[\" brew\"]},\"minecraft:custom_data\":{\"payload\":[1,2,3],\"nested\":{\"a\":true}},\"minecraft:lore\":[\"one\",{\"text\":\"two\",\"bold\":true}]}");
    add("units","stone",1,"{\"minecraft:custom_name\":\"Units\",\"minecraft:unbreakable\":{},\"minecraft:intangible_projectile\":{}}");
    cases.get("units").set(DataComponents.CREATIVE_SLOT_LOCK,Unit.INSTANCE);
    add("damage","iron_sword",1,"{\"minecraft:custom_name\":\"Worn\",\"minecraft:max_damage\":1234,\"minecraft:damage\":17,\"minecraft:repair_cost\":22}");
    add("identifiers","stone",1,"{\"minecraft:custom_name\":\"IDs\",\"minecraft:item_model\":\"minecraft:potion\",\"minecraft:tooltip_style\":\"test:plain\",\"minecraft:minimum_attack_charge\":0.5}");
    add("food","stone",64,"{\"minecraft:custom_name\":\"Food\",\"minecraft:food\":{\"nutrition\":6,\"saturation\":0.25,\"can_always_eat\":true}}");
    add("food_defaults","stone",1,"{\"minecraft:custom_name\":\"Food defaults\",\"minecraft:food\":{\"nutrition\":0,\"saturation\":0.0}}");
    add("tooltip","stone",1,"{\"minecraft:custom_name\":\"Hidden\",\"minecraft:tooltip_display\":{\"hide_tooltip\":true,\"hidden_components\":[\"minecraft:lore\",\"minecraft:food\"]}}");
    add("tooltip_empty","stone",1,"{\"minecraft:custom_name\":\"Visible\",\"minecraft:tooltip_display\":{}}");
    add("potion","potion",1,"{\"minecraft:custom_name\":\"Mixed\",\"minecraft:potion_contents\":{\"potion\":\"minecraft:strong_harming\",\"custom_color\":-1,\"custom_name\":\"brew\",\"custom_effects\":[{\"id\":\"minecraft:resistance\",\"amplifier\":2,\"duration\":-1,\"ambient\":true,\"show_particles\":false,\"show_icon\":true,\"hidden_effect\":{\"amplifier\":1,\"duration\":200}}]}}");
    add("potion_empty","potion",1,"{\"minecraft:custom_name\":\"Empty\",\"minecraft:potion_contents\":{}}");
    add("removed","stone",1,"{\"minecraft:custom_name\":\"Removed\",\"!minecraft:item_name\":{},\"!minecraft:enchantments\":{},\"!minecraft:custom_data\":{}}");
    add("defaults","stone",1,"{\"minecraft:custom_name\":\"Defaults\",\"minecraft:max_stack_size\":64,\"minecraft:rarity\":\"common\",\"minecraft:lore\":[],\"minecraft:enchantments\":{}}");
    add("stack99","stone",99,"{\"minecraft:custom_name\":\"Many\",\"minecraft:max_stack_size\":99}");
    var large=new JsonObject();large.addProperty("minecraft:custom_name","N".repeat(30000));
    var custom=new JsonObject();custom.addProperty("payload","D".repeat(25000));large.add("minecraft:custom_data",custom);
    add("large","potion",1,large.toString());
    var hiddenField=MobEffectInstance.class.getDeclaredField("hiddenEffect");hiddenField.setAccessible(true);
    var hidden=cases.get("potion").get(DataComponents.POTION_CONTENTS).customEffects().getFirst();
    hiddenField.set(hidden,new MobEffectInstance(MobEffects.RESISTANCE,600,0));
    for(int amp=0;amp<256;amp++){
      var value=new ItemStack(Items.POTION);value.set(DataComponents.CUSTOM_NAME,Component.literal("Amplifier"));
      value.set(DataComponents.POTION_CONTENTS,new PotionContents(Optional.empty(),Optional.empty(),List.of(new MobEffectInstance(MobEffects.INSTANT_DAMAGE,0,amp,false,true,true)),Optional.empty()));cases.put("amp_"+amp,value);
    }
    for(int flags=0;flags<8;flags++)for(int ticks:new int[]{Integer.MIN_VALUE,-2,-1,0,1,200,Integer.MAX_VALUE}){
      var value=new ItemStack(Items.POTION);value.set(DataComponents.CUSTOM_NAME,Component.literal("Effect flags"));
      value.set(DataComponents.POTION_CONTENTS,new PotionContents(Optional.empty(),Optional.empty(),List.of(new MobEffectInstance(MobEffects.RESISTANCE,ticks,1,(flags&1)!=0,(flags&2)!=0,(flags&4)!=0)),Optional.empty()));cases.put("flags_"+flags+"_"+ticks,value);
    }
  }
  static String wire(ItemStack value){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{ItemStack.OPTIONAL_STREAM_CODEC.encode(buffer,value);byte[] bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}
  }
  static String nbt(Tag value)throws Exception {
    var bytes=new ByteArrayOutputStream();NbtIo.writeAnyTag(value,new DataOutputStream(bytes));return HexFormat.of().formatHex(bytes.toByteArray());
  }
  static Tag nbt(String value)throws Exception {
    var input=new DataInputStream(new ByteArrayInputStream(HexFormat.of().parseHex(value)));
    var tag=NbtIo.readAnyTag(input,NbtAccounter.unlimitedHeap());if(input.available()!=0)throw new AssertionError("Trailing NBT");return tag;
  }
  static JsonElement component(Component value){return ComponentSerialization.CODEC.encodeStart(RegistryOps.create(JsonOps.INSTANCE,lookup),value).getOrThrow();}
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var enchant=new MappedRegistry<Enchantment>(Registries.ENCHANTMENT,Lifecycle.stable());
    lookup.lookupOrThrow(Registries.ENCHANTMENT).listElements().sorted(Comparator.comparing(h->h.key().identifier().toString())).forEach(h->enchant.register(h.key(),h.value(),RegistrationInfo.BUILT_IN));
    enchant.bindAllTagsToEmpty();enchant.freeze();
    var all=new ArrayList<Registry<?>>(BuiltInRegistries.REGISTRY.stream().toList());all.add(enchant);
    access=new RegistryAccess.ImmutableRegistryAccess(all).freeze();generate();
    var transientNames=BuiltInRegistries.DATA_COMPONENT_TYPE.stream().filter(t->t.codec()==null).map(t->BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(t).toString()).sorted().toList();
    if(!transientNames.equals(List.of("minecraft:additional_trade_cost","minecraft:creative_slot_lock","minecraft:map_post_processing")))throw new AssertionError("Transient component facts changed");
    System.out.println("Network-only components omitted by data codecs: "+transientNames);
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var body=(Body)((sun.misc.Unsafe)field.get(null)).allocateInstance(Body.class);body.setId(1);
    var source=new DamageSource(lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(DamageTypes.INDIRECT_MAGIC),body,body);
    var rows=new JsonArray();int checked=0;
    JsonArray candidates=args[0].equals("verify")?JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray():null;
    for(var entry:cases.entrySet()){
      var stack=entry.getValue();body.hand=stack;var death=source.getLocalizedDeathMessage(body);
      var data=ItemStack.CODEC.encodeStart(RegistryOps.create(NbtOps.INSTANCE,lookup),stack).getOrThrow();
      var row=new JsonObject();row.addProperty("name",entry.getKey());row.addProperty("stack",wire(stack));row.addProperty("data",nbt(data));row.add("display",component(stack.getDisplayName()));row.add("death",component(death));
      if(candidates!=null){
        var candidate=candidates.asList().stream().map(JsonElement::getAsJsonObject).filter(c->c.get("name").equals(row.get("name"))).findFirst().orElseThrow();
        var parsed=ItemStack.CODEC.parse(RegistryOps.create(NbtOps.INSTANCE,lookup),nbt(candidate.get("data").getAsString())).getOrThrow();
        var expected=ItemStack.CODEC.parse(RegistryOps.create(NbtOps.INSTANCE,lookup),data).getOrThrow();
        if(!ItemStack.matches(parsed,expected))throw new AssertionError("Item data differs: "+entry.getKey()+" actual="+nbt(candidate.get("data").getAsString())+" expected="+data);
        var decoded=ComponentSerialization.CODEC.parse(RegistryOps.create(NbtOps.INSTANCE,lookup),nbt(candidate.get("death").getAsString())).getOrThrow();
        if(!component(decoded).equals(component(death)))throw new AssertionError("Death component differs: "+entry.getKey()+" actual="+component(decoded)+" expected="+component(death));
        for(String kind:List.of("death_packet","chat_packet")){
          var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(candidate.get(kind).getAsString())),access);
          try {
            var packet=GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().decode(buffer);
            Component message;
            if(packet instanceof ClientboundPlayerCombatKillPacket p)message=p.message();
            else if(packet instanceof ClientboundSystemChatPacket p && !p.overlay())message=p.content();
            else throw new AssertionError("Wrong packet: "+kind);
            // Rebind the independently constructed reference to the negotiated holder set.
            // Component equality also preserves native unordered tooltip-set semantics.
            var expectedMessage=ComponentSerialization.CODEC.parse(RegistryOps.create(JsonOps.INSTANCE,access),component(death)).getOrThrow();
            if(buffer.isReadable() || !message.equals(expectedMessage))throw new AssertionError("Packet component differs: "+entry.getKey()+" "+kind);
          } finally {buffer.release();}
        }
        checked++;
      }
      rows.add(row);
    }
    if(candidates!=null){if(candidates.size()!=checked)throw new AssertionError("Wrong fixture count");System.out.println("PASS: "+checked+" Elixir item data/death hovers and "+(2*checked)+" death/chat packets native-decode with matching component semantics.");}
    else{Files.writeString(Path.of(args[0]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" native stack/data/display/self-death contexts across supported component families.");}
  }
}
