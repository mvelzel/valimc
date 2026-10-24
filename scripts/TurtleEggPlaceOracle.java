import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.*;

/** Original calls to native placement hooks, including same-block property changes. */
public class TurtleEggPlaceOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    var level = RedstoneOracle.probe(lookup);
    level.entities = new HashMap<>();
    level.blockTicks = new net.minecraft.world.ticks.LevelTicks<>(p -> true);
    level.fluidTicks = new net.minecraft.world.ticks.LevelTicks<>(p -> true);
    for (int x = 6; x <= 9; x++) for (int z = -1; z <= 1; z++) {
      var chunk = new net.minecraft.world.level.ChunkPos(x, z);
      level.blockTicks.addContainer(chunk, new net.minecraft.world.ticks.LevelChunkTicks<>());
      level.fluidTicks.addContainer(chunk, new net.minecraft.world.ticks.LevelChunkTicks<>());
    }
    level.events = new JsonArray(); level.writes = new JsonArray();
    level.sounds = new JsonArray(); level.blockEvents = new JsonArray(); level.primed = new JsonArray();
    var cases = new JsonArray();
    var egg = Blocks.TURTLE_EGG.defaultBlockState();
    for (var support : List.of(Blocks.SAND, Blocks.RED_SAND, Blocks.STONE, Blocks.AIR))
      for (var old : List.of(Blocks.AIR.defaultBlockState(), Blocks.STONE.defaultBlockState(),
          egg, egg.setValue(TurtleEggBlock.EGGS, 2)))
        for (int eggs = 1; eggs <= 4; eggs++) for (int hatch = 0; hatch <= 2; hatch++)
          for (int x : List.of(127, 128)) {
            var pos = new BlockPos(x, 64, 8);
            level.cells.clear(); level.cells.put(pos.below(), support.defaultBlockState()); level.cells.put(pos, old);
            level.events = new JsonArray(); level.writes = new JsonArray();
            var state = egg.setValue(TurtleEggBlock.EGGS, eggs).setValue(TurtleEggBlock.HATCH, hatch);
            boolean changed = level.setBlock(pos, state, 3, 512);
            var row = new JsonObject(); row.addProperty("x", x);
            row.addProperty("support", Block.getId(support.defaultBlockState()));
            row.addProperty("old", Block.getId(old)); row.addProperty("state", Block.getId(state));
            row.addProperty("changed", changed); row.add("events", level.events); cases.add(row);
          }
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(cases) + "\n");
    System.out.println("PASS: native turtle-egg placement cases: " + cases.size());
  }
}
