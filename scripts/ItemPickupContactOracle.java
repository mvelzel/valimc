import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.world.phys.AABB;

/** Actual AABB query/contact boundaries; accepted player bodies are supplied, no world tick is simulated. */
public class ItemPickupContactOracle {
 static JsonArray box(AABB b){var a=new JsonArray();for(double n:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})a.add(n);return a;}
 public static void main(String[] args)throws Exception{
  var rows=new JsonArray();
  for(double center:new double[]{0,29999970,-29999970})for(float width:new float[]{.6f,.2f})for(float height:new float[]{1.8f,1.5f,.6f,.2f}){
   var body=new AABB(center-width/2.,64,center-width/2.,center+width/2.,64+height,center+width/2.);var query=body.inflate(1,.5,1);
   var xs=new ArrayList<Double>();for(double n:new double[]{query.minX-.125,center,query.maxX+.125}){xs.add(Math.nextDown(n));xs.add(n);xs.add(Math.nextUp(n));}
   var ys=new ArrayList<Double>();for(double n:new double[]{query.minY-.25,64,query.maxY}){ys.add(Math.nextDown(n));ys.add(n);ys.add(Math.nextUp(n));}
   for(double x:xs)for(double y:ys)for(double z:new double[]{center,query.minZ-.125,query.maxZ+.125}){
    var item=new AABB(x-.125,y,z-.125,x+.125,y+.25,z+.125);var row=new JsonObject();row.add("body",box(body));row.add("query",box(query));var position=new JsonArray();position.add(x);position.add(y);position.add(z);row.add("position",position);row.addProperty("contact",query.intersects(item));rows.add(row);
   }
  }
  Files.writeString(Path.of(args[0]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" native pickup AABB boundaries; supplied unmounted bodies, no world/contact callbacks.");
 }
}
