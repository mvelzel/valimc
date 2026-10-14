import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;

/** Trace actual BlockCollisions reads and shape requests, including every state's boundary eligibility. */
public class BlockScanOracle {
  private static final Field cursorField;
  static {try{cursorField=BlockCollisions.class.getDeclaredField("cursor");cursorField.setAccessible(true);}
    catch(Exception e){throw new RuntimeException(e);}}
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  private static JsonArray trace(AABB box) throws Exception {
    var reads=new JsonArray();var holder=new Object[1];
    var chunk=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},(p,m,args)->{
      if(m.getName().equals("getBlockState")) {
        var pos=(BlockPos)args[0];var cursor=(Cursor3D)cursorField.get(holder[0]);
        var entry=new JsonArray();entry.add(pos.getX());entry.add(pos.getY());entry.add(pos.getZ());entry.add(cursor.getNextType());reads.add(entry);
        return Blocks.AIR.defaultBlockState();
      }
      throw new AssertionError("Unexpected chunk query: "+m);
    });
    var world=world(chunk);
    var scan=new BlockCollisions<BlockPos>(world,CollisionContext.empty(),box,false,(pos,shape)->pos.immutable());
    holder[0]=scan;while(scan.hasNext())throw new AssertionError("Air produced a collider");
    return reads;
  }
  private static CollisionGetter world(BlockGetter chunk) {
    return (CollisionGetter)Proxy.newProxyInstance(CollisionGetter.class.getClassLoader(),new Class<?>[]{CollisionGetter.class},(p,m,args)->{
      if(m.getName().equals("getChunkForCollisions"))return chunk;
      throw new AssertionError("Unexpected collision world query: "+m);
    });
  }
  private static boolean eligible(BlockState state,int type) {
    var target=new BlockPos(type>0?-1:0,type>1?-1:0,type>2?-1:0);var requested=new boolean[1];
    var chunk=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},(p,m,args)->{
      if(m.getName().equals("getBlockState"))return args[0].equals(target)?state:Blocks.AIR.defaultBlockState();
      throw new AssertionError("Unexpected eligibility chunk query: "+m);
    });
    var context=(CollisionContext)Proxy.newProxyInstance(CollisionContext.class.getClassLoader(),new Class<?>[]{CollisionContext.class},(p,m,args)->{
      if(m.getName().equals("getCollisionShape")){if(args[2].equals(target))requested[0]=true;return Shapes.empty();}
      throw new AssertionError("Unexpected eligibility context query: "+m);
    });
    var scan=new BlockCollisions<BlockPos>(world(chunk),context,new AABB(.2,.2,.2,.8,.8,.8),false,(pos,shape)->pos.immutable());
    while(scan.hasNext())throw new AssertionError("Empty context produced a collider");
    return requested[0];
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var plans=new JsonArray();
    for(double[] offset:new double[][]{{0,0,0},{-17,64,17},{29999990,-64,-29999990}})
      for(double edge:new double[]{-1,-1e-7,Math.nextDown(0.0),0,Math.nextUp(0.0),1e-7,.2,.5,1-1e-7,1,1+1e-7})
        for(double[] size:new double[][]{{.6,1.8,.6},{0,0,0},{1e-8,1e-7,1e-8},{2,2,2}}) {
          var box=new AABB(edge,edge,edge,edge+size[0],edge+size[1],edge+size[2]).move(offset[0],offset[1],offset[2]);
          var c=new JsonObject();c.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));c.add("positions",trace(box));plans.add(c);
        }
    // Raw volume is exactly 8^3=512: verify the bound without dropping corners early.
    var bound=new AABB(.2,.2,.2,5.8,5.8,5.8);var c=new JsonObject();c.add("box",vector(.2,.2,.2,5.8,5.8,5.8));c.add("positions",trace(bound));plans.add(c);
    var flags=new JsonArray();
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      var row=new JsonArray();row.add(Block.getId(state));for(int type=0;type<=3;type++)row.add(eligible(state,type));flags.add(row);
    }
    var result=new JsonObject();result.add("plans",plans);result.add("eligibility",flags);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+plans.size()+" native scan traces and "+flags.size()*4+" actual state boundary decisions.");
  }
}
