import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.tags.TagLoader;
import net.minecraft.world.SimpleContainer;
import net.minecraft.world.entity.EntityEquipment;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;

/** Original actual cooking-menu item clicks. Simple storage excludes block-entity hooks and XP. */
public class CookingClickOracle {
  static sun.misc.Unsafe unsafe; static RecipeManager manager;
  static ItemStack value(int profile) {
    if(profile==0)return ItemStack.EMPTY;
    var names=new String[]{"", "coal", "raw_iron", "cod", "stone", "bucket", "lava_bucket", "oak_log", "iron_ingot", "coal", "diamond_sword", "coal", "coal"};
    var stack=TableMenuOracle.item(names[profile],profile==4||profile==8?63:profile==5?15:profile==6||profile==10?1:profile==11?99:17);
    if(profile==9)stack.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
    if(profile==10)stack.set(DataComponents.DAMAGE,7);
    if(profile==11)stack.set(DataComponents.MAX_STACK_SIZE,99);
    if(profile==12)stack.remove(DataComponents.COOKING_FUEL);
    return stack;
  }
  static JsonElement encoded(ItemStack value){
    var row=ChestClickOracle.encoded(value);if(!value.isEmpty()){row.getAsJsonArray().add(value.getComponentsPatch().split().removed().contains(DataComponents.COOKING_FUEL));}return row;
  }
  static JsonArray stored(SimpleContainer storage){var row=new JsonArray();for(int i=0;i<3;i++)row.add(encoded(storage.getItem(i)));return row;}
  static JsonArray physical(Inventory inventory){
    var result=new JsonArray();for(int slot=0;slot<46;slot++){int index=slot>=36&&slot<=44?slot-36:slot>=9&&slot<=35?slot:slot==45?40:slot>=5&&slot<=8?44-slot:-1;result.add(index<0?JsonNull.INSTANCE:encoded(inventory.getItem(index)));}return result;
  }
  static void observe(JsonArray cases,int kind,boolean creative,int layout,int profile,int cursor,int slot,int action,int button,ItemStack routed)throws Exception {
    var world=(PlayerCraftingOracle.MenuWorld)unsafe.allocateInstance(PlayerCraftingOracle.MenuWorld.class);world.recipes=manager;
    var owner=(PlayerCraftingOracle.MenuPlayer)unsafe.allocateInstance(PlayerCraftingOracle.MenuPlayer.class);owner.world=world;owner.dropped=new ArrayList<>();
    var abilities=new Abilities();abilities.instabuild=creative;var field=Player.class.getDeclaredField("abilities");field.setAccessible(true);field.set(owner,abilities);
    var inventory=new Inventory(owner,new EntityEquipment());field=Player.class.getDeclaredField("inventory");field.setAccessible(true);field.set(owner,inventory);
    var storage=new SimpleContainer(3);var data=new SimpleContainerData(4);
    AbstractFurnaceMenu menu=kind==0?new FurnaceMenu(17,inventory,storage,data):kind==1?new SmokerMenu(17,inventory,storage,data):new BlastFurnaceMenu(17,inventory,storage,data);
    if(layout>0)for(var cell:menu.slots)cell.set(TableMenuOracle.item("bedrock",64));
    if(layout==2)for(int i:new int[]{0,1,2,3,29,30,38})menu.getSlot(i).set(value(1));
    inventory.setItem(40,value(5));inventory.setItem(39,TableMenuOracle.item("diamond_helmet",1));
    menu.getSlot(slot).set(routed==null?value(profile):routed.copy());menu.setCarried(value(cursor));
    var before=stored(storage);var player=physical(inventory);var carried=encoded(menu.getCarried());
    boolean overflow=false;
    if(action==ContainerInput.SWAP.ordinal()) {
      var incoming=inventory.getItem(button==40?40:button);var outgoing=menu.getSlot(slot).getItem();
      overflow=(!incoming.isEmpty() && menu.getSlot(slot).mayPlace(incoming) && incoming.getCount()>menu.getSlot(slot).getMaxStackSize(incoming))||(!outgoing.isEmpty() && outgoing.getCount()>outgoing.getMaxStackSize());
    }
    menu.clicked(slot,button,ContainerInput.values()[action],owner);
    var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("creative",creative);row.addProperty("layout",layout);row.addProperty("slot",slot);row.addProperty("action",action);row.addProperty("button",button);row.addProperty("overflow",overflow);
    row.add("before",before);row.add("player",player);row.add("cursor",carried);row.add("after",stored(storage));row.add("player_after",physical(inventory));row.add("cursor_after",encoded(menu.getCarried()));
    var drops=new JsonArray();for(var drop:owner.dropped)drops.add(encoded(drop));row.add("drops",drops);cases.add(row);
  }
  public static void main(String[] args)throws Exception {
    var initial=MiningToolOracle.initialize();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);unsafe=(sun.misc.Unsafe)f.get(null);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);var pending=TagLoader.loadTagsForExistingRegistries(resources,access);var statics=TagLoader.buildUpdatedLookups(access,pending);var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();var keys=loaded.listRegistryKeys().collect(Collectors.toSet());var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));for(var tags:pending)tags.apply();
      manager=new RecipeManager(lookup);manager.finalizeRecipeLoading(FeatureFlags.DEFAULT_FLAGS);
      var cases=new JsonArray();
      for(int kind=0;kind<3;kind++)for(boolean creative:new boolean[]{false,true})for(int layout=0;layout<3;layout++)for(int slot:new int[]{0,1,2,3,29,30,38})for(int profile=0;profile<13;profile++) {
        for(int cursor:new int[]{0,1,2,4,5,6,9,11,12})for(int button:new int[]{0,1})observe(cases,kind,creative,layout,profile,cursor,slot,ContainerInput.PICKUP.ordinal(),button,null);
        observe(cases,kind,creative,layout,profile,0,slot,ContainerInput.QUICK_MOVE.ordinal(),0,null);
        for(int button:new int[]{0,8,40})observe(cases,kind,creative,layout,profile,0,slot,ContainerInput.SWAP.ordinal(),button,null);
      }
      var routes=new JsonArray();for(int kind=0;kind<3;kind++)for(var item:BuiltInRegistries.ITEM)observe(routes,kind,false,0,0,0,3,ContainerInput.QUICK_MOVE.ordinal(),0,new ItemStack(item));
      var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);out.add("routes",routes);Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+cases.size()+" actual cooking clicks and "+routes.size()+" stock shift routes; block-entity/XP/persistence hooks excluded.");
    }
  }
}
