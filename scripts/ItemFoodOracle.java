import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.food.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.*;
import net.minecraft.world.level.GameType;

/** Original default facts and native food codecs/eligibility/duration/remainder observations. */
public class ItemFoodOracle {
  private static RegistryAccess.Frozen access;
  private static class Probe extends Player {
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
  }
  private static JsonObject food(FoodProperties value){
    var row=new JsonObject();row.addProperty("nutrition",value.nutrition());row.addProperty("saturation",(double)value.saturation());row.addProperty("can_always_eat",value.canAlwaysEat());return row;
  }
  private static String wire(ItemStack stack,boolean untrusted){
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{(untrusted?ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC:ItemStack.OPTIONAL_STREAM_CODEC).encode(buf,stack);var bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buf.release();}
  }
  private static JsonObject stack(ItemStack value){
    var row=new JsonObject();row.addProperty("item_id",value.isEmpty()?0:BuiltInRegistries.ITEM.getId(value.getItem()));row.addProperty("count",value.getCount());
    if(!value.getComponentsPatch().isEmpty())throw new AssertionError("Patched default remainder needs expanded facts");return row;
  }
  private static Map<String,ItemStack> cases(){
    var result=new LinkedHashMap<String,ItemStack>();
    for(int nutrition:new int[]{0,1,6,20,Integer.MAX_VALUE-20,Integer.MAX_VALUE})for(float saturation:new float[]{0,-0.0f,.1f,5,Float.MAX_VALUE})for(boolean always:new boolean[]{false,true}){
      var value=new ItemStack(Items.STONE);value.set(DataComponents.FOOD,new FoodProperties(nutrition,saturation,always));result.put("food_"+result.size(),value);
    }
    return result;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    var cases=cases();
    if(args[0].equals("verify")){
      var rows=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for(var entry:rows){var row=entry.getAsJsonObject();var expected=cases.get(row.get("name").getAsString());if(expected==null)throw new AssertionError(row);
        for(var mode:List.of("trusted","untrusted")){
          var buf=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(row.get(mode).getAsString())),access);
          try{var codec=mode.equals("untrusted")?ItemStack.validatedStreamCodec(ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC):ItemStack.OPTIONAL_STREAM_CODEC;
            var actual=codec.decode(buf);if(buf.isReadable()||!ItemStack.matches(expected,actual))throw new AssertionError(row);
          }finally{buf.release();}
        }
      }
      if(rows.size()!=cases.size())throw new AssertionError("Missing food codec cases");
      System.out.println("PASS: native decoding/validation of "+rows.size()+" food-patched stacks in both formats.");return;
    }
    var facts=new JsonObject();var items=new JsonObject();
    for(var item:BuiltInRegistries.ITEM){
      var value=new ItemStack(item);var food=value.get(DataComponents.FOOD);var consumable=value.get(DataComponents.CONSUMABLE);var remainder=value.get(DataComponents.USE_REMAINDER);
      var listeners=new JsonArray();for(var type:item.components().keySet())if(type!=DataComponents.FOOD&&item.components().get(type) instanceof ConsumableListener)listeners.add(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(type).toString());
      if(food==null&&consumable==null&&remainder==null&&listeners.isEmpty())continue;
      var row=new JsonObject();row.addProperty("item_id",BuiltInRegistries.ITEM.getId(item));if(food!=null)row.add("food",food(food));
      if(consumable!=null){var c=new JsonObject();c.addProperty("seconds",(double)consumable.consumeSeconds());c.addProperty("ticks",consumable.consumeTicks());c.addProperty("animation",consumable.animation().name().toLowerCase(Locale.ROOT));c.addProperty("sound",consumable.sound().unwrapKey().orElseThrow().identifier().toString());c.addProperty("particles",consumable.hasConsumeParticles());c.addProperty("effects",consumable.onConsumeEffects().size());row.add("consumable",c);}
      if(remainder!=null)row.add("remainder",stack(remainder.convertInto().create()));row.add("other_listeners",listeners);items.add(BuiltInRegistries.ITEM.getKey(item).toString(),row);
    }
    facts.addProperty("version","26.3");facts.addProperty("protocol",777);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.add("items",items);
    Files.writeString(Path.of(args[1]),new GsonBuilder().setPrettyPrinting().create().toJson(facts)+"\n");
    var rows=new JsonArray();for(var entry:cases.entrySet()){var row=new JsonObject();row.addProperty("name",entry.getKey());row.add("food",food(entry.getValue().get(DataComponents.FOOD)));row.addProperty("trusted",wire(entry.getValue(),false));row.addProperty("untrusted",wire(entry.getValue(),true));rows.add(row);}
    var ufield=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");ufield.setAccessible(true);var p=(Probe)((sun.misc.Unsafe)ufield.get(null)).allocateInstance(Probe.class);
    var abilities=Player.class.getDeclaredField("abilities");abilities.setAccessible(true);var foodField=Player.class.getDeclaredField("foodData");foodField.setAccessible(true);
    var control=Items.APPLE.components().get(DataComponents.CONSUMABLE);var eligibility=new JsonArray();
    for(var mode:GameType.values())for(int level:new int[]{0,6,19,20})for(boolean present:new boolean[]{false,true})for(boolean always:new boolean[]{false,true}){
      var a=new Abilities();mode.updatePlayerAbilities(a);abilities.set(p,a);var f=new FoodData();f.setFoodLevel(level);foodField.set(p,f);
      var value=new ItemStack(Items.STONE);if(present)value.set(DataComponents.FOOD,new FoodProperties(1,1,always));
      var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("level",level);c.addProperty("food",present);c.addProperty("always",always);c.addProperty("allowed",control.canConsume(p,value));eligibility.add(c);
    }
    var durations=new JsonArray();for(float seconds:new float[]{0,Math.nextDown(.05f),.05f,Math.nextUp(.05f),1.6f,3.2f,100000000,Float.MAX_VALUE}){
      var c=new JsonObject();c.addProperty("seconds",(double)seconds);c.addProperty("ticks",new Consumable(seconds,control.animation(),control.sound(),true,List.of()).consumeTicks());durations.add(c);
    }
    var remnants=new JsonArray();var bowl=Items.MUSHROOM_STEW.components().get(DataComponents.USE_REMAINDER);
    for(int old:new int[]{1,2,64})for(int consumed:new int[]{0,1})for(boolean infinite:new boolean[]{false,true}){
      var after=new ItemStack(Items.STONE,old-consumed);var extra=new JsonArray();var result=bowl.convertIntoRemainder(after,old,infinite,value->extra.add(stack(value)));
      var c=new JsonObject();c.addProperty("old",old);c.addProperty("consumed",consumed);c.addProperty("infinite",infinite);c.add("result",stack(result));c.add("extra",extra);remnants.add(c);
    }
    var result=new JsonObject();result.add("codecs",rows);result.add("eligibility",eligibility);result.add("durations",durations);result.add("remainders",remnants);
    Files.writeString(Path.of(args[2]),new Gson().toJson(result));
    System.out.println("PASS: "+items.size()+" native consumable/default facts, "+rows.size()+" food codec pairs, "+eligibility.size()+" real consumption gates, "+durations.size()+" durations and "+remnants.size()+" remainder conversions; world/effects/completion excluded.");
  }
}
