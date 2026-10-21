import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.lighting.*;

/** Native incremental sky-source height observations (the edge classes are the block fact table's). */
public class SkyColumnOracle {
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    int count=Block.BLOCK_STATE_REGISTRY.size();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    var rows=new JsonArray();var random=new Random(170417);
    for(int n=0;n<24;n++){
      var column=(HeightmapOracle.Column)unsafe.allocateInstance(HeightmapOracle.Column.class);column.edits=new HashMap<>();int x=n%16,z=n/16;
      var sky=new ChunkSkyLightSources(column);for(int y=-64;y<=63;y++)sky.update(column,x,y,z);
      if(sky.getLowestSourceY(x,z)!=64)throw new AssertionError("Native sky-source initialization");
      var operations=new ArrayList<int[]>();
      for(var block:List.of(Blocks.STONE,Blocks.GLASS,Blocks.OAK_LEAVES,Blocks.WATER,Blocks.OAK_SLAB,Blocks.FIRE,Blocks.AIR))operations.add(new int[]{319,Block.getId(block.defaultBlockState())});
      for(int i=0;i<128;i++)operations.add(new int[]{random.nextInt(384)-64,random.nextInt(count)});
      for(int y=63;y>=-64;y--)operations.add(new int[]{y,0});
      var steps=new JsonArray();
      for(var op:operations){
        column.edits.put(new BlockPos(x,op[0],z),Block.BLOCK_STATE_REGISTRY.byId(op[1]));sky.update(column,x,op[0],z);
        var step=new JsonArray();step.add(op[0]);step.add(op[1]);step.add(sky.getLowestSourceY(x,z));steps.add(step);
      }
      var row=new JsonObject();row.addProperty("x",x);row.addProperty("z",z);row.add("steps",steps);rows.add(row);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+(24*263)+" native incremental source-height observations. No lateral lighting or client light packets.");
  }
}
