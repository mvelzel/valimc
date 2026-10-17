import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.world.SimpleContainer;
import net.minecraft.world.entity.EntityEquipment;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.ItemStack;

/** Original native generic-container click observations; persistence/owners/world admission excluded. */
public class ChestClickOracle {
  static sun.misc.Unsafe unsafe;
  static ItemStack value(int profile) {
    if(profile==0)return ItemStack.EMPTY;
    var stack=TableMenuOracle.item(profile==4?"egg":profile==5?"diamond_sword":profile==6?"dirt":"stone",profile==1?17:profile==2?63:profile==4?15:profile==5?1:profile==7?99:64);
    if(profile==3)stack.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
    if(profile==5)stack.set(DataComponents.DAMAGE,7);
    if(profile==7)stack.set(DataComponents.MAX_STACK_SIZE,99);
    return stack;
  }
  static JsonElement encoded(ItemStack value) {
    var row=TableMenuOracle.stack(value);if(!value.isEmpty())row.getAsJsonArray().add(value.getMaxStackSize());return row;
  }
  static JsonArray physical(Inventory inventory) {
    var result=new JsonArray();
    for(int slot=0;slot<46;slot++) {
      int index=slot>=36&&slot<=44?slot-36:slot>=9&&slot<=35?slot:slot==45?40:slot>=5&&slot<=8?44-slot:-1;
      result.add(index<0?JsonNull.INSTANCE:encoded(inventory.getItem(index)));
    }
    return result;
  }
  static JsonArray storage(SimpleContainer storage) {
    var rows=new JsonArray();for(int i=0;i<storage.getContainerSize();i++)rows.add(encoded(storage.getItem(i)));return rows;
  }
  static void observe(JsonArray cases,int rows,boolean creative,int layout,int profile,int cursor,int slot,int action,int button)throws Exception {
    var world=(PlayerCraftingOracle.MenuWorld)unsafe.allocateInstance(PlayerCraftingOracle.MenuWorld.class);
    var owner=(PlayerCraftingOracle.MenuPlayer)unsafe.allocateInstance(PlayerCraftingOracle.MenuPlayer.class);owner.world=world;owner.dropped=new ArrayList<>();
    var abilities=new Abilities();abilities.instabuild=creative;
    var field=Player.class.getDeclaredField("abilities");field.setAccessible(true);field.set(owner,abilities);
    var inventory=new Inventory(owner,new EntityEquipment());field=Player.class.getDeclaredField("inventory");field.setAccessible(true);field.set(owner,inventory);
    var storage=new SimpleContainer(rows*9);
    var type=List.of(MenuType.GENERIC_9x1,MenuType.GENERIC_9x2,MenuType.GENERIC_9x3,MenuType.GENERIC_9x4,MenuType.GENERIC_9x5,MenuType.GENERIC_9x6).get(rows-1);
    var menu=new ChestMenu(type,17,inventory,storage,rows);
    if(layout>0)for(int i=0;i<menu.slots.size();i++)menu.getSlot(i).set(TableMenuOracle.item("bedrock",64));
    if(layout==2)for(int i:new int[]{0,rows*9-1,rows*9,rows*9+26,rows*9+27,rows*9+35})menu.getSlot(i).set(value(2));
    if(layout==3)for(int i:new int[]{0,rows*9-1,rows*9,rows*9+26,rows*9+27,rows*9+35})menu.getSlot(i).set(ItemStack.EMPTY);
    inventory.setItem(40,value(4));inventory.setItem(39,TableMenuOracle.item("diamond_helmet",1));
    menu.getSlot(slot).set(value(profile));menu.setCarried(value(cursor));
    var before=storage(storage);var player=physical(inventory);var carried=encoded(menu.getCarried());
    menu.clicked(slot,button,ContainerInput.values()[action],owner);
    if(!owner.dropped.isEmpty())throw new AssertionError("Unexpected native drop in drop-free plan");
    var row=new JsonObject();row.addProperty("rows",rows);row.addProperty("creative",creative);row.addProperty("layout",layout);row.addProperty("slot",slot);row.addProperty("action",action);row.addProperty("button",button);row.add("before",before);row.add("player",player);row.add("cursor",carried);row.add("after",storage(storage));row.add("player_after",physical(inventory));row.add("cursor_after",encoded(menu.getCarried()));cases.add(row);
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);unsafe=(sun.misc.Unsafe)field.get(null);
    var cases=new JsonArray();
    for(int rows:new int[]{1,3,6})for(boolean creative:new boolean[]{false,true})for(int layout=0;layout<4;layout++)for(int slot:new int[]{0,rows*9-1,rows*9,rows*9+26,rows*9+27,rows*9+35}) {
      for(int profile=0;profile<=7;profile++) {
        for(int cursor:new int[]{0,1,2,3,4,5,6,7})for(int button:new int[]{0,1})observe(cases,rows,creative,layout,profile,cursor,slot,ContainerInput.PICKUP.ordinal(),button);
        observe(cases,rows,creative,layout,profile,0,slot,ContainerInput.QUICK_MOVE.ordinal(),0);
        for(int button:new int[]{0,8,40})observe(cases,rows,creative,layout,profile,0,slot,ContainerInput.SWAP.ordinal(),button);
      }
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+cases.size()+" actual native pickup/shift/number/offhand container clicks; rows1/3/6, permissions, capacities, patches, packed/merge/empty boundaries. No persistence/world claim.");
  }
}
