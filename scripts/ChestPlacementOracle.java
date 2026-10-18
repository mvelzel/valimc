import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.context.BlockPlaceContext;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.ChestType;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.*;

/** Original native placement observations. Does not place blocks, consume items or simulate updates. */
public class ChestPlacementOracle {
  static class World extends ServerLevel {
    Map<BlockPos,BlockState> blocks;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){return blocks.getOrDefault(pos,Blocks.AIR.defaultBlockState());}
    public FluidState getFluidState(BlockPos pos){return getBlockState(pos).getFluidState();}
  }
  static class Context extends BlockPlaceContext {
    Direction horizontal, face;boolean secondary;
    Context(Level level,Direction horizontal,Direction face,boolean secondary){
      super(level,null,InteractionHand.MAIN_HAND,new ItemStack(Blocks.CHEST),new BlockHitResult(new Vec3(.5,.5,.5),face,BlockPos.ZERO,false));
      this.horizontal=horizontal;this.face=face;this.secondary=secondary;
    }
    public Direction getHorizontalDirection(){return horizontal;}
    public Direction getClickedFace(){return face;}
    public boolean isSecondaryUseActive(){return secondary;}
    public BlockPos getClickedPos(){return BlockPos.ZERO;}
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(World)u.allocateInstance(World.class);world.blocks=new HashMap<>();
    var neighbours=new ArrayList<Map<BlockPos,BlockState>>();neighbours.add(Map.of());
    for(var side:Direction.Plane.HORIZONTAL)for(var block:List.of(Blocks.CHEST,Blocks.TRAPPED_CHEST))for(var state:block.getStateDefinition().getPossibleStates())
      neighbours.add(Map.of(BlockPos.ZERO.relative(side),state));
    var fluids=List.of(Blocks.AIR.defaultBlockState(),Blocks.WATER.defaultBlockState(),
      Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,1),Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,8),
      Blocks.LAVA.defaultBlockState(),Blocks.STONE.defaultBlockState());
    var contexts=new JsonArray();var isolated=new JsonArray();int doubles=0;
    for(int n=0;n<neighbours.size();n++)for(var horizontal:Direction.Plane.HORIZONTAL)for(var face:Direction.values())for(boolean secondary:new boolean[]{false,true})for(var fluid:fluids){
      world.blocks=new HashMap<>(neighbours.get(n));world.blocks.put(BlockPos.ZERO,fluid);
      var result=Blocks.CHEST.getStateForPlacement(new Context(world,horizontal,face,secondary));
      if(result==null)throw new AssertionError("Unexpected absent chest candidate");
      if(result.getValue(ChestBlock.TYPE)!=ChestType.SINGLE)doubles++;
      var row=new JsonObject();row.addProperty("neighbor",n);row.addProperty("horizontal",horizontal.get3DDataValue());row.addProperty("face",face.get3DDataValue());
      row.addProperty("secondary",secondary);row.addProperty("target",Block.getId(fluid));row.addProperty("result",Block.getId(result));row.addProperty("wet",result.getValue(ChestBlock.WATERLOGGED));
      contexts.add(row);
      if(n==0&&face==Direction.UP&&!secondary)isolated.add(row.deepCopy());
    }
    var fluidStates=new JsonArray();
    for(var state:Block.BLOCK_STATE_REGISTRY){
      world.blocks=new HashMap<>();world.blocks.put(BlockPos.ZERO,state);
      var result=Blocks.CHEST.getStateForPlacement(new Context(world,Direction.NORTH,Direction.UP,false));
      var row=new JsonArray();row.add(Block.getId(state));row.add(Block.getId(result));fluidStates.add(row);
    }
    var yaw=new JsonArray();var angles=new ArrayList<Float>();
    for(float value:new float[]{-Float.MAX_VALUE,-1080,-405,-360,-315,-225,-135,-45.000004f,-45,-44.999996f,0,44.999996f,45,45.000004f,135,225,315,360,405,1080,Float.MAX_VALUE})angles.add(value);
    var random=new Random(42);
    for(int i=0;i<8192;i++){float value=Float.intBitsToFloat(random.nextInt());if(Float.isFinite(value))angles.add(value);}
    for(float value:angles){var row=new JsonArray();row.add((double)value);row.add(Direction.fromYRot(value).get3DDataValue());yaw.add(row);}
    var worlds=new JsonArray();
    for(var blocks:neighbours){var rows=new JsonArray();for(var entry:blocks.entrySet()){
      var row=new JsonObject();row.add("position",new Gson().toJsonTree(List.of(entry.getKey().getX(),entry.getKey().getY(),entry.getKey().getZ())));
      row.addProperty("state",Block.getId(entry.getValue()));rows.add(row);
    }worlds.add(rows);}
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("neighbor_worlds",neighbours.size());out.addProperty("double_candidates",doubles);out.add("isolated",isolated);out.add("yaw",yaw);out.add("fluid_states",fluidStates);out.add("neighbors",worlds);out.add("cases",contexts);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+contexts.size()+" native chest placement candidates over "+neighbours.size()+" isolated/single-neighbor worlds, plus all target fluid states and yaw boundaries; actual placement, neighbor updates and lifecycle excluded.");
  }
}
