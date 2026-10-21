import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.util.datafix.DataFixers;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Mirror;
import net.minecraft.world.level.block.Rotation;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.levelgen.feature.Feature;
import net.minecraft.world.level.levelgen.structure.templatesystem.StructureProcessorType;
import net.minecraft.world.level.levelgen.structure.templatesystem.StructureTemplate;
import net.minecraft.world.level.levelgen.structure.templatesystem.loader.ResourceManagerTemplateSource;

/**
 * Structure templates and processor lists (VMC-025c), as a server loads them: the
 * `worldgen/processor_list` registry as vanilla's codec encodes it, and every template the
 * features name (template and fossil features), read from the vanilla data pack through
 * vanilla's own template source (data fixed to the current version) and listed as
 * `StructureTemplate` holds it after loading.
 *
 * Usage: StructureTemplateOracle TEMPLATES.json PROCESSOR_LISTS.json. Templates: per id its
 * size, its palettes (each block as [x, y, z, state id] in the loaded order: full blocks,
 * then other blocks, then block entities, each sorted by y, x, z; a block entity's NBT as a
 * fifth SNBT element) and its entity count; and per block state that a rotation or mirror
 * changes (VMC-025f: structure pieces orient any state), its rotations (clockwise 90, 180,
 * counterclockwise 90) and mirrors (left-right, front-back).
 */
public class StructureTemplateOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
    var lists = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.PROCESSOR_LIST).listElements().forEach(holder ->
        lists.put(holder.key().identifier().toString(), StructureProcessorType.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow()));

    // The templates the features name: every feature's codec encoding, inline features included.
    var ids = new TreeSet<String>();
    lookup.lookupOrThrow(Registries.FEATURE).listElements().forEach(holder ->
        collect(Feature.DIRECT_CODEC.encodeStart(ops, holder.value()).getOrThrow(), ids));

    var templates = new JsonObject();
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
        List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var source = new ResourceManagerTemplateSource(DataFixers.getDataFixer(), lookup.lookupOrThrow(Registries.BLOCK), resources,
          new net.minecraft.resources.FileToIdConverter("structure", ".nbt"));
      var palettesField = StructureTemplate.class.getDeclaredField("palettes");
      palettesField.setAccessible(true);
      var entitiesField = StructureTemplate.class.getDeclaredField("entityInfoList");
      entitiesField.setAccessible(true);
      for (var id : ids) {
        var template = source.load(Identifier.parse(id)).orElseThrow(() -> new IllegalStateException("no template " + id));
        var entry = new JsonObject();
        var size = new JsonArray();
        size.add(template.getSize().getX());
        size.add(template.getSize().getY());
        size.add(template.getSize().getZ());
        entry.add("size", size);
        var palettes = new JsonArray();
        for (var palette : (List<StructureTemplate.Palette>) palettesField.get(template)) {
          var blocks = new JsonArray();
          for (var info : palette.blocks()) {
            var row = new JsonArray();
            row.add(info.pos().getX());
            row.add(info.pos().getY());
            row.add(info.pos().getZ());
            int state = Block.getId(info.state());
            row.add(state);
            if (info.nbt() != null) row.add(info.nbt().toString());
            blocks.add(row);
          }
          palettes.add(blocks);
        }
        entry.add("palettes", palettes);
        entry.addProperty("entities", ((List<?>) entitiesField.get(template)).size());
        templates.add(id, entry);
      }
    }
    // Every block state that a rotation or mirror changes (structure pieces orient any state);
    // the others are their own transforms.
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
    out.add("templates", templates);
    out.add("transforms", transforms);
    Files.writeString(Path.of(args[0]), new GsonBuilder().create().toJson(out) + "\n");
    var listsOut = new JsonObject();
    lists.forEach((k, v) -> listsOut.add(k, WorldgenFactsOracle.widenFloats(v)));
    Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(listsOut) + "\n");
    System.out.println("PASS: " + templates.size() + " structure templates (" + transforms.size() + " states that rotate or mirror), "
        + lists.size() + " processor lists");
  }



  /** Template ids in a feature's encoding: template features' templates, fossil structures. */
  static void collect(JsonElement element, Set<String> ids) {
    if (element.isJsonArray()) {
      element.getAsJsonArray().forEach(e -> collect(e, ids));
      return;
    }
    if (!element.isJsonObject()) return;
    var object = element.getAsJsonObject();
    var type = object.has("type") && object.get("type").isJsonPrimitive() ? object.get("type").getAsString() : "";
    if (type.equals("minecraft:template")) {
      for (var t : object.getAsJsonArray("templates")) ids.add(t.getAsJsonObject().getAsJsonObject("data").get("id").getAsString());
    } else if (type.equals("minecraft:fossil")) {
      for (var key : List.of("fossil_structures", "overlay_structures")) {
        for (var t : object.getAsJsonArray(key)) ids.add(t.getAsString());
      }
    }
    object.entrySet().forEach(e -> collect(e.getValue(), ids));
  }
}
