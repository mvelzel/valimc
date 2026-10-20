import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.Direction;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.lighting.LightEngine;
import net.minecraft.world.phys.shapes.Shapes;

/**
 * Light facts per block state (VMC-022a): emission and dampening, one byte per
 * state (emission << 4 | dampening), and per direction an equivalence class of
 * the face's light-occlusion shape (`LightEngine.getOcclusionShape`). For each
 * direction d, `occludes[d]` says whether light leaving a block of face class a
 * through d is stopped by a block whose opposite face has class b
 * (`Shapes.faceShapeOccludes`, as `LightEngine.shapeOccludes` does). Every state
 * is checked against every class representative of the other side.
 */
public class LightFactsOracle {
  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    var directions = Direction.values();
    var states = new ArrayList<BlockState>();
    for (var state : Block.BLOCK_STATE_REGISTRY) states.add(state);
    int count = states.size();

    var properties = new StringBuilder();
    for (var state : states) {
      int emission = state.getLightEmission(), dampening = state.getLightDampening();
      if (emission < 0 || emission > 15 || dampening < 0 || dampening > 15) throw new AssertionError("light value range");
      properties.append(String.format(Locale.ROOT, "%02x", emission << 4 | dampening));
    }

    var faces = new JsonArray();
    var classLists = new ArrayList<List<BlockState>>();
    var stateClasses = new int[6][count];
    for (var d : directions) {
      var classes = new LinkedHashMap<String, Integer>();
      var representatives = new ArrayList<BlockState>();
      var text = new StringBuilder();
      for (int i = 0; i < count; i++) {
        var key = SkyColumnOracle.shape(LightEngine.getOcclusionShape(states.get(i), d));
        Integer index = classes.get(key);
        if (index == null) { index = classes.size(); classes.put(key, index); representatives.add(states.get(i)); }
        if (index > 255) throw new AssertionError("too many face classes");
        stateClasses[d.ordinal()][i] = index;
        text.append(String.format(Locale.ROOT, "%02x", index));
      }
      classLists.add(representatives);
      var face = new JsonObject();
      face.addProperty("direction", d.getSerializedName());
      face.addProperty("class_count", classes.size());
      face.addProperty("states", text.toString());
      faces.add(face);
    }

    var tables = new JsonArray();
    long checks = 0;
    for (var d : directions) {
      var from = classLists.get(d.ordinal());
      var to = classLists.get(d.getOpposite().ordinal());
      var bits = new byte[(from.size() * to.size() + 7) / 8];
      for (int a = 0; a < from.size(); a++)
        for (int b = 0; b < to.size(); b++)
          if (occludes(from.get(a), to.get(b), d)) { int o = a * to.size() + b; bits[o / 8] |= (byte) (1 << (o % 8)); }
      // Each state agrees with its class on both sides of the face.
      for (int i = 0; i < count; i++) {
        var state = states.get(i);
        int a = stateClasses[d.ordinal()][i];
        int b = stateClasses[d.getOpposite().ordinal()][i];
        for (int k = 0; k < to.size(); k++) {
          int o = a * to.size() + k;
          if (occludes(state, to.get(k), d) != ((bits[o / 8] & (1 << (o % 8))) != 0)) throw new AssertionError("from-class mismatch " + state);
          checks++;
        }
        for (int k = 0; k < from.size(); k++) {
          int o = k * to.size() + b;
          if (occludes(from.get(k), state, d) != ((bits[o / 8] & (1 << (o % 8))) != 0)) throw new AssertionError("to-class mismatch " + state);
          checks++;
        }
      }
      var table = new JsonObject();
      table.addProperty("direction", d.getSerializedName());
      table.addProperty("bits", HexFormat.of().formatHex(bits));
      tables.add(table);
    }

    var facts = new JsonObject();
    facts.addProperty("version", "26.3");
    facts.addProperty("data_version", 5023);
    facts.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    facts.addProperty("state_count", count);
    facts.addProperty("properties", properties.toString());
    facts.add("faces", faces);
    facts.add("occludes", tables);
    Files.writeString(Path.of(args[0]), new Gson().toJson(facts) + "\n");
    var sizes = new ArrayList<Integer>();
    for (var f : faces) sizes.add(f.getAsJsonObject().get("class_count").getAsInt());
    System.out.println("PASS: light facts for " + count + " states; face classes per direction " + sizes + "; " + checks + " occlusion checks against class representatives");
  }

  static boolean occludes(BlockState from, BlockState to, Direction d) {
    return Shapes.faceShapeOccludes(LightEngine.getOcclusionShape(from, d), LightEngine.getOcclusionShape(to, d.getOpposite()));
  }
}
