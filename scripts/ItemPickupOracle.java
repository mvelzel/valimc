import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.world.entity.EntityEquipment;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.item.*;

/** Actual Inventory.add callback and mutated remainder, independent of world contact/durability. */
public class ItemPickupOracle {
 static class Probe extends Player {
  boolean infinite;
  private Probe(){super(null,null);}
  public boolean hasInfiniteMaterials(){return infinite;}
  public net.minecraft.world.level.GameType gameMode(){return infinite?net.minecraft.world.level.GameType.CREATIVE:net.minecraft.world.level.GameType.SURVIVAL;}
 }
 static RegistryAccess.Frozen registries;
 static String stack(ItemStack s){
  var b=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
  try{ItemStack.OPTIONAL_STREAM_CODEC.encode(b,s);var bytes=new byte[b.readableBytes()];b.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{b.release();}
 }
 static JsonObject inventory(Inventory inv){
  var o=new JsonObject();for(int i=0;i<36;i++)if(!inv.getItem(i).isEmpty())o.addProperty(Integer.toString(i<9?36+i:i),stack(inv.getItem(i)));
  if(!inv.getItem(40).isEmpty())o.addProperty("45",stack(inv.getItem(40)));return o;
 }
 static ItemStack custom(int count){var s=new ItemStack(Items.STONE,count);s.set(DataComponents.MAX_STACK_SIZE,99);return s;}
 static void seed(Inventory inv,int layout,int selected){
  inv.setSelectedSlot(selected);
  if(layout>=1)for(int i=0;i<36;i++)inv.setItem(i,new ItemStack(layout==2?Items.COBBLESTONE:Items.STONE,64));
  if(layout==3){inv.setItem(selected,new ItemStack(Items.STONE,63));inv.setItem(40,new ItemStack(Items.STONE,60));}
  if(layout==4){inv.setItem(selected,new ItemStack(Items.STONE,60));inv.setItem(40,new ItemStack(Items.STONE,62));inv.setItem(0,new ItemStack(Items.STONE,63));inv.setItem(1,ItemStack.EMPTY);inv.setItem(9,ItemStack.EMPTY);}
  if(layout==5){for(int i=0;i<36;i++)inv.setItem(i,custom(99));inv.setItem(selected,custom(97));}
  if(layout==6){for(int i=0;i<36;i++)inv.setItem(i,ItemStack.EMPTY);var s=new ItemStack(Items.STONE,63);s.set(DataComponents.MAX_STACK_SIZE,64);inv.setItem(selected,s);}
  if(layout==7){inv.setItem(1,ItemStack.EMPTY);inv.setItem(9,ItemStack.EMPTY);}
 }
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
  var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);var player=(Probe)u.allocateInstance(Probe.class);
  var stacks=new ArrayList<ItemStack>();for(int count:new int[]{1,7,64})stacks.add(new ItemStack(Items.STONE,count));
  stacks.add(new ItemStack(Items.EGG,16));stacks.add(custom(99));stacks.add(ItemStack.EMPTY);
  var sword=new ItemStack(Items.DIAMOND_SWORD);sword.set(DataComponents.DAMAGE,12);stacks.add(sword);
  var named=new ItemStack(Items.STONE,4);named.set(DataComponents.CUSTOM_NAME,Component.literal("separate"));stacks.add(named);
  var cases=new JsonArray();
  for(int layout=0;layout<8;layout++)for(int selected:new int[]{0,2,8})for(boolean infinite:new boolean[]{false,true})for(var original:stacks){
   player.infinite=infinite;var inv=new Inventory(player,new EntityEquipment());seed(inv,layout,selected);var input=original.copy();var row=new JsonObject();row.addProperty("layout",layout);row.addProperty("selected",selected);row.addProperty("infinite",infinite);row.addProperty("stack",stack(input));row.add("before",inventory(inv));
   row.addProperty("callback",inv.add(input));row.add("after",inventory(inv));row.addProperty("remainder",stack(input));cases.add(row);
  }
  Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual Inventory.add insertion/remainder/callback observations; contact/source transfer excluded.");
 }
}
