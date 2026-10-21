import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.core.Direction.Axis;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.nio.file.*;
import java.util.*;

/** Original native clipping/intersection probe using every cached geometry, named by its first state. */
public class CollisionOracle {
  private static final Gson gson=new Gson();
  private static VoxelShape[] shapes;private static int[] representatives;
  private static JsonArray vector(double... values) {var result=new JsonArray();for(double v:values)result.add(v);return result;}
  private static JsonArray box(AABB b) {return vector(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ);}
  private static JsonObject query(int[] ids, double[][] offsets, Axis axis, AABB box, double delta, boolean raw) {
    var nativeShapes=new ArrayList<VoxelShape>();var selected=new JsonArray();var shifts=new JsonArray();
    for(int i=0;i<ids.length;i++){selected.add(representatives[ids[i]]);shifts.add(vector(offsets[i]));
      nativeShapes.add(shapes[ids[i]].move(offsets[i][0],offsets[i][1],offsets[i][2]));}
    double result=raw?nativeShapes.getFirst().collide(axis,box,delta):Shapes.collide(axis,box,nativeShapes,delta);
    var c=new JsonObject();c.add("shapes",selected);c.add("offsets",shifts);c.addProperty("axis",axis.getName());
    c.add("box",box(box));c.addProperty("delta",delta);c.addProperty("raw",raw);
    c.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));return c;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var cache=net.minecraft.world.level.block.state.BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cache.setAccessible(true);
    var keys=new HashSet<String>();var found=new ArrayList<VoxelShape>();var states=new ArrayList<Integer>();
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(cache.get(state)==null)continue;
      var shape=state.getCollisionShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO);
      if(keys.add(gson.toJson(BlockFactsOracle.geometry(shape)))){found.add(shape);states.add(Block.getId(state));}
    }
    shapes=found.toArray(VoxelShape[]::new);representatives=states.stream().mapToInt(Integer::intValue).toArray();
    var queries=new JsonArray();var intersections=new JsonArray();var random=new Random(14301);
    for(int id=0;id<shapes.length;id++) {
      for(int i=0;i<40;i++) {
        double[] offset={random.nextInt(9)-4,random.nextInt(9)-4,random.nextInt(9)-4};
        double x=offset[0]+random.nextDouble()*4-1.5,y=offset[1]+random.nextDouble()*4-1.5,z=offset[2]+random.nextDouble()*4-1.5;
        var bounds=new AABB(x,y,z,x+0.6000000238418579,y+1.7999999523162842,z+0.6000000238418579);
        for(var axis:Axis.values())queries.add(query(new int[]{id},new double[][]{offset},axis,bounds,random.nextDouble()*8-4,true));
      }
      for(var axis:Axis.values())for(double delta:new double[]{-0.0,0.0,-1e-8,1e-8,-1e-7,1e-7,-1,1})
        queries.add(query(new int[]{id},new double[][]{{0,0,0}},axis,new AABB(-0.3,-0.3,-0.3,0.3,1.5,0.3),delta,true));
      for(double[] offset:new double[][]{{30000000,64,-30000000},{-30000000,-64,30000000}})
        for(var axis:Axis.values())for(double delta:new double[]{-1e-7,1e-7,-1,1}) {
          var bounds=new AABB(offset[0]-0.3,offset[1],offset[2]-0.3,offset[0]+0.3,offset[1]+1.8,offset[2]+0.3);
          queries.add(query(new int[]{id},new double[][]{offset},axis,bounds,delta,true));
        }
      if(shapes[id].isEmpty())continue;
      var first=shapes[id].toAabbs().getFirst();
      for(var axis:Axis.values())for(double coordinate:shapes[id].getCoords(axis))
        for(double epsilon:new double[]{-1.0000001e-7,-1e-7,-0.9999999e-7,0,0.9999999e-7,1e-7,1.0000001e-7})
          for(int direction:new int[]{-1,1}) {
            double[] lo={first.minX+0.01,first.minY+0.01,first.minZ+0.01};double[] hi={first.maxX-0.01,first.maxY-0.01,first.maxZ-0.01};
            int index=axis.ordinal();if(direction==1){hi[index]=coordinate+epsilon;lo[index]=hi[index]-0.6;}
            else{lo[index]=coordinate+epsilon;hi[index]=lo[index]+0.6;}
            queries.add(query(new int[]{id},new double[][]{{0,0,0}},axis,new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]),direction,true));
          }
    }
    for(int i=0;i<1024;i++) {
      int a=random.nextInt(shapes.length),b=random.nextInt(shapes.length);
      double x=random.nextDouble()*4-1.5,y=random.nextDouble()*4-1.5,z=random.nextDouble()*4-1.5;
      var bounds=new AABB(x,y,z,x+0.6,y+1.8,z+0.6);
      double delta=i%8==0?1e-8:random.nextDouble()*8-4;var axis=Axis.values()[i%3];
      queries.add(query(new int[]{a,b},new double[][]{{0,0,0},{0.25,0.5,-0.25}},axis,bounds,delta,false));
      queries.add(query(new int[]{b,a},new double[][]{{0.25,0.5,-0.25},{0,0,0}},axis,bounds,delta,false));
      var other=new AABB(random.nextDouble()*4-1.5,random.nextDouble()*4-1.5,random.nextDouble()*4-1.5,
        random.nextDouble()*4-1.5,random.nextDouble()*4-1.5,random.nextDouble()*4-1.5);
      var c=new JsonObject();c.add("a",box(bounds));c.add("b",box(other));c.addProperty("intersects",bounds.intersects(other));intersections.add(c);
    }
    for(double delta:new double[]{-0.0,0.0,1e-8,-1e-8,1e-7,-1e-7})
      queries.add(query(new int[]{},new double[][]{},Axis.X,new AABB(0,0,0,1,1,1),delta,false));
    var output=new JsonObject();output.add("queries",queries);output.add("intersections",intersections);
    Files.writeString(Path.of(args[0]),gson.toJson(output));
    System.out.println("PASS: "+queries.size()+" native clipping queries across all "+shapes.length+" cached grids and "+intersections.size()+" intersections.");
  }
}
