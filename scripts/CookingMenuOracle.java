import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.game.*;
import net.minecraft.resources.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.crafting.*;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;

/** Original native furnace-family layouts, data ordering and packet bodies; no live clicks or XP claim. */
public class CookingMenuOracle {
  static class World extends ServerLevel {
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    RecipeManager recipes;
    public RecipeManager recipeAccess(){return recipes;}
  }
  static java.lang.reflect.Field field(String name)throws Exception {
    var field=AbstractFurnaceBlockEntity.class.getDeclaredField(name);field.setAccessible(true);return field;
  }
  interface Encoder {void encode(RegistryFriendlyByteBuf buffer);}
  static String hex(RegistryAccess access,Encoder encoder){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{encoder.encode(buffer);var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}
  }
  public static void main(String[] args)throws Exception {
    var registry=MiningToolOracle.initialize();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    net.minecraft.core.HolderLookup.Provider lookup;
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var loaded=RegistryDataLoader.load(resources,registry.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var keys=loaded.listRegistryKeys().collect(Collectors.toSet());lookup=HolderLookup.Provider.create(Stream.concat(registry.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
    }
    var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);var cases=new JsonArray();var progress=new JsonArray();
    for(int kind=0;kind<3;kind++) {
      var owner=(TableMenuOracle.Owner)unsafe.allocateInstance(TableMenuOracle.Owner.class);var world=(World)unsafe.allocateInstance(World.class);world.recipes=new RecipeManager(lookup);var level=net.minecraft.world.entity.Entity.class.getDeclaredField("level");level.setAccessible(true);level.set(owner,world);owner.abilities=new Abilities();owner.drops=new ArrayList<>();
      var inventory=new TableMenuOracle.Owned(owner);owner.inventory=inventory;
      for(int i=0;i<36;i++)inventory.setItem(i,TableMenuOracle.item("oak_planks",i+1));
      var block=kind==0?Blocks.FURNACE:kind==1?Blocks.SMOKER:Blocks.BLAST_FURNACE;var state=block.defaultBlockState();
      AbstractFurnaceBlockEntity storage=kind==0?new FurnaceBlockEntity(BlockPos.ZERO,state):kind==1?new SmokerBlockEntity(BlockPos.ZERO,state):new BlastFurnaceBlockEntity(BlockPos.ZERO,state);
      storage.setItem(0,TableMenuOracle.item(kind==1?"cod":"raw_iron",3));storage.setItem(1,TableMenuOracle.item("coal",7));storage.setItem(2,TableMenuOracle.item(kind==1?"cooked_cod":"iron_ingot",11));
      var data=(ContainerData)field("dataAccess").get(storage);
      AbstractFurnaceMenu menu=kind==0?new FurnaceMenu(17,inventory,storage,data):kind==1?new SmokerMenu(17,inventory,storage,data):new BlastFurnaceMenu(17,inventory,storage,data);
      var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("type",BuiltInRegistries.MENU.getId(menu.getType()));
      var slots=new JsonArray();var contents=new JsonArray();var stored=new JsonArray();
      for(int i=0;i<menu.slots.size();i++) {
        var slot=menu.getSlot(i);var address=new JsonArray();address.add(slot.container==storage?"cooking":"player");
        int index=slot.getContainerSlot();address.add(slot.container==storage||index>=9?index:36+index);slots.add(address);contents.add(TableMenuOracle.stack(slot.getItem()));
      }
      for(int i=0;i<3;i++)stored.add(TableMenuOracle.stack(storage.getItem(i)));
      row.add("slots",slots);row.add("contents",contents);row.add("storage",stored);row.add("player",TableMenuOracle.physical(inventory));
      String title=kind==0?"container.furnace":kind==1?"container.smoker":"container.blast_furnace";
      row.addProperty("open_hex",hex(access,b->ClientboundOpenScreenPacket.STREAM_CODEC.encode(b,new ClientboundOpenScreenPacket(17,menu.getType(),Component.translatable(title)))));
      row.addProperty("content_hex",hex(access,b->ClientboundContainerSetContentPacket.STREAM_CODEC.encode(b,new ClientboundContainerSetContentPacket(17,0,menu.getItems(),net.minecraft.world.item.ItemStack.EMPTY))));
      for(int left:new int[]{0,1,67,1600,20000})for(int total:new int[]{0,100,200})for(int timer:new int[]{0,1,99,200}) {
        int burnTotal=left==20000?20000:1600;
        field("litTimeRemaining").setInt(storage,left);field("litTotalTime").setInt(storage,burnTotal);field("cookingTimer").setInt(storage,timer);field("cookingTotalTime").setInt(storage,total);
        var observation=new JsonObject();observation.addProperty("kind",kind);observation.addProperty("burn_left",left);observation.addProperty("burn_total",burnTotal);observation.addProperty("progress",timer);observation.addProperty("total",total);
        var values=new JsonArray();var packets=new JsonArray();for(int i=0;i<data.getCount();i++) {
          int id=i,value=data.get(i);values.add(value);packets.add(hex(access,b->ClientboundContainerSetDataPacket.STREAM_CODEC.encode(b,new ClientboundContainerSetDataPacket(17,id,value))));
        }
        observation.add("data",values);observation.add("data_hex",packets);progress.add(observation);
      }
      menu.removed(owner);var after=new JsonArray();for(int i=0;i<3;i++)after.add(TableMenuOracle.stack(storage.getItem(i)));
      if(!after.equals(stored)||!owner.drops.isEmpty())throw new AssertionError("Closing processor changed storage");row.add("after_close",after);cases.add(row);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);out.add("progress",progress);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS:3 native cooking menu layouts/open/content bodies and "+progress.size()+" actual block-entity progress observations; clicks/XP excluded.");
  }
}
