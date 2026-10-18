import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.lang.reflect.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.Containers;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;

/** Original native stack splitting/scattering observations with recorded RNG primitives. */
public class ContainerDropOracle {
  static class World extends ServerLevel {
    RandomSource drawSource;JsonArray records;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public RandomSource getRandom(){return drawSource;}
    public int getNextEntityId(){return 1;}
    public boolean addFreshEntity(Entity entity){
      if(!(entity instanceof ItemEntity item))throw new AssertionError("Unexpected entity");
      try{
        var delay=ItemEntity.class.getDeclaredField("pickupDelay");delay.setAccessible(true);
        var row=new JsonObject();row.addProperty("count",item.getItem().getCount());
        row.add("position",new Gson().toJsonTree(new double[]{item.getX(),item.getY(),item.getZ()}));
        var v=item.getDeltaMovement();row.add("velocity",new Gson().toJsonTree(new double[]{v.x,v.y,v.z}));
        row.addProperty("pickup_delay",delay.getInt(item));records.add(row);return true;
      }catch(ReflectiveOperationException e){throw new AssertionError(e);}
    }
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    var cases=new JsonArray();
    for(var position:List.of(new double[]{0,64,0},new double[]{-1.2,-64,-15.8},new double[]{29999983,319,-29999983}))
      for(int count:new int[]{0,1,9,10,11,20,30,31,64,99})for(int seed=0;seed<16;seed++){
        var world=(World)unsafe.allocateInstance(World.class);world.records=new JsonArray();var operations=new JsonArray();
        var delegate=RandomSource.create(seed);
        world.drawSource=(RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,values)->{
          if(method.isDefault())return InvocationHandler.invokeDefault(proxy,method,values==null?new Object[0]:values);
          Object result=method.invoke(delegate,values);
          var op=new JsonArray();op.add(method.getName());
          if(method.getName().equals("nextDouble")){op.add((Double)result);}
          else if(method.getName().equals("nextInt")&&values!=null&&values.length==1){op.add((Integer)values[0]);op.add((Integer)result);}
          else throw new AssertionError("Unexpected RNG primitive: "+method);
          operations.add(op);return result;
        });
        var stack=new ItemStack(Items.OAK_PLANKS,count);
        Containers.dropItemStack(world,position[0],position[1],position[2],stack);
        int sum=0;for(var row:world.records)sum+=row.getAsJsonObject().get("count").getAsInt();
        if(sum!=count||!stack.isEmpty())throw new AssertionError("Native quantity changed");
        var row=new JsonObject();row.add("origin",new Gson().toJsonTree(position));row.addProperty("count",count);row.addProperty("seed",seed);
        row.add("random",operations);row.add("items",world.records);cases.add(row);
      }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+cases.size()+" native stored-stack scattering/split/velocity/delay cases with actual RNG traces; journal, item components and removal callbacks excluded.");
  }
}
