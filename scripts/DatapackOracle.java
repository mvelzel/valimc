import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.resources.Identifier;

/**
 * A sample worldgen data pack (VMC-028c), written at run time from the vanilla pack's own JSON so
 * that nothing of it is kept in the tree.
 *
 * <p>`make PACK`: a pack folder whose overworld noise settings have sea level 70 instead of 63 (the
 * aquifers' and every feature's sea level) and whose plains biome also places
 * `minecraft:ore_emerald` among its underground ores (a placed feature plains does not have, so
 * the feature order changes). Its format is the pinned server's.
 */
public class DatapackOracle {
  public static void main(String[] args) throws Exception {
    if (!args[0].equals("make")) throw new IllegalArgumentException("usage: DatapackOracle make PACK");
    var pack = Path.of(args[1]);
    MiningToolOracle.initialize();
    var gson = new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create();
    int format = net.minecraft.SharedConstants.getCurrentVersion().packVersion(net.minecraft.server.packs.PackType.SERVER_DATA).major();
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(
        net.minecraft.server.packs.PackType.SERVER_DATA, WorldgenFactsOracle.packResources(List.of()))) {
      var settings = read(resources, "worldgen/noise_settings/overworld.json");
      settings.addProperty("sea_level", 70);
      write(pack, "worldgen/noise_settings/overworld.json", settings, gson);

      var plains = read(resources, "worldgen/biome/plains.json");
      var steps = plains.getAsJsonArray("features");
      // The underground ores step (`GenerationStep.Decoration.UNDERGROUND_ORES`).
      var ores = steps.get(6).getAsJsonArray();
      ores.add("minecraft:ore_emerald");
      write(pack, "worldgen/biome/plains.json", plains, gson);
    }
    var meta = new JsonObject();
    var info = new JsonObject();
    info.addProperty("description", "ValiMC sample worldgen pack");
    info.addProperty("min_format", format);
    info.addProperty("max_format", format);
    meta.add("pack", info);
    Files.createDirectories(pack);
    Files.writeString(pack.resolve("pack.mcmeta"), gson.toJson(meta) + "\n");
    System.out.println("PASS: sample worldgen pack (pack format " + format + ") in " + pack);
  }

  static JsonObject read(net.minecraft.server.packs.resources.ResourceManager resources, String path) throws Exception {
    var resource = resources.getResource(Identifier.withDefaultNamespace(path)).orElseThrow();
    try (var reader = resource.openAsReader()) {
      return JsonParser.parseReader(reader).getAsJsonObject();
    }
  }

  static void write(Path pack, String path, JsonObject json, Gson gson) throws Exception {
    var file = pack.resolve("data/minecraft/" + path);
    Files.createDirectories(file.getParent());
    Files.writeString(file, gson.toJson(json) + "\n");
  }
}
