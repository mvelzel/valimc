import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.nio.file.*;
import java.util.*;

/** Compare actual native nonempty AND and native box creation, never a reconstructed reference. */
public class VoxelIntersectionOracle {
  private static final JsonArray shapes=new JsonArray(),pairs=new JsonArray(),boxes=new JsonArray();
  private static final Map<String,Integer> ids=new LinkedHashMap<>();
  private static final Gson gson=new Gson();
  private static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static int id(VoxelShape shape) throws Exception {
    var geometry=BlockFactsOracle.geometry(shape);String key=gson.toJson(geometry);
    return ids.computeIfAbsent(key,k->{shapes.add(geometry);return shapes.size()-1;});
  }
  private static VoxelShape box(AABB bounds) throws Exception {
    var shape=Shapes.create(bounds);var c=new JsonObject();c.add("bounds",vector(bounds.minX,bounds.minY,bounds.minZ,bounds.maxX,bounds.maxY,bounds.maxZ));
    c.addProperty("shape",id(shape));boxes.add(c);return shape;
  }
  private static void pair(VoxelShape left,VoxelShape right) throws Exception {
    var p=new JsonArray();p.add(id(left));p.add(id(right));p.add(Shapes.joinIsNotEmpty(left,right,BooleanOp.AND));pairs.add(p);
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var cacheField=BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cacheField.setAccessible(true);
    var grids=new LinkedHashMap<String,VoxelShape>();
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      var cache=cacheField.get(state);if(cache==null)continue;
      var f=cache.getClass().getDeclaredField("collisionShape");f.setAccessible(true);var shape=(VoxelShape)f.get(cache);
      grids.putIfAbsent(gson.toJson(BlockFactsOracle.geometry(shape)),shape);
    }
    if(grids.size()!=330)throw new AssertionError("Cached grid coverage differs");
    var probes=new ArrayList<VoxelShape>(grids.values());
    probes.add(Shapes.or(Shapes.box(0,0,0,.25,1,1),Shapes.box(.75,0,0,1,1,1)));
    probes.add(Shapes.or(Shapes.box(0,0,0,1,.25,1),Shapes.box(0,.75,0,1,1,1)));
    for(double[] offset:new double[][]{{0,0,0},{-17,64,17},{29999990,-64,-29999990}}) {
      var tests=new ArrayList<VoxelShape>();
      for(double[] b:new double[][]{{.2,.1,.2,.8,1.9,.8},{1,0,0,2,1,1},{1-1e-8,0,0,2,1,1},
          {1-2e-7,0,0,2,1,1},{0,0,0,1,1,1},{.25,.5,.25,.75,1.5,.75},{0,.5,0,1,1,1},
          {0,0,0,1e-8,1,1},{.3,.3,.3,.7,.7,.7},{-.1,.99,-.1,.1,1.2,.1},
          {0,-1e-7,0,1,1+1e-7,1},{-.25,0,.375,.25,1.5,.625}})
        tests.add(box(new AABB(b[0],b[1],b[2],b[3],b[4],b[5]).move(offset[0],offset[1],offset[2])));
      for(var shape:probes) {
        var moved=shape.move(offset[0],offset[1],offset[2]);pair(moved,moved);pair(moved,moved.move(0,0,0));
        for(var test:tests){pair(moved,test);pair(test,moved);}
        if(shape.isEmpty()||offset[0]==-17)continue;
        var bounds=moved.toAabbs().getFirst();
        double[] min={bounds.minX,bounds.minY,bounds.minZ},max={bounds.maxX,bounds.maxY,bounds.maxZ};
        for(int axis=0;axis<3;axis++)for(int sign:new int[]{-1,1})for(double gap:new double[]{-2e-7,-1e-8,0,1e-8,2e-7}) {
          double[] lo=new double[3],hi=new double[3];
          for(int i=0;i<3;i++){lo[i]=min[i]+(max[i]-min[i])*.25;hi[i]=min[i]+(max[i]-min[i])*.75;}
          if(sign>0){lo[axis]=max[axis]+gap;hi[axis]=lo[axis]+.2;}
          else {hi[axis]=min[axis]-gap;lo[axis]=hi[axis]-.2;}
          var test=box(new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]));pair(moved,test);pair(test,moved);
        }
      }
    }
    for(double delta:new double[]{-2e-7,-Math.nextUp(1e-7),-1e-7,-Math.nextDown(1e-7),-1e-8,-0.0,0,1e-8,1e-7,2e-7}) {
      var a=box(new AABB(-.2,-.2,-.2,1,1,1));var b=box(new AABB(1+delta,-.1,-.1,2,1,1));pair(a,b);pair(b,a);
      var thin=box(new AABB(-.2,0,0,-.2+Math.abs(delta),1,1));pair(thin,thin);pair(thin,thin.move(0,0,0));
    }
    var all=new ArrayList<VoxelShape>(grids.values());
    for(int i=0;i<all.size();i++)for(int stride:new int[]{0,1,7,53,177}) {
      var a=all.get(i);var b=all.get((i+stride)%all.size());pair(a,b);pair(b,a);
    }
    var result=new JsonObject();result.add("shapes",shapes);result.add("boxes",boxes);result.add("pairs",pairs);
    Files.writeString(Path.of(args[0]),gson.toJson(result));
    System.out.println("PASS: "+pairs.size()+" actual native intersections / "+boxes.size()+" boxes, all 330 cached grids plus compounds.");
  }
}
