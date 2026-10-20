import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.server.level.ChunkTrackingView;
import net.minecraft.world.level.ChunkPos;

/**
 * VMC-070: vanilla's chunk tracking views. Records the chunks of views at every
 * distance 2..32 and the entering/leaving chunks of view changes (moves, distance
 * changes, teleports, empty views) as `ChunkTrackingView` computes them.
 */
public class ChunkViewOracle {
  static final int LIMIT = 1_875_000;

  static JsonArray chunks(List<ChunkPos> positions) {
    var array = new JsonArray();
    for (var pos : positions) { array.add(pos.x()); array.add(pos.z()); }
    return array;
  }

  static JsonElement view(ChunkPos center, Integer distance) {
    if (distance == null) return JsonNull.INSTANCE;
    var view = new JsonObject();
    view.addProperty("x", center.x()); view.addProperty("z", center.z());
    view.addProperty("distance", distance);
    return view;
  }

  static ChunkTrackingView of(ChunkPos center, Integer distance) {
    return distance == null ? ChunkTrackingView.EMPTY : ChunkTrackingView.of(center, distance);
  }

  static JsonObject difference(ChunkPos from, Integer fromDistance, ChunkPos to, Integer toDistance) {
    var entering = new ArrayList<ChunkPos>();
    var leaving = new ArrayList<ChunkPos>();
    ChunkTrackingView.difference(of(from, fromDistance), of(to, toDistance), entering::add, leaving::add);
    var result = new JsonObject();
    result.add("from", view(from, fromDistance)); result.add("to", view(to, toDistance));
    result.add("entering", chunks(entering)); result.add("leaving", chunks(leaving));
    return result;
  }

  static ChunkPos center(Random random) {
    return random.nextInt(4) == 0
        ? new ChunkPos(random.nextInt(2 * LIMIT + 1) - LIMIT, random.nextInt(2 * LIMIT + 1) - LIMIT)
        : new ChunkPos(random.nextInt(65) - 32, random.nextInt(65) - 32);
  }

  public static void main(String[] args) throws Exception {
    var random = new Random(70);
    var views = new JsonArray();
    for (int distance = 2; distance <= 32; distance++) {
      var center = center(random);
      var positions = new ArrayList<ChunkPos>();
      ChunkTrackingView.of(center, distance).forEach(positions::add);
      var view = view(center, distance).getAsJsonObject();
      view.add("chunks", chunks(positions));
      views.add(view);
    }
    var differences = new JsonArray();
    for (int i = 0; i < 200; i++) {
      var from = center(random);
      int fromDistance = 2 + random.nextInt(31);
      int toDistance = random.nextInt(3) == 0 ? 2 + random.nextInt(31) : fromDistance;
      int reach = random.nextInt(4) == 0 ? 2 * (fromDistance + toDistance) + 8 : 3;
      var to = new ChunkPos(from.x() + random.nextInt(2 * reach + 1) - reach,
                            from.z() + random.nextInt(2 * reach + 1) - reach);
      differences.add(difference(from, fromDistance, to, toDistance));
    }
    var origin = new ChunkPos(0, 0);
    differences.add(difference(origin, 6, origin, 3));
    differences.add(difference(origin, 4, origin, 6));
    differences.add(difference(origin, 2, origin, 32));
    differences.add(difference(origin, null, new ChunkPos(-7, 3), 10));
    differences.add(difference(new ChunkPos(-7, 3), 10, origin, null));
    differences.add(difference(origin, 10, new ChunkPos(1000, -1000), 10));
    var facts = new JsonObject();
    facts.add("views", views); facts.add("differences", differences);
    Files.writeString(Path.of(args[0]), new Gson().toJson(facts) + "\n");
    System.out.println("PASS: " + views.size() + " views and " + differences.size() + " view changes recorded");
  }
}
