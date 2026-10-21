import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Mirror;
import net.minecraft.world.level.block.Rotation;
import net.minecraft.world.level.levelgen.structure.templatesystem.StructureProcessorType;

/**
 * What placing structure templates needs besides the templates (VMC-025c, VMC-025f; the
 * templates themselves are `StructureOracle facts`' `structure_templates.json`): the
 * `worldgen/processor_list` registry as vanilla's codec encodes it, as a server loads it, and
 * per block state that a rotation or mirror changes, its rotations (clockwise 90, 180,
 * counterclockwise 90) and mirrors (left-right, front-back), by global state id; other states
 * are their own transforms.
 *
 * Usage: StructureTemplateOracle BLOCK_TRANSFORMS.json PROCESSOR_LISTS.json [--packs PACK...].
 */
public class StructureTemplateOracle {
  public static void main(String[] args) throws Exception {
    // The registries a server loads: vanilla's pack, then `--packs` (VMC-028c).
    var packs = WorldgenFactsOracle.packs(args);
    args = WorldgenFactsOracle.withoutPacks(args);
    net.minecraft.core.HolderLookup.Provider lookup = WorldgenFactsOracle.loadRegistries(packs);
    var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
    var lists = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.PROCESSOR_LIST).listElements().forEach(holder ->
        lists.put(holder.key().identifier().toString(), StructureProcessorType.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));
    var transforms = new JsonArray();
    for (var state : Block.BLOCK_STATE_REGISTRY) {
      int id = Block.getId(state);
      var row = new JsonArray();
      row.add(id);
      boolean changes = false;
      for (var rotation : List.of(Rotation.CLOCKWISE_90, Rotation.CLOCKWISE_180, Rotation.COUNTERCLOCKWISE_90)) {
        int to = Block.getId(state.rotate(rotation));
        changes |= to != id;
        row.add(to);
      }
      for (var mirror : List.of(Mirror.LEFT_RIGHT, Mirror.FRONT_BACK)) {
        int to = Block.getId(state.mirror(mirror));
        changes |= to != id;
        row.add(to);
      }
      if (changes) transforms.add(row);
    }
    var out = new JsonObject();
    out.addProperty("version", "26.3");
    out.addProperty("data_version", 5023);
    out.add("transforms", transforms);
    Files.writeString(Path.of(args[0]), new GsonBuilder().create().toJson(out) + "\n");
    var listsOut = new JsonObject();
    lists.forEach((k, v) -> listsOut.add(k, WorldgenFactsOracle.widenFloats(v)));
    Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(listsOut) + "\n");
    System.out.println("PASS: " + transforms.size() + " block states that rotate or mirror, " + lists.size() + " processor lists");
  }
}
