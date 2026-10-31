import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.Mth;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.ExperienceOrb;
import net.minecraft.world.level.block.entity.AbstractFurnaceBlockEntity;
import net.minecraft.world.level.entity.EntityTypeTest;
import net.minecraft.world.phys.*;

/**
 * Original observations of the real cooking award hook, with controlled world I/O, and of an
 * occupied furnace's removal (VMC-032c5, `preRemoveSideEffects`): the item entities its slots
 * drop and the orbs its stored recipes pay out, with every fraction draw fixed.
 */
public class CookingExperienceOracle {
  static RegistryAccess.Frozen access;
  static class World extends ServerLevel {
    RandomSource random; List<Integer> values; int floats;
    net.minecraft.world.item.crafting.RecipeManager recipes; List<Entity> spawned;
    public net.minecraft.world.item.crafting.RecipeManager recipeAccess(){return recipes;}
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public RandomSource getRandom(){return random;}
    public RegistryAccess registryAccess(){return access;}
    public int getNextEntityId(){return 1;}
    public boolean noCollision(AABB box){return true;}
    public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> type,AABB box,Predicate<? super T> test){return List.of();}
    public boolean addFreshEntity(Entity entity){
      if(spawned!=null)spawned.add(entity);
      if(entity instanceof ExperienceOrb orb)values.add(orb.getValue());
      return true;
    }
  }
  static Set<Integer> samples(float fraction) {
    var result=new LinkedHashSet<Integer>(List.of(0,1,8388608,16777215));
    int edge=(int)Math.ceil((double)fraction*16777216);
    for(int sample:new int[]{edge-1,edge,edge+1})if(sample>=0&&sample<16777216)result.add(sample);
    return result;
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);
    var hook=AbstractFurnaceBlockEntity.class.getDeclaredMethod("createExperience",ServerLevel.class,Vec3.class,int.class,float.class);hook.setAccessible(true);
    var rates=new TreeMap<Integer,String>();
    var metadata=JsonParser.parseString(Files.readString(Path.of("priv/crafting/cooking.json"))).getAsJsonObject();
    for(var element:metadata.getAsJsonArray("recipes")){
      var row=element.getAsJsonObject();rates.putIfAbsent(row.get("xp_bits").getAsInt(),row.get("recipe").getAsString());
    }
    var cases=new JsonArray();var boundaries=new JsonArray();
    for(var rate:rates.entrySet())for(int count:new int[]{1,2,3,7,8,9,10,31,63,64,127,255,511,1000,4096}){
      float xp=Float.intBitsToFloat(rate.getKey());float product=count*xp;
      for(int sample:samples(Mth.frac(product))){
        var world=(World)unsafe.allocateInstance(World.class);world.values=new ArrayList<>();
        var delegate=RandomSource.create(17);
        world.random=(RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,params)->{
          if(method.getName().equals("nextFloat")){world.floats++;return sample/16777216f;}
          return method.invoke(delegate,params);
        });
        hook.invoke(null,world,Vec3.ZERO,count,xp);
        var row=new JsonObject();row.addProperty("recipe",rate.getValue());row.addProperty("count",count);row.addProperty("draw",sample);
        row.addProperty("experience",world.values.stream().mapToInt(Integer::intValue).sum());row.addProperty("draws",world.floats);
        var values=new JsonArray();world.values.forEach(values::add);row.add("orbs",values);cases.add(row);
      }
    }
    for(var rate:rates.entrySet())for(int count:new int[]{16777215,16777216,16777217,1073741823,1073741824,2147483647}){
      float xp=Float.intBitsToFloat(rate.getKey());float product=count*xp;float fraction=Mth.frac(product);
      for(int sample:samples(fraction)){
        var row=new JsonObject();row.addProperty("recipe",rate.getValue());row.addProperty("count",count);row.addProperty("draw",sample);
        boolean safe=(double)product<=Integer.MAX_VALUE;row.addProperty("safe",safe);
        row.addProperty("experience",Mth.floor(product)+(fraction!=0f&&sample/16777216f<fraction?1:0));
        row.addProperty("draws",fraction!=0f?1:0);boundaries.add(row);
      }
    }
    var removals=removals(unsafe);
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("rates",rates.size());out.add("cases",cases);out.add("math_boundaries",boundaries);out.add("removals",removals);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+removals.size()+" occupied processor removals; "+cases.size()+" actual createExperience calls across "+rates.size()+" stock XP rates and "+boundaries.size()+" native Mth/float32 boundaries; no live award protocol claim.");
  }

  // An occupied furnace, smoker or blast furnace removed (`preRemoveSideEffects` at a position):
  // its slots drop through `Containers.dropContents` and each stored recipe's experience pops at
  // the block's centre. Every fraction draw (`nextFloat`) is fixed to `draw`.
  static JsonArray removals(sun.misc.Unsafe unsafe)throws Exception {
    var initial=MiningToolOracle.initialize();
    var rows=new JsonArray();
    try(var resources=new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))){
      var pending=net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,access);
      var statics=net.minecraft.tags.TagLoader.buildUpdatedLookups(access,pending);
      var staticKeys=statics.stream().map(r->r.key()).collect(java.util.stream.Collectors.toSet());
      var base=net.minecraft.core.HolderLookup.Provider.create(java.util.stream.Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=net.minecraft.resources.RegistryDataLoader.load(resources,base.listRegistries().toList(),net.minecraft.resources.RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var keys=loaded.listRegistryKeys().collect(java.util.stream.Collectors.toSet());
      var lookup=net.minecraft.core.HolderLookup.Provider.create(java.util.stream.Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
      for(var tags:pending)tags.apply();
      var manager=new net.minecraft.world.item.crafting.RecipeManager(lookup);
      var used=AbstractFurnaceBlockEntity.class.getDeclaredField("recipesUsed");used.setAccessible(true);
      var B=net.minecraft.world.level.block.Blocks.class;
      Object[][] setups={
        {"furnace",new String[]{"raw_iron:5","coal:3","iron_ingot:9"},new String[]{"minecraft:iron_ingot_from_smelting_raw_iron:10","minecraft:gold_ingot_from_smelting_raw_gold:3"}},
        {"smoker",new String[]{"beef:64","oak_log:2",""},new String[]{"minecraft:cooked_beef_from_smoking:7"}},
        {"blast_furnace",new String[]{"","","iron_ingot:1"},new String[]{"minecraft:iron_ingot_from_blasting_raw_iron:1","minecraft:gold_ingot_from_blasting_raw_gold:2","minecraft:copper_ingot_from_blasting_raw_copper:5"}},
        {"furnace",new String[]{"cobblestone:64","",""},new String[]{}},
      };
      for(var setup:setups)for(int draw:new int[]{0,16777215}){
        var block=BuiltInRegistries.BLOCK.getValue(net.minecraft.resources.Identifier.withDefaultNamespace((String)setup[0]));
        var pos=new net.minecraft.core.BlockPos(3,64,-5);
        var entity=(AbstractFurnaceBlockEntity)((net.minecraft.world.level.block.EntityBlock)block).newBlockEntity(pos,block.defaultBlockState());
        var row=new JsonObject();row.addProperty("kind",(String)setup[0]);row.addProperty("draw",draw);
        var slots=new JsonArray();
        var stacks=(String[])setup[1];
        for(int i=0;i<3;i++){
          if(stacks[i].isEmpty()){slots.add(JsonNull.INSTANCE);continue;}
          var parts=stacks[i].split(":");
          entity.setItem(i,new net.minecraft.world.item.ItemStack(BuiltInRegistries.ITEM.getValue(net.minecraft.resources.Identifier.withDefaultNamespace(parts[0])),Integer.parseInt(parts[1])));
          var slot=new JsonArray();slot.add(parts[0]);slot.add(Integer.parseInt(parts[1]));slots.add(slot);
        }
        var recipes=new JsonObject();
        var map=(it.unimi.dsi.fastutil.objects.Reference2IntOpenHashMap<net.minecraft.resources.ResourceKey<net.minecraft.world.item.crafting.Recipe<?>>>)used.get(entity);
        for(var recipe:(String[])setup[2]){
          int split=recipe.lastIndexOf(':');var name=recipe.substring(0,split);int count=Integer.parseInt(recipe.substring(split+1));
          var key=net.minecraft.resources.ResourceKey.create(net.minecraft.core.registries.Registries.RECIPE,net.minecraft.resources.Identifier.parse(name));
          if(manager.byKey(key).isEmpty())throw new AssertionError("Unknown recipe "+name);
          map.addTo(key,count);recipes.addProperty(name,count);
        }
        row.add("slots",slots);row.add("recipes",recipes);
        var world=(World)unsafe.allocateInstance(World.class);world.values=new ArrayList<>();world.spawned=new ArrayList<>();world.recipes=manager;
        var delegate=RandomSource.create(draw);
        world.random=(RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,params)->{
          if(method.getName().equals("nextFloat")){world.floats++;return draw/16777216f;}
          return method.invoke(delegate,params);
        });
        entity.setLevel(world);
        entity.preRemoveSideEffects(pos,block.defaultBlockState());
        var items=new JsonArray();var orbs=new JsonArray();
        for(var spawned:world.spawned){
          var at=new JsonArray();at.add(spawned.getX());at.add(spawned.getY());at.add(spawned.getZ());
          if(spawned instanceof ExperienceOrb orb){var o=new JsonObject();o.addProperty("value",orb.getValue());o.add("at",at);orbs.add(o);}
          else if(spawned instanceof net.minecraft.world.entity.item.ItemEntity item){
            var o=new JsonObject();o.addProperty("item",BuiltInRegistries.ITEM.getKey(item.getItem().getItem()).getPath());o.addProperty("count",item.getItem().getCount());o.add("at",at);items.add(o);
          }
          else throw new AssertionError("Unexpected spawn "+spawned);
        }
        row.add("items",items);row.add("orbs",orbs);row.addProperty("draws",world.floats);
        row.add("origin",new Gson().toJsonTree(new int[]{pos.getX(),pos.getY(),pos.getZ()}));
        rows.add(row);
      }
    }
    return rows;
  }
}
