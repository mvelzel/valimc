/** Original observations of actual menu Ctrl-Q, with world/stats/network controlled. */
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
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;

public class CraftingBulkOracle extends TableMenuClickOracle {
  static void bulk(RecipeManager manager,JsonArray cases,int size,boolean creative,Map<Integer,ItemStack> slots,ItemStack cursor)throws Exception {
    var observations=new JsonArray();
    int[][] actions={action(ContainerInput.THROW,0,1)};
    if(size==3)observe(manager,observations,creative,slots,Map.of(),cursor,actions);
    else observeMenu(manager,observations,creative,slots,cursor,actions);
    var row=new JsonObject();row.addProperty("size",size);row.add("observation",observations.get(0));cases.add(row);
  }
  public static void main(String[]args)throws Exception {
    var initial=MiningToolOracle.initialize();
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      var pending=net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,access);
      var statics=net.minecraft.tags.TagLoader.buildUpdatedLookups(access,pending);var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));for(var tags:pending)tags.apply();
      var manager=new RecipeManager(lookup);var cases=new JsonArray();
      var profiles=JsonParser.parseString(Files.readString(Path.of("priv/crafting/recipes.json"))).getAsJsonObject().getAsJsonArray("recipes");
      for(var entry:profiles)for(int size:new int[]{2,3}) {
        var profile=entry.getAsJsonObject();int width=profile.get("width").getAsInt(),height=profile.get("height").getAsInt();
        var ingredients=profile.getAsJsonArray("ingredients");
        if(width>size||height>size||ingredients.size()>size*size)continue;
        var slots=new HashMap<Integer,ItemStack>();
        for(int i=0;i<ingredients.size();i++)if(!ingredients.get(i).isJsonNull()) {
          var item=new ItemStack(BuiltInRegistries.ITEM.byId(ingredients.get(i).getAsJsonArray().get(0).getAsInt()));
          item.setCount(Math.min(2,item.getMaxStackSize()));
          item.set(net.minecraft.core.component.DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
          slots.put((width==0?i:i/width*size+i%width)+1,item);
        }
        for(boolean creative:new boolean[]{false,true})bulk(manager,cases,size,creative,slots,ItemStack.EMPTY);
      }
      for(int size:new int[]{2,3})for(boolean creative:new boolean[]{false,true})for(int amount:new int[]{1,5,6,17,64}) {
        for(var cursor:List.of(ItemStack.EMPTY,stack("stone",1),stack("oak_planks",4)))
          bulk(manager,cases,size,creative,Map.of(size*size,stack("oak_log",amount)),cursor);
        int bottom=size+1;
        int top=Math.min(amount,63);
        bulk(manager,cases,size,creative,Map.of(1,stack("oak_planks",top),2,stack("oak_planks",top),bottom,stack("oak_planks",top+1),bottom+1,stack("oak_planks",top+1)),ItemStack.EMPTY);
      }
      var facts=new JsonObject();facts.addProperty("version","26.3");facts.add("cases",cases);
      Files.writeString(Path.of(args[0]),new Gson().toJson(facts));
      System.out.println("PASS:"+cases.size()+" actual menu Ctrl-Q traces, ordinary recipes/both grids/permissions, cursor refusals, recipe identity and five-record continuation boundaries.");
    }
  }
}
