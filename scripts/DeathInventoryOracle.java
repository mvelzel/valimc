import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.CustomData;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;

/** Original native vanishing/drop-order probe. Item creation/world physics are deliberately excluded. */
public class DeathInventoryOracle {
  private static class Probe extends Player {
    final List<Integer> dropped=new ArrayList<>();
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    void vanish(){destroyVanishingCursedItems();}
    public ItemEntity createItemStackToDrop(ItemStack stack,boolean scatter,boolean owner){
      if(!scatter||owner)throw new AssertionError("Death drop flags");
      dropped.add(stack.get(DataComponents.CUSTOM_DATA).copyTag().getIntOr("slot",-1));return null;
    }
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var source=lookup.lookupOrThrow(Registries.ENCHANTMENT);var enchantments=new MappedRegistry<Enchantment>(Registries.ENCHANTMENT,Lifecycle.stable());
    for(var id:source.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())enchantments.register(id,source.getOrThrow(id).value(),RegistrationInfo.BUILT_IN);
    enchantments.freeze();var access=new RegistryAccess.ImmutableRegistryAccess(List.of(enchantments)).freeze();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);var player=(Probe)unsafe.allocateInstance(Probe.class);
    var dropped=Probe.class.getDeclaredField("dropped");dropped.setAccessible(true);dropped.set(player,new ArrayList<Integer>());
    var inventory=new Inventory(player,new EntityEquipment());var field=Player.class.getDeclaredField("inventory");field.setAccessible(true);field.set(player,inventory);
    var rows=new JsonArray();
    for(var enchantment:enchantments.entrySet())for(int level:new int[]{0,1,255})for(boolean stored:new boolean[]{false,true})for(int slot:new int[]{0,36}){
      var stack=new ItemStack(Items.STONE);var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{buf.writeVarInt(1);buf.writeVarInt(enchantments.getId(enchantment.getValue()));buf.writeVarInt(level);stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,ItemEnchantments.STREAM_CODEC.decode(buf));}finally{buf.release();}
      inventory.setItem(slot,stack);player.vanish();var c=new JsonObject();c.addProperty("name",enchantment.getKey().identifier().toString());c.addProperty("level",level);c.addProperty("stored",stored);c.addProperty("slot",slot);c.addProperty("vanished",inventory.getItem(slot).isEmpty());rows.add(c);inventory.removeItemNoUpdate(slot);
    }
    var ownSlots=new LinkedHashMap<Integer,Integer>();for(int i=0;i<36;i++)ownSlots.put(i,i<9?i+36:i);
    for(var e:Inventory.EQUIPMENT_SLOT_MAPPING.int2ObjectEntrySet()){
      var menu=switch(e.getValue()){case OFFHAND->45;case FEET->8;case LEGS->7;case CHEST->6;case HEAD->5;default->-1;};
      if(menu>=0)ownSlots.put(e.getIntKey(),menu);
    }
    for(var e:ownSlots.entrySet()){var stack=new ItemStack(Items.STONE);var tag=new CompoundTag();tag.putInt("slot",e.getValue());stack.set(DataComponents.CUSTOM_DATA,CustomData.of(tag));inventory.setItem(e.getKey(),stack);}
    inventory.dropAll();if(!inventory.isEmpty())throw new AssertionError("Death inventory not cleared");
    var result=new JsonObject();result.add("vanishing",rows);result.add("drop_order",new Gson().toJsonTree(player.dropped));
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));System.out.println("PASS: "+rows.size()+" native enchantment/drop decisions and "+player.dropped.size()+" inventory/equipment drops.");
  }
}
