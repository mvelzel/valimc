import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.*;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;

/** Invoke the actual native supplied-shape movement method; no recreated reference algorithm. */
public class MovementCollisionOracle {
  private static Method resolve;
  private static final JsonArray shapes=new JsonArray(),cases=new JsonArray();
  private static final Map<String,Integer> ids=new LinkedHashMap<>();
  private static final Gson gson=new Gson();
  private static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static int id(VoxelShape shape) throws Exception {
    var geometry=BlockFactsOracle.geometry(shape);String key=gson.toJson(geometry);
    return ids.computeIfAbsent(key,k->{shapes.add(geometry);return shapes.size()-1;});
  }
  private static void probe(AABB box,List<VoxelShape> colliders,Vec3 movement) throws Exception {
    probe(box,colliders,movement,Vec3.ZERO);
  }
  private static void probe(AABB box,List<VoxelShape> colliders,Vec3 movement,Vec3 offset) throws Exception {
    var world=colliders.stream().map(s->s.move(offset.x,offset.y,offset.z)).toList();
    var result=(Vec3)resolve.invoke(null,movement,box,world);var c=new JsonObject();
    c.add("position",vector(offset.x,offset.y,offset.z));
    c.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
    c.add("requested",vector(movement.x,movement.y,movement.z));var list=new JsonArray();
    for(var shape:colliders)list.add(id(shape));c.add("shapes",list);var bits=new JsonArray();
    for(double value:new double[]{result.x,result.y,result.z})bits.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(value)));
    c.add("result_bits",bits);cases.add(c);
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    resolve=Entity.class.getDeclaredMethod("collideWithShapes",Vec3.class,AABB.class,List.class);resolve.setAccessible(true);
    var cacheField=BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cacheField.setAccessible(true);
    var grids=new LinkedHashMap<String,VoxelShape>();
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      var cache=cacheField.get(state);if(cache==null)continue;
      var f=cache.getClass().getDeclaredField("collisionShape");f.setAccessible(true);var shape=(VoxelShape)f.get(cache);
      grids.putIfAbsent(gson.toJson(BlockFactsOracle.geometry(shape)),shape);
    }
    if(grids.size()!=330)throw new AssertionError("Unexpected cached-grid coverage");
    var motions=new ArrayList<Vec3>();
    for(int sign:new int[]{-1,1})for(double[] v:new double[][]{{2,-1,2},{2,-1,1},{1,-1,2},{2,1,2},{0,-3,0},{2,0,0},{0,0,2},{1e-8,1e-7,-1e-8},{0,-0.0,0}})
      motions.add(new Vec3(sign*v[0],sign*v[1],sign*v[2]));
    motions.add(new Vec3(-0.0,-0.0,-0.0));motions.add(new Vec3(Math.nextDown(1e-7),Math.nextUp(1e-7),-1e-7));
    for(var shape:grids.values())for(double[] p:new double[][]{{0,0,0},{-17,64,17},{29999998,-64,-29999998}}) {
      for(var box:List.of(new AABB(-1.2,1.25,-1.2,-.6,3.05,-.6),new AABB(.2,.1,.2,.8,1.9,.8)))
        for(var motion:motions)probe(box.move(p[0],p[1],p[2]),List.of(shape),motion,new Vec3(p[0],p[1],p[2]));
    }
    var corner=Shapes.box(1,0,1,2,3,2);var floor=Shapes.box(-4,-1,-4,4,0,4);
    var wallX=Shapes.box(1,0,-4,2,3,4);var wallZ=Shapes.box(-4,0,1,4,3,2);var ceiling=Shapes.box(-4,2,-4,4,3,4);
    List<List<VoxelShape>> layouts=List.of(List.of(),List.of(Shapes.empty()),List.of(corner),
      List.of(floor,corner),List.of(floor,wallX),List.of(floor,wallX,wallZ,ceiling),List.of(Shapes.empty(),corner));
    for(var layout:layouts)for(double x:new double[]{-2,-1,-0.0,0.0,1,2})
      for(double y:new double[]{-2,0,2})for(double z:new double[]{-2,-1,-0.0,0.0,1,2})
        for(var box:List.of(new AABB(-.3,0,-.3,.3,1.8,.3),new AABB(2.2,0,2.2,2.8,1.8,2.8)))
          probe(box,layout,new Vec3(x,y,z));
    probe(new AABB(-.3,0,-.3,.3,1.8,.3),Collections.nCopies(128,corner),new Vec3(2,-1,2));
    var output=new JsonObject();output.add("shapes",shapes);output.add("cases",cases);
    Files.writeString(Path.of(args[0]),gson.toJson(output));
    System.out.println("PASS: "+cases.size()+" native movement vectors across all 330 cached grids and compound/empty layouts.");
  }
}
