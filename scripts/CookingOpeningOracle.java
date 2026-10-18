import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.MenuProvider;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.BlockState;

/** Original actual native menu-provider queries. Malformed world types are observed, not admitted. */
public class CookingOpeningOracle {
  static class World extends ServerLevel {
    BlockEntity entity;BlockState above;int blockQueries;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockEntity getBlockEntity(BlockPos pos){return entity;}
    public BlockState getBlockState(BlockPos pos){blockQueries++;return above;}
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);var cases=new JsonArray();
    for(var block:List.of(Blocks.FURNACE,Blocks.SMOKER,Blocks.BLAST_FURNACE))for(var state:block.getStateDefinition().getPossibleStates())for(int kind=0;kind<5;kind++)for(var above:List.of(Blocks.AIR,Blocks.STONE,Blocks.WATER)) {
      var world=(World)unsafe.allocateInstance(World.class);world.above=above.defaultBlockState();world.blockQueries=0;
      world.entity=kind==0?null:kind==1?new FurnaceBlockEntity(BlockPos.ZERO,Blocks.FURNACE.defaultBlockState()):kind==2?new SmokerBlockEntity(BlockPos.ZERO,Blocks.SMOKER.defaultBlockState()):kind==3?new BlastFurnaceBlockEntity(BlockPos.ZERO,Blocks.BLAST_FURNACE.defaultBlockState()):new ChestBlockEntity(BlockPos.ZERO,Blocks.CHEST.defaultBlockState());
      var provider=state.getMenuProvider(world,BlockPos.ZERO);
      if((provider!=null)!=(world.entity instanceof MenuProvider)||world.blockQueries!=0)throw new AssertionError("Unexpected native provider dependency");
      var row=new JsonObject();row.addProperty("state",Block.getId(state));row.addProperty("entity",kind);row.addProperty("above",Block.getId(above.defaultBlockState()));row.addProperty("provider",provider!=null);row.addProperty("block_queries",world.blockQueries);cases.add(row);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+cases.size()+" native processing-state menu-provider contexts; no above-block queries, missing provider refuses. Inconsistent owned types still require server fencing.");
  }
}
