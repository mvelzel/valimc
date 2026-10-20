import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.levelgen.synth.NormalNoise;

/**
 * Worldgen facts (VMC-023): every entry of the `worldgen/noise` registry as
 * vanilla's own codec encodes it (defaults omitted), keyed by identifier.
 */
public class WorldgenFactsOracle {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    var noises = new TreeMap<String, JsonElement>();
    lookup.lookupOrThrow(Registries.NOISE).listElements().forEach(holder ->
        noises.put(holder.key().identifier().toString(),
            NormalNoise.DIRECT_CODEC.encodeStart(JsonOps.INSTANCE, holder.value()).getOrThrow()));
    var out = new JsonObject();
    noises.forEach(out::add);
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(out) + "\n");
    System.out.println("PASS: " + noises.size() + " vanilla noise parameter sets");
  }
}
