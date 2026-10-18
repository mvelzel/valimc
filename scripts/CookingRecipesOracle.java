import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.tags.TagLoader;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.*;

/** Original native cooking recipe selection/assembly observations; no upstream recipe files are emitted. */
public class CookingRecipesOracle {
  static java.lang.reflect.Method duration;
  static java.lang.reflect.Field speed;
  static FurnaceBlockEntity furnace;
  static class World extends ServerLevel {
    RecipeManager manager;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public RecipeManager recipeAccess(){return manager;}
    public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
  }
  @SuppressWarnings({"rawtypes","unchecked"})
  static JsonElement observe(RecipeManager manager,World world,RecipeType type,ItemStack input)throws Exception {
    Optional<RecipeHolder<AbstractCookingRecipe>> selected=manager.getRecipeFor(type,new SingleRecipeInput(input),world);
    if(selected.isEmpty())return JsonNull.INSTANCE;
    var holder=selected.get();var recipe=holder.value();var result=recipe.assemble(new SingleRecipeInput(input));
    if(!result.getComponentsPatch().isEmpty())throw new AssertionError("Unobserved cooking output patch "+holder.id());
    var row=new JsonObject();row.addProperty("recipe",holder.id().identifier().toString());
    row.addProperty("result",BuiltInRegistries.ITEM.getId(result.getItem()));row.addProperty("count",result.getCount());
    row.addProperty("ticks",recipe.cookingTime());row.addProperty("xp_bits",Float.floatToRawIntBits(recipe.experience()));
    var times=new JsonArray();for(float multiplier:new float[]{0f,1f,2f}) {speed.setFloat(furnace,multiplier);times.add((Integer)duration.invoke(null,holder,furnace));}
    row.add("times",times);return row;
  }
  public static void main(String[] args)throws Exception {
    var initial=MiningToolOracle.initialize();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    duration=AbstractFurnaceBlockEntity.class.getDeclaredMethod("getTotalCookTime",RecipeHolder.class,AbstractFurnaceBlockEntity.class);duration.setAccessible(true);
    speed=AbstractFurnaceBlockEntity.class.getDeclaredField("speedMultiplier");speed.setAccessible(true);
    furnace=new FurnaceBlockEntity(BlockPos.ZERO,Blocks.FURNACE.defaultBlockState());
    var cases=new JsonArray();
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      var pending=TagLoader.loadTagsForExistingRegistries(resources,access);var statics=TagLoader.buildUpdatedLookups(access,pending);
      var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
      for(var tags:pending)tags.apply();
      var manager=new RecipeManager(lookup);var world=(World)unsafe.allocateInstance(World.class);world.manager=manager;
      var kinds=List.of(RecipeType.SMELTING,RecipeType.SMOKING,RecipeType.BLASTING);
      for(int kind=0;kind<kinds.size();kind++)for(var item:BuiltInRegistries.ITEM)for(int profile=0;profile<3;profile++){
        var input=new ItemStack(item,profile==2?item.getDefaultMaxStackSize():1);
        if(profile==1)input.set(DataComponents.CUSTOM_NAME,Component.literal("Raw"));
        if(profile==0) {
          var type=kinds.get(kind);var recipeInput=new SingleRecipeInput(input);
          long matches=manager.getRecipes().stream().filter(h->h.value().getType()==type && h.value() instanceof AbstractCookingRecipe recipe && recipe.matches(recipeInput,world)).count();
          if(matches>1)throw new AssertionError("Ambiguous stock cooking selection "+item+" "+type);
        }
        var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("item",BuiltInRegistries.ITEM.getId(item));row.addProperty("profile",profile);
        row.add("selected",observe(manager,world,kinds.get(kind),input));cases.add(row);
      }
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+cases.size()+" actual cooking RecipeManager selections/assemblies across stock/named/full inputs and all three cooking kinds; no live processing/XP claim.");
  }
}
