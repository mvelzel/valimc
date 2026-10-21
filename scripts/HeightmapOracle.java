import com.google.gson.*;
import java.io.ByteArrayOutputStream;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.levelgen.Heightmap;

/** Native heightmap predicates and actual update/removal traces, with a controlled flat column. */
public class HeightmapOracle {
  static class Column extends LevelChunk {
    Map<BlockPos,BlockState> edits;
    private Column(){super((Level)null,(ChunkPos)null);}
    public int getMinY(){return -64;}
    public int getHeight(){return 384;}
    public ChunkPos getPos(){return new ChunkPos(0,0);}
    public BlockState getBlockState(BlockPos p){return edits.getOrDefault(p,base(p.getY()));}
  }
  static BlockState base(int y){return (y < -64||y>63?Blocks.AIR:y==-64?Blocks.BEDROCK:y<60?Blocks.STONE:y<63?Blocks.DIRT:Blocks.GRASS_BLOCK).defaultBlockState();}
  public static void main(String[] args)throws Exception{
    MiningToolOracle.initialize(); // Bind the jar's resolved block tags before evaluating predicates.
    if(!Heightmap.Types.MOTION_BLOCKING.isOpaque().test(Blocks.STONE.defaultBlockState()))throw new AssertionError("Missing native heightmap tags");
    var types=Heightmap.Types.values();int count=Block.BLOCK_STATE_REGISTRY.size();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    var rows=new JsonArray();var random=new Random(170416);var all=Block.BLOCK_STATE_REGISTRY;
    for(int n=0;n<32;n++){
      var column=(Column)unsafe.allocateInstance(Column.class);column.edits=new HashMap<>();int x=n%16,z=n/16;
      var maps=new Heightmap[types.length];for(int i=0;i<types.length;i++){maps[i]=new Heightmap(column,types[i]);for(int y=-64;y<=63;y++)maps[i].update(x,y,z,base(y));if(maps[i].getFirstAvailable(x,z)!=64)throw new AssertionError("Wrong flat-column initialization");}
      var operations=new ArrayList<int[]>();
      for(var pair:List.of(new int[]{319,Block.getId(Blocks.STONE.defaultBlockState())},new int[]{319,Block.getId(Blocks.WATER.defaultBlockState())},new int[]{319,Block.getId(Blocks.FIRE.defaultBlockState())},new int[]{319,0},new int[]{63,0},new int[]{62,0},new int[]{318,Block.getId(Blocks.OAK_LEAVES.defaultBlockState())},new int[]{318,0},new int[]{-64,0}))operations.add(pair);
      for(int i=0;i<96;i++)operations.add(new int[]{random.nextInt(384)-64,random.nextInt(count)});
      var steps=new JsonArray();
      for(var op:operations){
        var state=all.byId(op[1]);column.edits.put(new BlockPos(x,op[0],z),state);var heights=new JsonArray();
        for(var map:maps){map.update(x,op[0],z,state);heights.add(map.getFirstAvailable(x,z));}
        var step=new JsonArray();step.add(op[0]);step.add(op[1]);step.add(heights);steps.add(step);
      }
      var row=new JsonObject();row.addProperty("x",x);row.addProperty("z",z);row.add("steps",steps);rows.add(row);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: 3360 actual column updates across "+types.length+" heightmap types (the predicates are the block fact table's). Generation, skylight and biome rain remain excluded.");
  }
}
