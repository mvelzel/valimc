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

/** Original observations of the real cooking award hook, with controlled world I/O. */
public class CookingExperienceOracle {
  static RegistryAccess.Frozen access;
  static class World extends ServerLevel {
    RandomSource random; List<Integer> values; int floats;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public RandomSource getRandom(){return random;}
    public RegistryAccess registryAccess(){return access;}
    public int getNextEntityId(){return 1;}
    public boolean noCollision(AABB box){return true;}
    public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> type,AABB box,Predicate<? super T> test){return List.of();}
    public boolean addFreshEntity(Entity entity){values.add(((ExperienceOrb)entity).getValue());return true;}
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
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("rates",rates.size());out.add("cases",cases);out.add("math_boundaries",boundaries);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+cases.size()+" actual createExperience calls across "+rates.size()+" stock XP rates and "+boundaries.size()+" native Mth/float32 boundaries; no live award protocol claim.");
  }
}
