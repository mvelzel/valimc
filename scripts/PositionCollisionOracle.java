import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction.Axis;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.Shapes;
import java.nio.file.*;
import java.util.*;

/** Native position-only geometry/offsets, including integer overflow and float rounding. */
public class PositionCollisionOracle {
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var maxOffset=net.minecraft.world.level.block.state.BlockBehaviour.class.getDeclaredMethod("getMaxHorizontalOffset");maxOffset.setAccessible(true);
    var blocks=Set.of(net.minecraft.world.level.block.Blocks.BAMBOO,net.minecraft.world.level.block.Blocks.POINTED_DRIPSTONE,net.minecraft.world.level.block.Blocks.SULFUR_SPIKE);
    var positions=new ArrayList<BlockPos>();
    for(int x:new int[]{-30000000,-65536,-687,-1,0,1,687,65536,30000000})
      for(int z:new int[]{-30000000,-1,0,1,30000000}) {
        positions.add(new BlockPos(x,-64,z));positions.add(new BlockPos(x,320,z));
      }
    var random=new Random(14302);
    for(int i=0;i<64;i++)positions.add(new BlockPos(random.nextInt(60000001)-30000000,random.nextInt(769)-384,random.nextInt(60000001)-30000000));
    var cases=new JsonArray();int clipping=0;
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      if(!blocks.contains(state.getBlock()))continue;
      int id=Block.getId(state);double limit=((Float)maxOffset.invoke(state.getBlock())).doubleValue();
      for(var pos:positions) {
        var offset=state.getOffset(pos);var shape=state.getCollisionShape(EmptyBlockGetter.INSTANCE,pos);
        var c=new JsonObject();c.addProperty("state",id);c.addProperty("limit",limit);c.add("position",vector(pos.getX(),pos.getY(),pos.getZ()));
        c.add("offset",vector(offset.x,offset.y,offset.z));c.add("geometry",BlockFactsOracle.geometry(shape));
        var worldShape=shape.move(pos.getX(),pos.getY(),pos.getZ());var queries=new JsonArray();
        for(var axis:Axis.values()) for(int direction:new int[]{-1,1}) {
          var bounds=worldShape.bounds();double[] lo={bounds.minX+0.01,bounds.minY+0.01,bounds.minZ+0.01};
          double[] hi={bounds.maxX-0.01,bounds.maxY-0.01,bounds.maxZ-0.01};int a=axis.ordinal();
          if(direction>0){hi[a]=bounds.min(axis)-0.15;lo[a]=hi[a]-0.6;}
          else{lo[a]=bounds.max(axis)+0.15;hi[a]=lo[a]+0.6;}
          var box=new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]);
          double delta=direction*4.0,result=Shapes.collide(axis,box,List.of(worldShape),delta);
          var q=new JsonObject();q.addProperty("axis",axis.getName());q.addProperty("delta",delta);
          q.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
          q.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));queries.add(q);clipping++;
        }
        c.add("queries",queries);cases.add(c);
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native position-only shape/offset cases and "+clipping+" clipping queries.");
  }
}
