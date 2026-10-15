import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.phys.*;

/** Actual AABB swept contact and strict segment entry, independent of collision-axis resolution. */
public class SweptContactOracle {
  private static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonArray box(AABB b){var a=new JsonArray();for(double n:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})a.add(n);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var f=Avatar.class.getDeclaredField("POSES");f.setAccessible(true);var dimensions=(Map<Pose,EntityDimensions>)f.get(null);var cases=new JsonArray();
    var shapes=List.of(List.<AABB>of(),List.of(new AABB(1,64,0,2,65,1)),List.of(new AABB(0,64,0,1,64.9,1)),List.of(new AABB(1,64,0,2,65,1),new AABB(-1,65,-1,0,65.5,0)));
    for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))
      for(var from:List.of(new Vec3(.5,64,.5),new Vec3(-.3,64.9,.5),new Vec3(.5,64.9000001,.5),new Vec3(.5,65,.5)))
        for(var movement:List.of(Vec3.ZERO,new Vec3(3,0,0),new Vec3(-3,-2,0),new Vec3(0,-1,0),new Vec3(1,1,1),new Vec3(.0000001,0,0)))for(var boxes:shapes){
          var body=dimensions.get(pose).makeBoundingBox(from);var c=new JsonObject();c.add("body",box(body));c.add("movement",vec(movement));var bs=new JsonArray();for(var b:boxes)bs.add(box(b));c.add("boxes",bs);c.addProperty("hit",body.collidedAlongVector(movement,boxes));cases.add(c);
        }
    var random=new Random(15016);
    for(int i=0;i<500;i++){
      var from=new Vec3(random.nextDouble()*4-2,64+random.nextDouble()*4-2,random.nextDouble()*4-2);var movement=new Vec3(random.nextDouble()*6-3,random.nextDouble()*6-3,random.nextDouble()*6-3);
      var body=dimensions.get(Pose.STANDING).makeBoundingBox(from);var b=new AABB(random.nextDouble()*2-1,64+random.nextDouble(),random.nextDouble()*2-1,random.nextDouble()*2,65+random.nextDouble(),random.nextDouble()*2);
      var c=new JsonObject();c.add("body",box(body));c.add("movement",vec(movement));var bs=new JsonArray();bs.add(box(b));c.add("boxes",bs);c.addProperty("hit",body.collidedAlongVector(movement,List.of(b)));cases.add(c);
    }
    var out=new JsonObject();out.add("sweeps",cases);var clips=new JsonArray();
    for(var from:List.of(new Vec3(0,64,.5),new Vec3(.5,64.5,.5),new Vec3(-1,65,.5)))
      for(var to:List.of(new Vec3(2,64,.5),new Vec3(2,64.5,.5),new Vec3(.5,64.5,.5),new Vec3(-1,65,.5))){
        var b=new AABB(0,64,0,1,65,1);var c=new JsonObject();c.add("box",box(b));c.add("from",vec(from));c.add("to",vec(to));c.add("clip",b.clip(from,to).map(SweptContactOracle::vec).orElse(null));clips.add(c);
      }
    out.add("clips",clips);Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out));System.out.println("PASS: "+cases.size()+" actual swept contacts and "+clips.size()+" strict segment clips.");
  }
}
