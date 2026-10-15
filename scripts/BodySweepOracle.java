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
  private static JsonObject run(Vec3 from,Vec3 to,Pose pose,EntityDimensions dimensions,int stop){
    var body=dimensions.makeBoundingBox(to).deflate((double)1.0e-5f);var visits=new JsonArray();
    boolean complete=BlockGetter.forEachBlockIntersectedBetween(from,to,body,(pos,step)->{
      var item=new JsonArray();item.add(pos.getX());item.add(pos.getY());item.add(pos.getZ());item.add(step);visits.add(item);return visits.size()<stop;
    });
    var c=new JsonObject();c.add("from",vec(from));c.add("to",vec(to));c.add("box",box(body));c.addProperty("pose",pose.toString().toLowerCase(Locale.ROOT));c.addProperty("stop_after",stop);c.addProperty("complete",complete);c.add("visits",visits);return c;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var field=Avatar.class.getDeclaredField("POSES");field.setAccessible(true);
    var dimensions=(Map<Pose,EntityDimensions>)field.get(null);var cases=new JsonArray();var deltas=new ArrayList<Vec3>();
    for(double x:new double[]{-1,0,1})for(double y:new double[]{-1,0,1})for(double z:new double[]{-1,0,1})deltas.add(new Vec3(x,y,z));
    deltas.addAll(List.of(new Vec3(.000009,0,0),new Vec3(.00001,0,0),new Vec3(.000011,0,0),new Vec3(2.5,-3,1.25),new Vec3(-2.5,3,-1.25)));
    for(var from:List.of(new Vec3(.5,64,.5),new Vec3(-.3,65.01,-.3),new Vec3(29999999.5,-63.99,-29999999.5)))
      for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))for(var delta:deltas)for(int stop:new int[]{1,3,512}){
        cases.add(run(from,from.add(delta),pose,dimensions.get(pose),stop));
      }
    var random=new Random(15015);var poses=List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING);
    for(int i=0;i<300;i++){
      var from=new Vec3((i%2==0?29999990:0)+random.nextDouble()*4-2,64+random.nextDouble()*4-2,random.nextDouble()*4-2);
      var to=from.add(random.nextDouble()*6-3,random.nextDouble()*6-3,random.nextDouble()*6-3);var pose=poses.get(i%3);
      for(int stop:new int[]{1,3,512})cases.add(run(from,to,pose,dimensions.get(pose),stop));
    }
    for(var delta:List.of(new Vec3(64,0,0),new Vec3(0,-64,0),new Vec3(32,32,32),new Vec3(64,-64,64),new Vec3(.1,0,Math.nextUp(.1))))
      for(var pose:poses)for(int stop:new int[]{1,3,512}){
        var from=new Vec3(.3,64.00001,-.7);cases.add(run(from,from.add(delta),pose,dimensions.get(pose),stop));
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" native ordered body sweep/early-stop traces, including tiny movement, axis ties and remote coordinates.");
  }
}
