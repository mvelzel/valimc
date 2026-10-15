import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.tags.ItemTags;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.level.GameType;

/** Actual player freeze eligibility with supplied worn stacks/modes; no world or health simulation. */
public class FreezingEligibilityOracle {
  private static class Probe extends Player {
    GameType mode; EquipmentSlot slot; ItemStack stack; int frozen;
    private Probe(){super(null,null);}
    public GameType gameMode(){return mode;}
    public ItemStack getItemBySlot(EquipmentSlot candidate){return candidate==slot?stack:ItemStack.EMPTY;}
    public int getTicksFrozen(){return frozen;}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static int menuSlot(EquipmentSlot slot){return switch(slot){case HEAD->5;case CHEST->6;case LEGS->7;case FEET->8;case MAINHAND->36;case OFFHAND->45;default->throw new AssertionError(slot);};}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var tags=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject();
    var wearableIds=new HashSet<Integer>();for(var id:tags.getAsJsonObject("minecraft:item").getAsJsonArray("minecraft:freeze_immune_wearables"))wearableIds.add(id.getAsInt());
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var item:BuiltInRegistries.ITEM)bind.invoke(item.builtInRegistryHolder(),wearableIds.contains(BuiltInRegistries.ITEM.getId(item))?List.of(ItemTags.FREEZE_IMMUNE_WEARABLES):List.of());
    for(var id:tags.getAsJsonObject("minecraft:entity_type").getAsJsonArray("minecraft:freeze_immune_entity_types"))
      if(id.getAsInt()==BuiltInRegistries.ENTITY_TYPE.getId(EntityTypes.PLAYER))throw new AssertionError("Player type is freeze immune");
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);var p=(Probe)unsafe.allocateInstance(Probe.class);field(Entity.class,"type").set(p,EntityTypes.PLAYER);
    var cases=new JsonArray();
    for(var mode:GameType.values())for(var slot:List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET,EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND))for(var item:BuiltInRegistries.ITEM){
      p.mode=mode;p.slot=slot;p.stack=new ItemStack(item);var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("slot",menuSlot(slot));c.addProperty("item_id",BuiltInRegistries.ITEM.getId(item));c.addProperty("allowed",p.canFreeze());cases.add(c);
    }
    var thresholds=new JsonArray();
    for(int ticks:new int[]{0,1,139,140,141}){p.frozen=ticks;var c=new JsonObject();c.addProperty("ticks",ticks);c.addProperty("fully",p.isFullyFrozen());thresholds.add(c);}
    var result=new JsonObject();result.add("equipment",cases);result.add("thresholds",thresholds);result.addProperty("required",p.getTicksRequiredToFreeze());
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native player freeze eligibility cases across every item, four modes and six equipment/hand slots; native full-freeze threshold="+p.getTicksRequiredToFreeze()+".");
  }
}
