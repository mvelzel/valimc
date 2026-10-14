import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.chunk.*;
import sun.misc.Unsafe;
import java.nio.file.*;

/** Constructor-free loaded chunk exercises the actual out-of-section lookup. */
public class ChunkHeightOracle {
  private static void set(Class<?> c,Object object,String name,Object value) throws Exception {
    var f=c.getDeclaredField(name);f.setAccessible(true);f.set(object,value);
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(Unsafe)f.get(null);
    var chunk=(LevelChunk)unsafe.allocateInstance(LevelChunk.class);
    set(LevelChunk.class,chunk,"level",unsafe.allocateInstance(ServerLevel.class));
    set(ChunkAccess.class,chunk,"levelHeightAccessor",LevelHeightAccessor.create(-64,384));
    // Entries deliberately remain null: an outside lookup must never dereference a section.
    set(ChunkAccess.class,chunk,"sections",new LevelChunkSection[24]);
    var cases=new JsonArray();
    for(int x:new int[]{-29999999,-17,0,17,29999999})
      for(int z:new int[]{-29999999,-17,0,17,29999999})
        for(int y:new int[]{-1000000,-1000,-81,-80,-66,-65,320,321,335,336,1000,1000000}) {
          var state=chunk.getBlockState(new BlockPos(x,y,z));
          if(state!=Blocks.AIR.defaultBlockState())throw new AssertionError("Native outside state differs");
          var c=new JsonArray();c.add(x);c.add(y);c.add(z);c.add(Block.getId(state));cases.add(c);
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" actual native loaded-chunk outside-height reads.");
  }
}
