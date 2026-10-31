import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.HashedStack;
import it.unimi.dsi.fastutil.ints.Int2ObjectOpenHashMap;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.game.ClientboundOpenScreenPacket;
import net.minecraft.network.protocol.game.ClientboundContainerSetContentPacket;
import net.minecraft.network.protocol.game.ServerboundContainerClickPacket;
import net.minecraft.network.protocol.game.ClientboundSetPlayerInventoryPacket;
import net.minecraft.world.SimpleContainer;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.entity.ContainerUser;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.ItemStack;
import io.netty.buffer.Unpooled;

/** Original native chest layout/open-codec/empty-cursor close facts; shared storage and clicks excluded. */
public class ChestMenuOracle {
  static class Storage extends SimpleContainer {
    int opens,closes;
    Storage(int size){super(size);}
    @Override public void startOpen(ContainerUser player){opens++;}
    @Override public void stopOpen(ContainerUser player){closes++;}
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var types=List.of(MenuType.GENERIC_9x1,MenuType.GENERIC_9x2,MenuType.GENERIC_9x3,MenuType.GENERIC_9x4,MenuType.GENERIC_9x5,MenuType.GENERIC_9x6);
    var cases=new JsonArray();
    for(int rows=1;rows<=6;rows++){
      var owner=(TableMenuOracle.Owner)u.allocateInstance(TableMenuOracle.Owner.class);
      owner.abilities=new Abilities();owner.drops=new ArrayList<>();
      var inventory=new TableMenuOracle.Owned(owner);owner.inventory=inventory;
      for(int i=0;i<36;i++)inventory.setItem(i,TableMenuOracle.item("oak_planks",i+1));
      var storage=new Storage(rows*9);
      for(int i=0;i<storage.getContainerSize();i++)storage.setItem(i,TableMenuOracle.item("stone",i+1));
      var menu=new ChestMenu(types.get(rows-1),17,inventory,storage,rows);
      var row=new JsonObject();row.addProperty("rows",rows);row.addProperty("type",BuiltInRegistries.MENU.getId(menu.getType()));
      var slots=new JsonArray();var contents=new JsonArray();var stored=new JsonArray();
      for(int i=0;i<menu.slots.size();i++){
        var slot=menu.getSlot(i);var address=new JsonArray();address.add(slot.container==storage?"container":"player");
        int index=slot.getContainerSlot();address.add(slot.container==storage||index>=9?index:36+index);slots.add(address);
        contents.add(TableMenuOracle.stack(slot.getItem()));
      }
      for(int i=0;i<storage.getContainerSize();i++)stored.add(TableMenuOracle.stack(storage.getItem(i)));
      row.add("slots",slots);row.add("contents",contents);row.add("storage",stored);row.add("player",TableMenuOracle.physical(inventory));
      var title=rows==6?"container.chestDouble":"container.chest";
      var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{
        ClientboundOpenScreenPacket.STREAM_CODEC.encode(buffer,new ClientboundOpenScreenPacket(17,menu.getType(),Component.translatable(title)));
        var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);row.addProperty("open_hex",HexFormat.of().formatHex(bytes));
        var decoded=ClientboundOpenScreenPacket.STREAM_CODEC.decode(buffer);
        if(buffer.isReadable()||decoded.getContainerId()!=17)throw new AssertionError("Invalid native open packet");
      }finally{buffer.release();}
      buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{
        int hotbar=rows*9+27;
        var predictions=new Int2ObjectOpenHashMap<HashedStack>();predictions.put(hotbar,HashedStack.EMPTY);
        var cursor=HashedStack.create(menu.getSlot(hotbar).getItem(),component->0x12345678);
        ServerboundContainerClickPacket.STREAM_CODEC.encode(buffer,new ServerboundContainerClickPacket(17,0,(short)hotbar,(byte)0,ContainerInput.PICKUP,predictions,cursor));
        var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);row.addProperty("pickup_hex",HexFormat.of().formatHex(bytes));
      }finally{buffer.release();}
      buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{
        ClientboundContainerSetContentPacket.STREAM_CODEC.encode(buffer,new ClientboundContainerSetContentPacket(17,0,menu.getItems(),ItemStack.EMPTY));
        var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);row.addProperty("content_hex",HexFormat.of().formatHex(bytes));
        var decoded=ClientboundContainerSetContentPacket.STREAM_CODEC.decode(buffer);
        if(buffer.isReadable()||decoded.containerId()!=17||decoded.items().size()!=rows*9+36)throw new AssertionError("Invalid native content packet");
      }finally{buffer.release();}
      menu.removed(owner);row.addProperty("opens",storage.opens);row.addProperty("closes",storage.closes);
      if(storage.opens!=1||storage.closes!=1)throw new AssertionError("Unbalanced native view lifecycle");
      var after=new JsonArray();for(int i=0;i<storage.getContainerSize();i++)after.add(TableMenuOracle.stack(storage.getItem(i)));
      if(!after.equals(stored)||!owner.drops.isEmpty())throw new AssertionError("Closing chest moved storage");
      row.add("after_close",after);cases.add(row);
    }
    // A barrel's own menu (`BarrelBlockEntity.createMenu`) and its default name. Removed first, so
    // opening counts no viewer (the barrel's level and sounds are ChestSoundOracle's).
    var barrels=new JsonArray();
    for(var state:List.of(net.minecraft.world.level.block.Blocks.BARREL.defaultBlockState())){
      var owner=(TableMenuOracle.Owner)u.allocateInstance(TableMenuOracle.Owner.class);
      owner.abilities=new Abilities();owner.drops=new ArrayList<>();
      var inventory=new TableMenuOracle.Owned(owner);owner.inventory=inventory;
      var barrel=new net.minecraft.world.level.block.entity.BarrelBlockEntity(net.minecraft.core.BlockPos.ZERO,state);barrel.setRemoved();
      var create=net.minecraft.world.level.block.entity.BarrelBlockEntity.class.getDeclaredMethod("createMenu",int.class,Inventory.class);create.setAccessible(true);
      var menu=(AbstractContainerMenu)create.invoke(barrel,17,inventory);
      var row=new JsonObject();row.addProperty("type",BuiltInRegistries.MENU.getId(menu.getType()));row.addProperty("size",barrel.getContainerSize());
      row.addProperty("chest_menu",menu instanceof ChestMenu chest&&chest.getContainer()==barrel&&chest.getRowCount()==3);
      var slots=new JsonArray();
      for(int i=0;i<menu.slots.size();i++){
        var slot=menu.getSlot(i);var address=new JsonArray();address.add(slot.container==barrel?"container":"player");
        int index=slot.getContainerSlot();address.add(slot.container==barrel||index>=9?index:36+index);slots.add(address);
      }
      row.add("slots",slots);
      var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{
        ClientboundOpenScreenPacket.STREAM_CODEC.encode(buffer,new ClientboundOpenScreenPacket(17,menu.getType(),barrel.getDisplayName()));
        var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);row.addProperty("open_hex",HexFormat.of().formatHex(bytes));
      }finally{buffer.release();}
      barrels.add(row);
    }
    var corrections=new JsonArray();
    for(var stack:List.of(ItemStack.EMPTY,TableMenuOracle.item("oak_planks",7))){
      var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{
        ClientboundSetPlayerInventoryPacket.STREAM_CODEC.encode(buffer,new ClientboundSetPlayerInventoryPacket(Inventory.SLOT_OFFHAND,stack));
        var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);
        var row=new JsonObject();row.addProperty("slot",Inventory.SLOT_OFFHAND);row.add("stack",TableMenuOracle.stack(stack));
        row.addProperty("hex",HexFormat.of().formatHex(bytes));corrections.add(row);
      }finally{buffer.release();}
    }
    var out=new JsonObject();out.add("offhand_corrections",corrections);out.addProperty("version","26.3");out.addProperty("protocol",777);
    out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);out.add("barrels",barrels);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: six native chest layouts/open/content bodies/hotbar pickup input codecs and empty-cursor close retaining storage; gameplay clicks/world/ownership/persistence excluded.");
  }
}
