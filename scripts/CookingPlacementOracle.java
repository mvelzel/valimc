import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.world.level.block.*;

/** Original native furnace-family candidate/state observations; consumption and lifecycle excluded. */
public class CookingPlacementOracle {
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    var world=(ChestPlacementOracle.World)unsafe.allocateInstance(ChestPlacementOracle.World.class);
    var cases=new JsonArray();var states=new JsonArray();
    var targets=List.of(Blocks.AIR.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,1),Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,8),Blocks.LAVA.defaultBlockState(),Blocks.STONE.defaultBlockState());
    var kinds=List.of(Blocks.FURNACE,Blocks.SMOKER,Blocks.BLAST_FURNACE);
    for(int kind=0;kind<kinds.size();kind++) {
      var block=kinds.get(kind);
      for(var state:block.getStateDefinition().getPossibleStates()) {
        var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("state",Block.getId(state));row.addProperty("facing",state.getValue(HorizontalDirectionalBlock.FACING).get3DDataValue());row.addProperty("lit",state.getValue(AbstractFurnaceBlock.LIT));states.add(row);
      }
      for(var horizontal:Direction.Plane.HORIZONTAL)for(var face:Direction.values())for(boolean secondary:List.of(false,true))for(var target:targets) {
        world.blocks=new HashMap<>();world.blocks.put(BlockPos.ZERO,target);
        var result=block.getStateForPlacement(new ChestPlacementOracle.Context(world,horizontal,face,secondary));
        if(result==null)throw new AssertionError("Absent native candidate");
        var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("heading",horizontal.get3DDataValue());row.addProperty("face",face.get3DDataValue());row.addProperty("secondary",secondary);row.addProperty("target",Block.getId(target));row.addProperty("result",Block.getId(result));cases.add(row);
      }
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);out.add("states",states);Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+cases.size()+" actual native processing-block placement candidates and "+states.size()+" state properties; no placement admission/lifecycle/loot claim.");
  }
}
