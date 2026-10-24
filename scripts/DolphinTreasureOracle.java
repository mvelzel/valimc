import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.Vec3;

/** Actual native treasure goals, controls and travel, with only the structure answer supplied. */
public class DolphinTreasureOracle {
  public static void main(String[] args) throws Exception {
    var level = MobAiOracle.setup();
    var pool = MobAiOracle.floor(54,32,Blocks.STONE.defaultBlockState());
    pool.addAll(MobAiOracle.box(-32,55,-32,32,66,32,Blocks.WATER.defaultBlockState()));
    var cases = new JsonArray(); int seed=200;
    for (var target : Arrays.asList(new BlockPos(18,60,12),new BlockPos(2,60,0),null))
      for (int air : new int[] {150,4800}) {
        level.treasureResult = target; level.structureQueries = new ArrayList<>();
        var result = MobAiOracle.run(level,"dolphin_treasure_"+(seed++),pool,
          List.of(new MobAiOracle.Spawn("minecraft:dolphin",new Vec3(.5,60,.5),0,seed,Map.of("got_fish",true,"air",air))),
          List.of(),List.of(),120);
        result.add("treasure_result",target == null ? JsonNull.INSTANCE : new Gson().toJsonTree(new int[] {target.getX(),target.getY(),target.getZ()}));
        result.add("structure_queries",new Gson().toJsonTree(level.structureQueries)); cases.add(result);
      }
    var out = new JsonObject(); out.add("cases",cases);
    Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out)+"\n");
    System.out.println("PASS: native dolphin treasure traces: "+cases.size());
  }
}
