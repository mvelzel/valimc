import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
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
import net.minecraft.world.item.alchemy.*;
import net.minecraft.world.item.crafting.*;

/**
 * Original actual brewing-stand menu clicks (VMC-034o): pickups, shift-clicks
 * and number swaps over `BrewingStandMenu` with plain storage, and every stock
 * item's shift route from the inventory. The menu's window type is recorded.
 */
public class BrewingClickOracle {
  static sun.misc.Unsafe unsafe; static RecipeManager manager;
  static ItemStack value(int profile) {
    return switch (profile) {
      case 0 -> ItemStack.EMPTY;
      case 1 -> PotionContents.createItemStack(Items.POTION, Potions.WATER);
      case 2 -> PotionContents.createItemStack(Items.SPLASH_POTION, Potions.AWKWARD);
      case 3 -> TableMenuOracle.item("nether_wart", 17);
      case 4 -> TableMenuOracle.item("blaze_powder", 17);
      case 5 -> TableMenuOracle.item("glass_bottle", 16);
      case 6 -> TableMenuOracle.item("stone", 63);
      case 7 -> TableMenuOracle.item("gunpowder", 64);
      case 8 -> TableMenuOracle.item("dirt", 5);
      default -> TableMenuOracle.item("blaze_powder", 64);
    };
  }
  // A potion's contents are left out: the checker rebuilds stacks by item.
  static JsonElement encoded(ItemStack value) {
    if (value.isEmpty()) return JsonNull.INSTANCE;
    var row = new JsonArray(); row.add(BuiltInRegistries.ITEM.getId(value.getItem())); row.add(value.getCount()); row.add(value.getMaxStackSize());
    return row;
  }
  static JsonArray stored(SimpleContainer storage){var row=new JsonArray();for(int i=0;i<5;i++)row.add(encoded(storage.getItem(i)));return row;}
  static JsonArray physical(Inventory inventory){
    var result=new JsonArray();for(int slot=0;slot<46;slot++){int index=slot>=36&&slot<=44?slot-36:slot>=9&&slot<=35?slot:slot==45?40:slot>=5&&slot<=8?44-slot:-1;result.add(index<0?JsonNull.INSTANCE:encoded(inventory.getItem(index)));}return result;
  }
  static void observe(JsonArray cases,boolean creative,int layout,int profile,int cursor,int slot,int action,int button,ItemStack routed)throws Exception {
    var world=(PlayerCraftingOracle.MenuWorld)unsafe.allocateInstance(PlayerCraftingOracle.MenuWorld.class);world.recipes=manager;
    var owner=(PlayerCraftingOracle.MenuPlayer)unsafe.allocateInstance(PlayerCraftingOracle.MenuPlayer.class);owner.world=world;owner.dropped=new ArrayList<>();
    var abilities=new Abilities();abilities.instabuild=creative;var field=Player.class.getDeclaredField("abilities");field.setAccessible(true);field.set(owner,abilities);
    var inventory=new Inventory(owner,new EntityEquipment());field=Player.class.getDeclaredField("inventory");field.setAccessible(true);field.set(owner,inventory);
    var storage=new SimpleContainer(5);var menu=new BrewingStandMenu(17,inventory,storage,new SimpleContainerData(4));
    if(layout==1)for(int i:new int[]{0,2,3,4,6,33})menu.getSlot(i).set(value(i<3?1:i==3?3:i==4?4:6));
    menu.getSlot(slot).set(routed==null?value(profile):routed.copy());menu.setCarried(value(cursor));
    var before=stored(storage);var player=physical(inventory);var carried=encoded(menu.getCarried());
    boolean overflow=false;
    if(action==ContainerInput.SWAP.ordinal()) {
      var incoming=inventory.getItem(button==40?40:button);var outgoing=menu.getSlot(slot).getItem();
      overflow=(!incoming.isEmpty() && menu.getSlot(slot).mayPlace(incoming) && incoming.getCount()>menu.getSlot(slot).getMaxStackSize(incoming))||(!outgoing.isEmpty() && outgoing.getCount()>outgoing.getMaxStackSize());
    }
    menu.clicked(slot,button,ContainerInput.values()[action],owner);
    var row=new JsonObject();row.addProperty("creative",creative);row.addProperty("slot",slot);row.addProperty("action",action);row.addProperty("button",button);row.addProperty("overflow",overflow);
    row.add("before",before);row.add("player",player);row.add("cursor",carried);row.add("after",stored(storage));row.add("player_after",physical(inventory));row.add("cursor_after",encoded(menu.getCarried()));
    var drops=new JsonArray();for(var drop:owner.dropped)drops.add(encoded(drop));row.add("drops",drops);cases.add(row);
  }
  public static void main(String[] args)throws Exception {
    var initial=MiningToolOracle.initialize();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);unsafe=(sun.misc.Unsafe)f.get(null);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);var pending=TagLoader.loadTagsForExistingRegistries(resources,access);var statics=TagLoader.buildUpdatedLookups(access,pending);var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));for(var tags:pending)tags.apply();
      manager=new RecipeManager(lookup);manager.finalizeRecipeLoading(FeatureFlags.DEFAULT_FLAGS);
      var cases=new JsonArray();
      for(boolean creative:new boolean[]{false,true})for(int layout=0;layout<2;layout++)for(int slot:new int[]{0,1,3,4,5,31,32,40})for(int profile=0;profile<10;profile++) {
        for(int cursor:new int[]{0,1,2,3,4,5,9})for(int button:new int[]{0,1})observe(cases,creative,layout,profile,cursor,slot,ContainerInput.PICKUP.ordinal(),button,null);
        observe(cases,creative,layout,profile,0,slot,ContainerInput.QUICK_MOVE.ordinal(),0,null);
        for(int button:new int[]{0,8,40})observe(cases,creative,layout,profile,0,slot,ContainerInput.SWAP.ordinal(),button,null);
      }
      var routes=new JsonArray();for(var item:BuiltInRegistries.ITEM)observe(routes,false,0,0,0,5,ContainerInput.QUICK_MOVE.ordinal(),0,new ItemStack(item));
      var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);
      out.addProperty("menu_type",BuiltInRegistries.MENU.getId(MenuType.BREWING_STAND));
      out.add("cases",cases);out.add("routes",routes);Files.writeString(Path.of(args[0]),new Gson().toJson(out));
      System.out.println("PASS: "+cases.size()+" actual brewing-stand clicks and "+routes.size()+" stock shift routes.");
    }
  }
}
