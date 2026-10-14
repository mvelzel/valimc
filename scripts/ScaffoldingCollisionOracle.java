import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction.Axis;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.nio.file.*;
import java.util.*;

/** Actual native scaffolding/context methods for every state, flag and height boundary. */
public class ScaffoldingCollisionOracle {
  private static class Context extends EntityCollisionContext {
    Context(double bottom,boolean descending,boolean placement){super(descending,placement,bottom,ItemStack.EMPTY,false,null);}
  }
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  private static JsonObject context(double bottom,boolean descending,boolean placement) {
    var c=new JsonObject();c.addProperty("kind","entity");c.addProperty("bottom",bottom);
    c.addProperty("descending",descending);c.addProperty("placement",placement);return c;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var catalog=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();
    var cases=new JsonArray();var below=CollisionMetadata.scaffoldingField("SHAPE_BELOW_BLOCK");int clipping=0;
    for(var entry:catalog.getAsJsonObject("scaffolding").getAsJsonArray("states")) {
      int id=entry.getAsJsonArray().get(0).getAsInt();var state=Block.BLOCK_STATE_REGISTRY.byId(id);
      for(int y:new int[]{-1000000,-384,0,64,320,1000000}) {
        var pos=new BlockPos(-17,y,17);var contexts=new ArrayList<JsonObject>();
        var empty=new JsonObject();empty.addProperty("kind","empty");contexts.add(empty);
        var heights=new ArrayList<Double>();
        for(double h:new double[]{-1.0,0.0,0.5,0.875,1.0,2.0})heights.add(y+h);
        for(double h:new double[]{0.0,1.0}) {
          double threshold=y+h-(double)1.0e-5f;
          heights.add(Math.nextDown(threshold));heights.add(threshold);heights.add(Math.nextUp(threshold));
        }
        for(double height:heights)for(boolean descending:new boolean[]{false,true})for(boolean placement:new boolean[]{false,true})
          contexts.add(context(height,descending,placement));
        for(var facts:contexts) {
          CollisionContext ctx=facts.get("kind").getAsString().equals("empty")?CollisionContext.empty():
            new Context(facts.get("bottom").getAsDouble(),facts.get("descending").getAsBoolean(),facts.get("placement").getAsBoolean());
          var shape=state.getCollisionShape(EmptyBlockGetter.INSTANCE,pos,ctx);var worldShape=shape.move(pos.getX(),y,pos.getZ());
          var c=new JsonObject();c.addProperty("state",id);c.add("position",vector(pos.getX(),y,pos.getZ()));c.add("context",facts);
          c.add("geometry",CollisionMetadata.geometry(shape));
          c.addProperty("above_full",ctx.isAbove(Shapes.block(),pos,true));c.addProperty("above_below",ctx.isAbove(below,pos,true));
          c.addProperty("above_false_default",ctx.isAbove(Shapes.block(),pos,false));var queries=new JsonArray();
          for(var axis:Axis.values())for(int direction:new int[]{-1,1}) {
            double[] lo={-16.8,y+0.1,17.2},hi={-16.2,y+1.9,17.8};int a=axis.ordinal();
            if(direction>0){hi[a]=(a==0?-17:a==1?y:17)-0.15;lo[a]=hi[a]-0.6;}
            else{lo[a]=(a==0?-17:a==1?y:17)+1.15;hi[a]=lo[a]+0.6;}
            var box=new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]);double delta=direction*4.0;
            double result=Shapes.collide(axis,box,List.of(worldShape),delta);var q=new JsonObject();
            q.addProperty("axis",axis.getName());q.addProperty("delta",delta);q.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
            q.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));queries.add(q);clipping++;
          }
          c.add("queries",queries);cases.add(c);
        }
      }
    }
    Files.writeString(Path.of(args[1]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native scaffolding contexts and "+clipping+" clipping queries across all 32 states.");
  }
}
