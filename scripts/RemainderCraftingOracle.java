import com.google.gson.*;
import java.util.*;
import java.util.stream.*;
import java.nio.file.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.*;
import net.minecraft.server.packs.resources.*;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;
/** Original actual remainder-recipe menu observations; controlled world/stats/network. */
public class RemainderCraftingOracle extends TableMenuClickOracle {
 static JsonElement value(ItemStack stack) {
   if(stack.isEmpty())return JsonNull.INSTANCE;
   var row=new JsonArray();row.add(BuiltInRegistries.ITEM.getId(stack.getItem()));row.add(stack.getCount());
   var glint=stack.get(DataComponents.ENCHANTMENT_GLINT_OVERRIDE);row.add(glint==null?JsonNull.INSTANCE:new JsonPrimitive(glint));
   var damage=stack.get(DataComponents.DAMAGE);row.add(damage==null?JsonNull.INSTANCE:new JsonPrimitive(damage));
   var maximum=stack.get(DataComponents.MAX_STACK_SIZE);row.add(maximum==null?JsonNull.INSTANCE:new JsonPrimitive(maximum));return row;
 }
 static JsonArray physical(net.minecraft.world.entity.player.Inventory inventory) {
   var values=new JsonArray();for(int slot=0;slot<46;slot++) {
     int index=slot>=36&&slot<=44?slot-36:slot>=9&&slot<=35?slot:slot>=5&&slot<=8?44-slot:slot==45?40:-1;
     values.add(value(index<0?ItemStack.EMPTY:inventory.getItem(index)));
   }return values;
 }
 static void trace(RecipeManager recipes,JsonArray cases,int size,boolean creative,Map<Integer,ItemStack> slots,Map<Integer,ItemStack> hidden,int[] action)throws Exception {
   var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
   var world=(MenuWorld)unsafe.allocateInstance(MenuWorld.class);world.recipes=recipes;
   var owner=(MenuPlayer)unsafe.allocateInstance(MenuPlayer.class);owner.world=world;owner.dropped=new ArrayList<>();
   var abilities=new net.minecraft.world.entity.player.Abilities();abilities.instabuild=creative;
   field=net.minecraft.world.entity.player.Player.class.getDeclaredField("abilities");field.setAccessible(true);field.set(owner,abilities);
   var inventory=new net.minecraft.world.entity.player.Inventory(owner,new net.minecraft.world.entity.EntityEquipment());
   field=net.minecraft.world.entity.player.Player.class.getDeclaredField("inventory");field.setAccessible(true);field.set(owner,inventory);
   for(var entry:hidden.entrySet())inventory.setItem(entry.getKey(),entry.getValue().copy());
   AbstractContainerMenu menu=size==3?new Table(inventory,owner):new Menu(inventory,owner);
   for(var entry:slots.entrySet())menu.getSlot(entry.getKey()).set(entry.getValue().copy());
   var before=new JsonArray();for(int i=0;i<46;i++)before.add(value(i==0?ItemStack.EMPTY:menu.getSlot(i).getItem()));
   var owned=physical(inventory);
   menu.clicked(action[1],action[2],ContainerInput.values()[action[0]],owner);
   var after=new JsonArray();for(int i=0;i<46;i++)after.add(value(menu.getSlot(i).getItem()));
   var drops=new JsonArray();for(var stack:owner.dropped)drops.add(value(stack));
   var row=new JsonObject();row.addProperty("size",size);row.addProperty("creative",creative);row.add("before",before);row.add("physical_before",owned);row.add("action",new Gson().toJsonTree(action));row.add("after",after);row.add("physical_after",physical(inventory));row.add("cursor",value(menu.getCarried()));row.add("drops",drops);cases.add(row);
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

      var manager=new RecipeManager(lookup);var cases=new JsonArray();var profiles=new JsonArray();
      for(var holder:manager.getRecipes()) {
        String name=holder.id().identifier().getPath();
        if(!Set.of("cake","honey_block","sugar_from_honey_bottle").contains(name))continue;
        var recipe=(CraftingRecipe)holder.value();var ingredients=ingredients(recipe);
        int w=recipe instanceof ShapedRecipe shape?shape.getWidth():0;
        int h=recipe instanceof ShapedRecipe shape?shape.getHeight():0;
        var profile=new JsonObject();profile.addProperty("width",w);profile.addProperty("height",h);
        var sets=new JsonArray();for(var ingredient:ingredients){var ids=new JsonArray();if(ingredient.isPresent())for(var item:ingredient.get().items().toList())ids.add(BuiltInRegistries.ITEM.getId(item.value()));sets.add(ids.isEmpty()?JsonNull.INSTANCE:ids);}
        profile.add("ingredients",sets);profile.addProperty("result",BuiltInRegistries.ITEM.getId(recipe.assemble(CraftingInput.EMPTY).getItem()));profile.addProperty("count",recipe.assemble(CraftingInput.EMPTY).getCount());profile.addProperty("name","minecraft:"+name);profiles.add(profile);
        String remainder=name.equals("cake")?"bucket":"glass_bottle";
        var output=recipe.assemble(CraftingInput.EMPTY);
        for(int size:new int[]{2,3}) {
          if(w>size||h>size||ingredients.size()>size*size)continue;
          for(boolean creative:new boolean[]{false,true})for(int amount:new int[]{1,2,16,99})for(int layout=0;layout<7;layout++)for(int actionIndex=0;actionIndex<8;actionIndex++) {
            var slots=new HashMap<Integer,ItemStack>();var hidden=new HashMap<Integer,ItemStack>();
            for(int i=0;i<ingredients.size();i++)if(ingredients.get(i).isPresent()) {
              var item=ingredients.get(i).get().items().findFirst().get().value();var stack=new ItemStack(item,amount);
              if(amount>stack.getMaxStackSize())stack.set(DataComponents.MAX_STACK_SIZE,99);
              stack.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
              slots.put((w==0?i:i/w*size+i%w)+1,stack);
            }
            int start=size==3?10:9,end=size==3?45:44;
            if(layout>0)for(int slot=start;slot<=end;slot++)slots.put(slot,stack("bedrock",64));
            if(layout==2)slots.remove(end);
            if(layout==3)slots.put(size==3?37:36,stack(remainder,remainder.equals("bucket")?15:63));
            if(layout==4) {if(size==3)hidden.put(40,stack(remainder,remainder.equals("bucket")?15:63));else slots.put(45,stack(remainder,remainder.equals("bucket")?15:63));}
            if(layout==5)slots.put(end,output.copyWithCount(1));
            if(layout==6)slots.put(start,stack(remainder,remainder.equals("bucket")?15:63));
            int[][] actions={action(ContainerInput.PICKUP,0,0),action(ContainerInput.PICKUP,0,1),action(ContainerInput.QUICK_MOVE,0,0),action(ContainerInput.SWAP,0,0),action(ContainerInput.SWAP,0,40),action(ContainerInput.THROW,0,0),action(ContainerInput.CLONE,0,2),action(ContainerInput.THROW,0,1)};
            trace(manager,cases,size,creative,slots,hidden,actions[actionIndex]);
          }
        }
      }
      var remainderIds=new JsonObject();
      var used=new HashSet<Integer>();for(var profile:profiles)for(var ids:profile.getAsJsonObject().getAsJsonArray("ingredients"))if(!ids.isJsonNull())for(var id:ids.getAsJsonArray())used.add(id.getAsInt());
      for(var item:BuiltInRegistries.ITEM)if(item.getCraftingRemainder()!=null&&used.contains(BuiltInRegistries.ITEM.getId(item))) {
        var remainder=item.getCraftingRemainder().create();
        if(remainder.getCount()!=1||!remainder.getComponentsPatch().isEmpty())throw new AssertionError("Changed remainder template");
        remainderIds.addProperty(Integer.toString(BuiltInRegistries.ITEM.getId(item)),BuiltInRegistries.ITEM.getId(remainder.getItem()));
      }
      var catalog=new JsonObject();catalog.addProperty("version","26.3");catalog.addProperty("data_version",5023);catalog.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");catalog.add("recipes",profiles);catalog.add("remainders",remainderIds);
      Files.writeString(Path.of(args[1]),new Gson().toJson(catalog)+"\n");
      var facts=new JsonObject();facts.addProperty("version","26.3");facts.add("cases",cases);
      Files.writeString(Path.of(args[0]),new Gson().toJson(facts));System.out.println("PASS:"+cases.size()+" native remainder menu traces with effective max-stack/glint/damage /"+profiles.size()+" recipes.");
    }
 }
}
