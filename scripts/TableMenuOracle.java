/** Original native table layout/cleanup probe; requested drops are captured, not simulated. */
import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.network.*;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.game.ClientboundOpenScreenPacket;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.util.Prediction;
import net.minecraft.world.Container;
import net.minecraft.world.entity.EntityEquipment;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.level.GameType;
import io.netty.buffer.Unpooled;

public class TableMenuOracle {
  static class Owner extends ServerPlayer {
    boolean disconnected;
    Abilities abilities;
    Inventory inventory;
    List<ItemStack> drops;
    private Owner() { super(null,null,null,null); }
    public boolean hasDisconnected() { return disconnected; }
    public Abilities getAbilities() { return abilities; }
    public Inventory getInventory() { return inventory; }
    public GameType gameMode() { return abilities.instabuild?GameType.CREATIVE:GameType.SURVIVAL; }
    public ItemEntity drop(ItemStack stack,boolean random,Prediction prediction) {
      if(random||prediction!=Prediction.SERVER_ONLY)throw new AssertionError("Wrong cleanup effect");
      if(!stack.isEmpty())drops.add(stack.copy());
      return null;
    }
  }
  static class Owned extends Inventory {
    Owned(Owner owner) { super(owner,new EntityEquipment()); }
    public void placeItemBackInInventory(ItemStack stack,Prediction prediction) {
      super.placeItemBackInInventory(stack,false,prediction); // Suppress only outbound packets.
    }
  }
  static class Menu extends CraftingMenu {
    Menu(Inventory inventory) { super(17,inventory,ContainerLevelAccess.create(null,BlockPos.ZERO)); }
    public void slotsChanged(Container container) {} // Cleanup/layout only, no recipe claim.
  }
  static ItemStack item(String name,int count) {
    return new ItemStack(BuiltInRegistries.ITEM.getValue(net.minecraft.resources.Identifier.parse(name)),count);
  }
  static JsonElement stack(ItemStack stack) {
    if(stack.isEmpty())return JsonNull.INSTANCE;
    var row=new JsonArray();row.add(BuiltInRegistries.ITEM.getId(stack.getItem()));row.add(stack.getCount());
    var glint=stack.get(DataComponents.ENCHANTMENT_GLINT_OVERRIDE);
    row.add(glint==null?JsonNull.INSTANCE:new JsonPrimitive(glint));
    var damage=stack.get(DataComponents.DAMAGE);
    row.add(damage==null?JsonNull.INSTANCE:new JsonPrimitive(damage));
    return row;
  }
  static JsonArray physical(Inventory inventory) {
    var result=new JsonArray();
    for(int slot=0;slot<46;slot++) {
      int index=slot>=36&&slot<=44?slot-36:slot>=9&&slot<=35?slot:slot==45?40:slot>=5&&slot<=8?44-slot:-1;
      result.add(index<0?JsonNull.INSTANCE:stack(inventory.getItem(index)));
    }
    return result;
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)field.get(null);
    var cases=new JsonArray();var rows=new JsonArray();
    for(boolean creative:new boolean[]{false,true})for(boolean disconnected:new boolean[]{false,true})for(int layout=0;layout<6;layout++) {
      var owner=(Owner)unsafe.allocateInstance(Owner.class);
      owner.abilities=new Abilities();owner.abilities.instabuild=creative;owner.disconnected=disconnected;owner.drops=new ArrayList<>();
      var inventory=new Owned(owner);owner.inventory=inventory;inventory.setSelectedSlot(2);
      if(layout>0)for(int i=0;i<36;i++)inventory.setItem(i,item("bedrock",64));
      if(layout==2) { inventory.setItem(2,item("oak_planks",63));inventory.setItem(40,item("oak_planks",62)); }
      if(layout==3)for(int i:new int[]{0,8,9,35})inventory.setItem(i,ItemStack.EMPTY);
      if(layout==4) { inventory.setItem(2,item("egg",15));inventory.setItem(8,ItemStack.EMPTY); }
      if(layout==5) { var patched=item("oak_planks",60);patched.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);inventory.setItem(2,patched);inventory.setItem(40,item("oak_planks",64)); }
      var menu=new Menu(inventory);
      if(rows.isEmpty())for(int i=0;i<menu.slots.size();i++) {
        var slot=menu.getSlot(i);var row=new JsonArray();row.add(i);row.add(slot.getContainerSlot());row.add(slot.container==inventory?"inventory":i==0?"result":"crafting");rows.add(row);
      }
      var inputs=new ItemStack[]{item("oak_log",2),item("oak_planks",3),item("spruce_planks",4),item("egg",16),item("diamond",5),item("iron_sword",1),item("oak_planks",6),item("dirt",7),item("stone",8)};
      inputs[5].set(DataComponents.DAMAGE,17);inputs[6].set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
      var grid=new JsonArray();for(int i=0;i<9;i++){grid.add(stack(inputs[i]));menu.getSlot(i+1).set(inputs[i].copy());}
      var cursor=item("oak_planks",10);menu.setCarried(cursor.copy());menu.getSlot(0).set(item("diamond_block",64));
      var row=new JsonArray();row.add(creative);row.add(disconnected);row.add(layout);row.add(physical(inventory));row.add(grid);row.add(stack(cursor));
      menu.removed(owner);
      row.add(physical(inventory));row.add(stack(menu.getCarried()));var dropped=new JsonArray();for(var value:owner.drops)dropped.add(stack(value));row.add(dropped);
      for(int i=1;i<=9;i++)if(menu.getSlot(i).hasItem())throw new AssertionError("Retained native input");
      cases.add(row);
    }
    var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    ClientboundOpenScreenPacket.STREAM_CODEC.encode(buffer,new ClientboundOpenScreenPacket(17,MenuType.CRAFTING,Component.translatable("container.crafting")));
    byte[] bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);
    var packet=ClientboundOpenScreenPacket.STREAM_CODEC.decode(buffer);if(buffer.isReadable())throw new AssertionError("Trailing open bytes");
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("container_id",packet.getContainerId());facts.addProperty("menu_type",BuiltInRegistries.MENU.getId(MenuType.CRAFTING));facts.addProperty("packet_hex",HexFormat.of().formatHex(bytes));facts.add("slots",rows);facts.add("cleanup",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts));
    System.out.println("PASS:46 actual table slots/open codec and "+cases.size()+" actual CraftingMenu cleanup contexts; both permissions/disconnect states, nine inputs/cursor, exact order/patch/overflow.");
  }
}
