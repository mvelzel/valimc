import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.Direction.Axis;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.nio.file.*;
import java.util.*;

/** Native construction, optimization and OR, retaining actual cached shape objects. */
public class VoxelUnionOracle {
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  private static JsonObject probe(String op,VoxelShape left,VoxelShape right,double[] bounds) throws Exception {
    var c=new JsonObject();c.addProperty("operation",op);VoxelShape result;
    if(op.equals("box")){c.add("bounds",vector(bounds));result=left;}
    else {
      c.add("left",CollisionMetadata.geometry(left));
      if(right==null)result=left.optimize();
      else{c.add("right",CollisionMetadata.geometry(right));result=Shapes.or(left,right);}
    }
    c.add("result",CollisionMetadata.geometry(result));var queries=new JsonArray();
    for(var axis:Axis.values())for(int direction:new int[]{-1,1}) {
      int a=axis.ordinal();double[] lo={0.2,0.1,0.2},hi={0.8,1.9,0.8};
      if(direction>0){hi[a]=-2.5;lo[a]=-3.1;}else{lo[a]=3.5;hi[a]=4.1;}
      query(queries,result,axis,new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]),direction*6.0);
      for(double delta:new double[]{-1e-7,-Math.nextDown(1e-7),0.0,Math.nextUp(1e-7),1.0})
        query(queries,result,axis,new AABB(0.2,0.2,0.2,0.8,0.8,0.8),direction*delta);
    }
    c.add("queries",queries);return c;
  }
  private static void query(JsonArray queries,VoxelShape shape,Axis axis,AABB box,double delta) {
    var q=new JsonObject();q.addProperty("axis",axis.getName());q.addProperty("delta",delta);
    q.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
    double result=Shapes.collide(axis,box,List.of(shape),delta);
    q.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));queries.add(q);
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var cacheField=BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cacheField.setAccessible(true);
    var shapes=new LinkedHashMap<String,VoxelShape>();
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      var cache=cacheField.get(state);if(cache==null)continue;
      var f=cache.getClass().getDeclaredField("collisionShape");f.setAccessible(true);var shape=(VoxelShape)f.get(cache);
      shapes.putIfAbsent(new Gson().toJson(CollisionMetadata.geometry(shape)),shape);
    }
    if(shapes.size()!=330)throw new AssertionError("Cached grid coverage changed");
    var cases=new JsonArray();var all=new ArrayList<>(shapes.values());int index=0;
    for(var shape:all) {
      cases.add(probe("optimize",shape,null,null));
      cases.add(probe("union",Shapes.empty(),shape,null));
      cases.add(probe("union",Shapes.block(),shape.move(0.13,0.25,-0.2),null));
      cases.add(probe("union",shape,shape.move(0.5,0.0,0.5),null));
      cases.add(probe("union",shape,all.get((index++*17+31)%all.size()).move(-0.25,0.5,0.0),null));
    }
    for(double gap:new double[]{-1e-7,Math.nextDown(-1e-7),Math.nextUp(-1e-7),-0.0,0.0,
        Math.nextDown(1e-7),1e-7,Math.nextUp(1e-7),0.1}) {
      cases.add(probe("union",Shapes.box(0,0,0,0.5,1,1),Shapes.box(0.5+gap,0,0,1,0.5,1),null));
      cases.add(probe("union",Shapes.box(0.5+gap,0,0,1,0.5,1),Shapes.box(0,0,0,0.5,1,1),null));
    }
    var random=new Random(2603145);
    for(int i=0;i<256;i++) {
      double[] b=new double[6];for(int a=0;a<3;a++){b[a]=random.nextDouble()*4-2;b[a+3]=b[a]+random.nextDouble()*2;}
      cases.add(probe("box",Shapes.create(b[0],b[1],b[2],b[3],b[4],b[5]),null,b));
    }
    for(double lo:new double[]{-1e-7,0.0,0.125,0.5,0.50000005})
      for(double width:new double[]{0.0,Math.nextDown(1e-7),1e-7,Math.nextUp(1e-7),0.125,0.5,1.0}) {
        double[] b={lo,0.0,0.0,lo+width,1.0,1.0};
        cases.add(probe("box",Shapes.create(b[0],b[1],b[2],b[3],b[4],b[5]),null,b));
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native voxel operations / "+cases.size()*36+" exact clips; all 330 cached grids.");
  }
}
