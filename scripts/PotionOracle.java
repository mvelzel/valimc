import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.alchemy.*;

/** Native potion identities, structured stack codecs and duration-scaled effect delivery. No live actions. */
public class PotionOracle {
  static RegistryAccess.Frozen access; static Field hidden;
  static JsonArray rungs(MobEffectInstance value)throws Exception {
    var rows=new JsonArray();while(value!=null){var row=new JsonArray();row.add(value.getDuration());row.add(value.getAmplifier());row.add(value.isAmbient());row.add(value.isVisible());row.add(value.showIcon());rows.add(row);value=(MobEffectInstance)hidden.get(value);}return rows;
  }
  static JsonObject effect(MobEffectInstance value)throws Exception {var row=new JsonObject();row.addProperty("id",BuiltInRegistries.MOB_EFFECT.getId(value.getEffect().value()));row.add("rungs",rungs(value));return row;}
  static JsonArray effects(Iterable<MobEffectInstance> values)throws Exception {var rows=new JsonArray();for(var value:values)rows.add(effect(value));return rows;}
  static JsonObject contents(PotionContents value)throws Exception {
    var row=new JsonObject();row.add("potion",value.potion().<JsonElement>map(h->new JsonPrimitive(BuiltInRegistries.POTION.getId(h.value()))).orElse(JsonNull.INSTANCE));row.add("color",value.customColor().<JsonElement>map(JsonPrimitive::new).orElse(JsonNull.INSTANCE));row.add("effects",effects(value.customEffects()));row.add("name",value.customName().<JsonElement>map(JsonPrimitive::new).orElse(JsonNull.INSTANCE));return row;
  }
  static String wire(ItemStack value,boolean untrusted){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{(untrusted?ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC:ItemStack.OPTIONAL_STREAM_CODEC).encode(buffer,value);var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}
  }
  static String component(PotionContents value){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{PotionContents.STREAM_CODEC.encode(buffer,value);var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}
  }
  static Map<String,ItemStack> cases()throws Exception {
    var rows=new LinkedHashMap<String,ItemStack>();
    for(var potion:BuiltInRegistries.POTION.listElements().toList())for(var item:List.of(Items.POTION,Items.SPLASH_POTION,Items.LINGERING_POTION,Items.TIPPED_ARROW))rows.put("stock_"+rows.size(),PotionContents.createItemStack(item,potion));
    var fire=BuiltInRegistries.POTION.get(net.minecraft.resources.Identifier.withDefaultNamespace("fire_resistance")).orElseThrow();
    var longFire=BuiltInRegistries.POTION.get(net.minecraft.resources.Identifier.withDefaultNamespace("long_fire_resistance")).orElseThrow();
    List<Optional<Holder<Potion>>> options=List.of(Optional.empty(),Optional.of(fire),Optional.of(longFire));
    for(var potion:options)for(var color:Arrays.asList(null,0,0x102030,-1,Integer.MIN_VALUE,Integer.MAX_VALUE))for(var name:Arrays.asList(null,"custom","é😀"))for(int variant=0;variant<4;variant++){
      var custom=new ArrayList<MobEffectInstance>();
      if(variant==1)custom.add(new MobEffectInstance(MobEffects.FIRE_RESISTANCE,3600,0,false,true,true));
      if(variant==2){custom.add(new MobEffectInstance(MobEffects.FIRE_RESISTANCE,-1,255,true,false,true));custom.add(new MobEffectInstance(MobEffects.WATER_BREATHING,0,0,true,true,true));}
      if(variant==3){var value=new MobEffectInstance(MobEffects.FIRE_RESISTANCE,2,2,false,true,false);hidden.set(value,new MobEffectInstance(MobEffects.FIRE_RESISTANCE,300,0,true,false,true));custom.add(value);}
      var value=new ItemStack(Items.POTION);value.set(DataComponents.POTION_CONTENTS,new PotionContents(potion,Optional.ofNullable(color),custom,Optional.ofNullable(name)));rows.put("patched_"+rows.size(),value);
    }
    for(int ticks:new int[]{Integer.MIN_VALUE,-20,-2,-1,0,1,127,128,2_147_483_583,Integer.MAX_VALUE})for(int flags=0;flags<8;flags++){
      var value=new ItemStack(Items.POTION);value.set(DataComponents.POTION_CONTENTS,new PotionContents(Optional.empty(),Optional.empty(),List.of(new MobEffectInstance(MobEffects.FIRE_RESISTANCE,ticks,255,(flags&1)!=0,(flags&2)!=0,(flags&4)!=0)),Optional.empty()));rows.put("duration_"+rows.size(),value);
    }
    var all=new ItemStack(Items.POTION);var custom=new ArrayList<MobEffectInstance>();for(var holder:BuiltInRegistries.MOB_EFFECT.listElements().toList())custom.add(new MobEffectInstance(holder,200,0));all.set(DataComponents.POTION_CONTENTS,new PotionContents(Optional.empty(),Optional.empty(),custom,Optional.empty()));rows.put("all_effects",all);
    return rows;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();hidden=MobEffectInstance.class.getDeclaredField("hiddenEffect");hidden.setAccessible(true);var cases=cases();
    if(args[0].equals("verify")){
      var rows=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for(var entry:rows){var row=entry.getAsJsonObject();var expected=cases.get(row.get("name").getAsString());for(var mode:List.of("trusted","untrusted")){
        var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(row.get(mode).getAsString())),access);
        try{var codec=mode.equals("untrusted")?ItemStack.validatedStreamCodec(ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC):ItemStack.OPTIONAL_STREAM_CODEC;var actual=codec.decode(buffer);if(buffer.isReadable()||!ItemStack.matches(expected,actual))throw new AssertionError("Native potion stack differs: "+row.get("name"));}finally{buffer.release();}
      }}if(rows.size()!=cases.size())throw new AssertionError("Missing potion stacks");System.out.println("PASS: "+rows.size()+" independently encoded potion stacks validated natively in both formats.");return;
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");var potions=new JsonArray();
    for(var potion:BuiltInRegistries.POTION.listElements().sorted(Comparator.comparingInt(h->BuiltInRegistries.POTION.getId(h.value()))).toList()){var row=new JsonObject();row.addProperty("id",BuiltInRegistries.POTION.getId(potion.value()));row.addProperty("name",potion.unwrapKey().orElseThrow().identifier().toString());row.add("effects",effects(potion.value().getEffects()));potions.add(row);}facts.add("potions",potions);
    var defaults=new JsonObject();for(var item:BuiltInRegistries.ITEM){var value=item.components().get(DataComponents.POTION_CONTENTS);if(value!=null)defaults.addProperty(Integer.toString(BuiltInRegistries.ITEM.getId(item)),component(value));}facts.add("default_contents",defaults);Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(facts)+"\n");
    var rows=new JsonArray();for(var entry:cases.entrySet()){
      var row=new JsonObject();row.addProperty("name",entry.getKey());row.addProperty("item",BuiltInRegistries.ITEM.getId(entry.getValue().getItem()));row.addProperty("patched",!entry.getValue().getComponentsPatch().isEmpty());var value=entry.getValue().get(DataComponents.POTION_CONTENTS);row.add("contents",contents(value));row.addProperty("trusted",wire(entry.getValue(),false));row.addProperty("untrusted",wire(entry.getValue(),true));var scaled=new JsonArray();
      for(float scale:new float[]{0,Float.MIN_VALUE,.01f,.333f,.5f,1,Math.nextUp(1f),1024,Float.MAX_VALUE}){var result=new ArrayList<MobEffectInstance>();value.forEachEffect(result::add,scale);var observation=new JsonObject();observation.addProperty("scale",(double)scale);observation.add("effects",effects(result));scaled.add(observation);}row.add("scaled",scaled);rows.add(row);
    }Files.writeString(Path.of(args[1]),new Gson().toJson(rows));System.out.println("PASS: "+potions.size()+" native potion holders, "+defaults.size()+" defaults and "+rows.size()+" dual-format stacks/scaled-delivery contexts. Color/name/hidden/custom effects included; application, instant effects, consumption and client excluded.");
  }
}
