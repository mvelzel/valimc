import com.google.gson.*;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.List;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.phys.Vec3;

/** Actual inherited item below-world callback; persistence/full world tick excluded. */
public class ItemVoidOracle {
  static class World extends ServerLevel {
    int minimum;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getMinY(){return minimum;}
  }
  static class Probe extends ItemEntity {
    World world; int calls; Entity.RemovalReason reason;
    private Probe(){super(null,.5,64,.5,ItemStack.EMPTY,0,0,0);}
    public ServerLevel level(){return world;}
    public void remove(Entity.RemovalReason reason){calls++;this.reason=reason;}
  }
  static Field field(Class<?> owner,String name)throws Exception{
    var f=owner.getDeclaredField(name);f.setAccessible(true);return f;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(World)u.allocateInstance(World.class);var p=(Probe)u.allocateInstance(Probe.class);p.world=world;
    var rows=new JsonArray();
    for(int minimum:new int[]{-64,0,320}){
      world.minimum=minimum;double edge=minimum-64;
      for(double y:new double[]{-1000000,edge-1,Math.nextDown(edge),edge,Math.nextUp(edge),edge+1,1000000}){
        field(Entity.class,"position").set(p,new Vec3(.5,y,.5));p.calls=0;p.reason=null;
        p.checkBelowWorld();
        var row=new JsonObject();row.addProperty("minimum",minimum);row.addProperty("y",y);
        row.addProperty("removed",p.calls==1);row.addProperty("reason",p.reason==null?null:p.reason.name());
        if(p.calls>1)throw new AssertionError("Repeated removal callback");rows.add(row);
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual ItemEntity inherited void-discard boundaries; full tick/storage excluded.");
  }
}
