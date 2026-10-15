import com.google.gson.*;
import java.lang.reflect.Proxy;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;

/** Executes native flow queries, retaining every queried cell and supplied scalar state. */
public class FluidFlowOracle {
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonArray position(BlockPos p){var a=new JsonArray();a.add(p.getX());a.add(p.getY());a.add(p.getZ());return a;}
  private static JsonObject observe(Map<BlockPos,BlockState> states){
    var queries=new HashSet<BlockPos>();
    var world=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},(proxy,m,args)->{
      if(m.getName().equals("getBlockState")||m.getName().equals("getFluidState")){
        var p=((BlockPos)args[0]).immutable();queries.add(p);var state=states.getOrDefault(p,Blocks.AIR.defaultBlockState());
        return m.getName().equals("getFluidState")?state.getFluidState():state;
      }
      if(m.getName().equals("getBlockEntity")){queries.add(((BlockPos)args[0]).immutable());return null;}
      throw new AssertionError("Unexpected flow world query "+m);
    });
    var state=states.get(BlockPos.ZERO).getFluidState();var flow=state.getFlow(world,BlockPos.ZERO);
    var c=new JsonObject();var entries=new JsonArray();
    for(var e:states.entrySet()){var b=new JsonObject();b.add("position",position(e.getKey()));b.addProperty("state",Block.getId(e.getValue()));entries.add(b);}
    c.add("states",entries);c.add("flow",vector(flow));var needed=new JsonArray();for(var p:queries)needed.add(position(p));c.add("queries",needed);return c;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();FluidBoundaryMetadata.bindFlowTag();
    var cases=new JsonArray();var random=new Random(2603015);
    var choices=List.of(Blocks.AIR.defaultBlockState(),Blocks.STONE.defaultBlockState(),Blocks.ICE.defaultBlockState(),
      Blocks.OAK_SIGN.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState(),
      Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,4),Blocks.LAVA.defaultBlockState().setValue(LiquidBlock.LEVEL,7),
      Blocks.OAK_SLAB.defaultBlockState(),Blocks.OAK_SLAB.defaultBlockState().setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED,true),
      Blocks.GLASS.defaultBlockState(),Blocks.OAK_FENCE.defaultBlockState(),Blocks.SCAFFOLDING.defaultBlockState(),
      Blocks.SHULKER_BOX.defaultBlockState(),Blocks.MOVING_PISTON.defaultBlockState(),Blocks.POWDER_SNOW.defaultBlockState());
    for(var block:List.of(Blocks.WATER,Blocks.LAVA))for(int level=0;level<=15;level++){
      var center=block.defaultBlockState().setValue(LiquidBlock.LEVEL,level);
      for(var direction:Direction.Plane.HORIZONTAL)for(var neighbor:choices)
        for(var below:List.of(Blocks.AIR.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState()))for(boolean ceiling:new boolean[]{false,true}){
          var states=new LinkedHashMap<BlockPos,BlockState>();states.put(BlockPos.ZERO,center);var p=BlockPos.ZERO.relative(direction);
          states.put(p,neighbor);states.put(p.below(),below);states.put(p.above(),ceiling?Blocks.STONE.defaultBlockState():Blocks.AIR.defaultBlockState());
          cases.add(observe(states));
        }
      for(int seed=0;seed<32;seed++){
        var states=new LinkedHashMap<BlockPos,BlockState>();states.put(BlockPos.ZERO,center);
        for(var direction:Direction.Plane.HORIZONTAL)for(int y=-1;y<=1;y++)states.put(BlockPos.ZERO.relative(direction).offset(0,y,0),choices.get(random.nextInt(choices.size())));
        cases.add(observe(states));
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native water/lava flow cases; actual neighbor-query coverage, contextual block entities absent.");
  }
}
