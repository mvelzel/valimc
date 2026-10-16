import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.lighting.*;
import net.minecraft.world.phys.shapes.VoxelShape;

/** Native vertical sky-source edge classes and incremental source-height observations. */
public class SkyColumnOracle {
  static String shape(VoxelShape shape) {
    var boxes=new ArrayList<String>();
    for(var box:shape.toAabbs())boxes.add(box.toString());
    Collections.sort(boxes);return boxes.toString();
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var edge=ChunkSkyLightSources.class.getDeclaredMethod("isEdgeOccluded",BlockState.class,BlockState.class);edge.setAccessible(true);
    var classes=new LinkedHashMap<String,Integer>();var representatives=new ArrayList<BlockState>();var indexes=new StringBuilder();int count=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      String key=(state.getLightDampening()>0)+":"+shape(LightEngine.getOcclusionShape(state,Direction.DOWN))+":"+shape(LightEngine.getOcclusionShape(state,Direction.UP));
      Integer index=classes.get(key);if(index==null){index=classes.size();classes.put(key,index);representatives.add(state);}
      if(index>255)throw new AssertionError("Too many native sky-edge classes");
      indexes.append(String.format(Locale.ROOT,"%02x",index));count++;
    }
    int size=classes.size();var pairs=new byte[(size*size+7)/8];
    for(int above=0;above<size;above++)for(int below=0;below<size;below++){
      int offset=above*size+below;
      if((boolean)edge.invoke(null,representatives.get(above),representatives.get(below)))pairs[offset/8]|=(byte)(1<<(offset%8));
    }
    // Confirm every state shares both edge directions with its class representative.
    int stateIndex=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      int index=Integer.parseInt(indexes.substring(stateIndex*2,stateIndex*2+2),16);
      for(int other=0;other<size;other++){
        if((boolean)edge.invoke(null,state,representatives.get(other)) != ((pairs[(index*size+other)/8]&(1<<((index*size+other)%8)))!=0))throw new AssertionError("Above class mismatch");
        if((boolean)edge.invoke(null,representatives.get(other),state) != ((pairs[(other*size+index)/8]&(1<<((other*size+index)%8)))!=0))throw new AssertionError("Below class mismatch");
      }
      stateIndex++;
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.addProperty("state_count",count);facts.addProperty("class_count",size);facts.addProperty("states",indexes.toString());facts.addProperty("pairs",HexFormat.of().formatHex(pairs));
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");
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
    Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+count+" sky-edge states / "+size+" exact equivalence classes / "+(2L*count*size)+" directed comparisons and "+(24*263)+" native incremental source-height observations. No lateral lighting or client light packets.");
  }
}
