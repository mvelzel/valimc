import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.phys.*;

/** Actual ordered candidate traversal, independent of world/contact callbacks. */
public class BodySweepOracle {
  private static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonArray box(AABB b){var a=new JsonArray();for(double n:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})a.add(n);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var field=Avatar.class.getDeclaredField("POSES");field.setAccessible(true);
    var dimensions=(Map<Pose,EntityDimensions>)field.get(null);var cases=new JsonArray();var deltas=new ArrayList<Vec3>();
    for(double x:new double[]{-1,0,1})for(double y:new double[]{-1,0,1})for(double z:new double[]{-1,0,1})deltas.add(new Vec3(x,y,z));
    deltas.addAll(List.of(new Vec3(.000009,0,0),new Vec3(.00001,0,0),new Vec3(.000011,0,0),new Vec3(2.5,-3,1.25),new Vec3(-2.5,3,-1.25)));
    for(var from:List.of(new Vec3(.5,64,.5),new Vec3(-.3,65.01,-.3),new Vec3(29999999.5,-63.99,-29999999.5)))
      for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))for(var delta:deltas)for(int stop:new int[]{1,3,512}){
        var to=from.add(delta);var body=dimensions.get(pose).makeBoundingBox(to).deflate((double)1.0e-5f);var visits=new JsonArray();
        boolean complete=BlockGetter.forEachBlockIntersectedBetween(from,to,body,(pos,step)->{
          var item=new JsonArray();item.add(pos.getX());item.add(pos.getY());item.add(pos.getZ());item.add(step);visits.add(item);return visits.size()<stop;
        });
        var c=new JsonObject();c.add("from",vec(from));c.add("to",vec(to));c.add("box",box(body));c.addProperty("pose",pose.toString().toLowerCase(Locale.ROOT));c.addProperty("stop_after",stop);c.addProperty("complete",complete);c.add("visits",visits);cases.add(c);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" native ordered body sweep/early-stop traces, including tiny movement, axis ties and remote coordinates.");
  }
}
