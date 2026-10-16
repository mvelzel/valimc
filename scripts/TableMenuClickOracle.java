/** Original actual table click/result observations; world construction/stats/network are controlled. */
import com.google.gson.*;
import java.util.*;
import java.util.stream.*;
import java.nio.file.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.*;
import net.minecraft.server.packs.resources.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;

public class TableMenuClickOracle extends PlayerCraftingOracle {
  static class Table extends CraftingMenu {
    RecipeManager recipes;
    MenuWorld world;
    Table(Inventory inventory,MenuPlayer owner) { super(17,inventory);recipes=owner.world.recipes;world=owner.world; }
    public void slotsChanged(net.minecraft.world.Container container) {
      if(recipes==null)return;
      var input=craftSlots.asPositionedCraftInput().input();
      var recipe=recipes.getRecipeFor(RecipeType.CRAFTING,input,world);
      resultSlots.setItem(0,recipe.map(r->r.value().assemble(input)).orElse(ItemStack.EMPTY));
    }
  }
  static JsonElement encoded(ItemStack value) { return TableMenuOracle.stack(value); }
  static void observe(RecipeManager recipes,JsonArray cases,boolean creative,Map<Integer,ItemStack> slots,Map<Integer,ItemStack> hidden,ItemStack cursor,int[][] actions)throws Exception {
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)field.get(null);
    var world=(MenuWorld)unsafe.allocateInstance(MenuWorld.class);world.recipes=recipes;
    var owner=(MenuPlayer)unsafe.allocateInstance(MenuPlayer.class);owner.world=world;owner.dropped=new ArrayList<>();
    var abilities=new Abilities();abilities.instabuild=creative;
    field=Player.class.getDeclaredField("abilities");field.setAccessible(true);field.set(owner,abilities);
    var inventory=new Inventory(owner,new net.minecraft.world.entity.EntityEquipment());
    field=Player.class.getDeclaredField("inventory");field.setAccessible(true);field.set(owner,inventory);
    for(var entry:hidden.entrySet())inventory.setItem(entry.getKey(),entry.getValue().copy());
    var menu=new Table(inventory,owner);var grid=new JsonArray();
    for(int slot=1;slot<46;slot++){var value=slots.getOrDefault(slot,ItemStack.EMPTY);menu.getSlot(slot).set(value.copy());if(slot<=9)grid.add(encoded(value));}
    menu.setCarried(cursor.copy());
    var before=TableMenuOracle.physical(inventory);var actionRows=new JsonArray();
    for(var action:actions){menu.clicked(action[1],action[2],ContainerInput.values()[action[0]],owner);actionRows.add(new Gson().toJsonTree(action));}
    var visible=new JsonArray();for(int slot=0;slot<46;slot++)visible.add(encoded(menu.getSlot(slot).getItem()));
    var row=new JsonArray();row.add(creative);row.add(before);row.add(grid);row.add(encoded(cursor));row.add(actionRows);row.add(visible);row.add(TableMenuOracle.physical(inventory));row.add(encoded(menu.getCarried()));
    var drops=new JsonArray();for(var value:owner.dropped)drops.add(encoded(value));row.add(drops);cases.add(row);
  }
  static Map<Integer,ItemStack> grid(JsonObject profile) {
    var result=new HashMap<Integer,ItemStack>();int width=profile.get("width").getAsInt();var ingredients=profile.getAsJsonArray("ingredients");
    for(int i=0;i<ingredients.size();i++)if(!ingredients.get(i).isJsonNull()) {
      int id=ingredients.get(i).getAsJsonArray().get(0).getAsInt();var input=new ItemStack(BuiltInRegistries.ITEM.byId(id));input.setCount(Math.min(2,input.getMaxStackSize()));
      result.put((width==0?i:i/width*3+i%width)+1,input);
    }
    return result;
  }
  static int[] action(ContainerInput action,int slot,int button){return new int[]{action.ordinal(),slot,button};}
  static void verify(String path)throws Exception {
    var facts=JsonParser.parseString(Files.readString(Path.of(path))).getAsJsonObject();
    var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var open=new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.buffer(),access);
    net.minecraft.network.protocol.game.ClientboundOpenScreenPacket.STREAM_CODEC.encode(open,new net.minecraft.network.protocol.game.ClientboundOpenScreenPacket(17,MenuType.CRAFTING,net.minecraft.network.chat.Component.translatable("container.crafting")));
    if(!io.netty.buffer.ByteBufUtil.hexDump(open).equals(facts.get("open").getAsString()))throw new AssertionError("Native open payload differs");
    var packets=facts.getAsJsonArray("packets");
    if(packets.size()!=2398)throw new AssertionError("Incomplete table packet coverage");
    for(var entry:packets) {
      var row=entry.getAsJsonArray();var bytes=HexFormat.of().parseHex(row.get(2).getAsString());
      var buffer=new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.wrappedBuffer(bytes),access);
      var packet=net.minecraft.network.protocol.game.ClientboundContainerSetContentPacket.STREAM_CODEC.decode(buffer);
      if(buffer.isReadable()||packet.containerId()!=row.get(0).getAsInt()||packet.stateId()!=row.get(1).getAsInt()||packet.items().size()!=46)throw new AssertionError("Wrong native table container/header");
      var expected=row.get(3).getAsJsonArray();for(int i=0;i<46;i++)if(!encoded(packet.items().get(i)).equals(expected.get(i)))throw new AssertionError("Native table slot decode differs "+i);
      if(!encoded(packet.carriedItem()).equals(row.get(4)))throw new AssertionError("Native table cursor decode differs");
    }
    System.out.println("PASS:2398 table content packets decoded by actual26.3 codec; native open payload identical, container IDs1..127, visible inputs/result/storage/cursor exact.");
  }
  public static void main(String[] args)throws Exception {
    var initial=MiningToolOracle.initialize();
    if(args[0].equals("verify")){verify(args[1]);return;}
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      var pending=net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,access);
      var statics=net.minecraft.tags.TagLoader.buildUpdatedLookups(access,pending);var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));for(var tags:pending)tags.apply();
      var manager=new RecipeManager(lookup);var cases=new JsonArray();
      var profiles=JsonParser.parseString(Files.readString(Path.of("priv/crafting/recipes.json"))).getAsJsonObject().getAsJsonArray("recipes");
      for(var entry:profiles)for(boolean creative:new boolean[]{false,true}) {
        var slots=grid(entry.getAsJsonObject());
        for(var action:List.of(ContainerInput.PICKUP,ContainerInput.QUICK_MOVE,ContainerInput.SWAP,ContainerInput.CLONE,ContainerInput.THROW))
          observe(manager,cases,creative,slots,Map.of(),ItemStack.EMPTY,new int[][]{action(action,0,0)});
      }
      for(boolean creative:new boolean[]{false,true})for(int layout=0;layout<8;layout++)for(int button:new int[]{0,1}) {
        var slots=new HashMap<Integer,ItemStack>();slots.put(1,stack("oak_log",17));
        if(layout>0)for(int slot=10;slot<46;slot++)slots.put(slot,stack("bedrock",64));
        if(layout==1)slots.remove(45);
        if(layout==2)slots.put(45,stack("oak_planks",60));
        if(layout==3)slots.put(45,stack("oak_planks",62));
        if(layout==4)slots.put(45,stack("oak_planks",63));
        if(layout==5)slots.put(37,stack("oak_planks",60));
        if(layout==6)slots.put(37,stack("oak_planks",62));
        if(layout==7)slots.put(37,stack("oak_planks",1));
        observe(manager,cases,creative,slots,Map.of(),ItemStack.EMPTY,new int[][]{action(ContainerInput.QUICK_MOVE,0,button)});
        for(int target:new int[]{0,8,40})observe(manager,cases,creative,slots,Map.of(),ItemStack.EMPTY,new int[][]{action(ContainerInput.SWAP,0,target)});
      }
      var pickaxe=Map.of(1,stack("oak_planks",2),2,stack("spruce_planks",2),3,stack("birch_planks",2),5,stack("stick",2),8,stack("stick",2));
      for(boolean creative:new boolean[]{false,true})for(int button:new int[]{0,1}) {
        for(var cursor:List.of(ItemStack.EMPTY,stack("wooden_pickaxe",1),stack("bedrock",1)))observe(manager,cases,creative,pickaxe,Map.of(),cursor,new int[][]{action(ContainerInput.PICKUP,0,button)});
        observe(manager,cases,creative,pickaxe,Map.of(),ItemStack.EMPTY,new int[][]{action(ContainerInput.PICKUP,0,button),action(ContainerInput.PICKUP,0,button)});
        observe(manager,cases,creative,pickaxe,Map.of(),stack("oak_planks",1),new int[][]{action(ContainerInput.THROW,0,0)});
        var hidden=Map.of(39,stack("iron_helmet",1),40,stack("oak_planks",5));
        observe(manager,cases,creative,Map.of(10,stack("iron_helmet",1)),hidden,ItemStack.EMPTY,new int[][]{action(ContainerInput.QUICK_MOVE,10,button)});
        observe(manager,cases,creative,Map.of(37,stack("iron_helmet",1)),Map.of(),ItemStack.EMPTY,new int[][]{action(ContainerInput.QUICK_MOVE,37,button)});
        observe(manager,cases,creative,Map.of(1,stack("oak_planks",3),9,stack("oak_planks",4),10,stack("oak_planks",5),45,stack("oak_planks",6)),hidden,stack("oak_planks",2),new int[][]{action(ContainerInput.PICKUP_ALL,5,button)});
        observe(manager,cases,creative,Map.of(37,stack("oak_log",2)),hidden,ItemStack.EMPTY,new int[][]{action(ContainerInput.PICKUP,37,0),action(ContainerInput.PICKUP,9,1),action(ContainerInput.SWAP,8,40),action(ContainerInput.THROW,9,button)});
        observe(manager,cases,creative,Map.of(),Map.of(),stack("oak_planks",17),new int[][]{action(ContainerInput.QUICK_CRAFT,-999,button*4),action(ContainerInput.QUICK_CRAFT,1,button*4+1),action(ContainerInput.QUICK_CRAFT,5,button*4+1),action(ContainerInput.QUICK_CRAFT,9,button*4+1),action(ContainerInput.QUICK_CRAFT,-999,button*4+2)});
      }
      for(boolean creative:new boolean[]{false,true})for(int source:new int[]{10,37})for(int layout=0;layout<5;layout++) {
        var slots=new HashMap<Integer,ItemStack>();for(int slot=1;slot<46;slot++)slots.put(slot,stack("bedrock",64));
        slots.put(source,stack("oak_planks",layout==1?64:4));int other=source==10?37:10;
        if(layout==0){slots.put(9,stack("oak_planks",63));slots.put(other,stack("oak_planks",60));}
        if(layout==1){slots.put(1,stack("oak_planks",63));slots.remove(9);slots.put(other,stack("oak_planks",63));}
        if(layout==2)slots.put(other,stack("oak_planks",63));
        if(layout==3){var patched=stack("oak_planks",60);patched.set(net.minecraft.core.component.DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);slots.put(other,patched);}
        if(layout==4){slots.put(source,stack("iron_helmet",1));slots.remove(5);}
        observe(manager,cases,creative,slots,Map.of(),ItemStack.EMPTY,new int[][]{action(ContainerInput.QUICK_MOVE,source,0)});
      }
      for(boolean creative:new boolean[]{false,true})observe(manager,cases,creative,Map.of(),Map.of(),stack("oak_planks",17),new int[][]{action(ContainerInput.QUICK_CRAFT,-999,8),action(ContainerInput.QUICK_CRAFT,1,9),action(ContainerInput.QUICK_CRAFT,9,9),action(ContainerInput.QUICK_CRAFT,-999,10)});
      Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
      System.out.println("PASS:"+cases.size()+" actual CraftingMenu/ResultSlot click traces across1180 ordinary profiles, both permissions, result gestures, cursor/storage boundaries and hidden equipment.");
    }
  }
}
