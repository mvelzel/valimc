import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.core.HolderLookup;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.tags.TagLoader;

/** Development-only metadata extraction. The Elixir server has no JVM dependency. */
public class ProtocolMetadata {
  @SuppressWarnings({"rawtypes", "unchecked"})
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    Map<String, List<String>> registries = new TreeMap<>();
    for (var data : RegistryDataLoader.SYNCHRONIZED_REGISTRIES) {
      var registry = lookup.lookupOrThrow(data.key());
      List<String> entries = registry.listElementIds().map(k -> k.identifier().toString()).sorted().toList();
      registries.put(data.key().identifier().toString(), entries);
    }
    Files.writeString(Path.of(args[0]), new GsonBuilder().setPrettyPrinting().create().toJson(registries));

    // Known-pack entries are resolved locally by the client, but tags must still
    // arrive over the wire before those entries can be decoded (e.g. enchantments).
    var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(
      net.minecraft.server.packs.PackType.SERVER_DATA,
      List.of(ServerPacksSource.createVanillaPackSource().fullResources()));
    Map<String, Map<String, List<Integer>>> tags = new TreeMap<>();
    Map<String, HolderLookup.RegistryLookup<?>> sources = new TreeMap<>();
    BuiltInRegistries.REGISTRY.stream().forEach(r -> sources.put(r.key().identifier().toString(), r));
    lookup.listRegistryKeys().forEach(key -> sources.put(key.identifier().toString(), lookup.lookupOrThrow(key)));
    for (var source : sources.values()) {
      var key = source.key();
      Map<net.minecraft.tags.TagKey<Object>, List<net.minecraft.core.Holder<Object>>> loaded =
        TagLoader.<Object>loadTagsForRegistry(resources, (ResourceKey) key,
          (id, required) -> (Optional) source.get(ResourceKey.create((ResourceKey) key, id)));
      if (loaded.isEmpty()) continue;
      Map<String, Integer> ids = new HashMap<>();
      var builtin = BuiltInRegistries.REGISTRY.getValue(key.identifier());
      if (builtin != null) {
        for (Object value : builtin) ids.put(((net.minecraft.core.Registry) builtin).getKey(value).toString(), ((net.minecraft.core.Registry) builtin).getId(value));
      } else if (registries.containsKey(key.identifier().toString())) {
        var names = registries.get(key.identifier().toString());
        for (int i = 0; i < names.size(); i++) ids.put(names.get(i), i);
      } else continue; // World-generation registries are not synchronized.
      Map<String, List<Integer>> entries = new TreeMap<>();
      loaded.forEach((tag, holders) -> entries.put(tag.location().toString(), holders.stream()
        .map(h -> Objects.requireNonNull(ids.get(h.unwrapKey().orElseThrow().identifier().toString())))
        .distinct().sorted().toList()));
      tags.put(key.identifier().toString(), entries);
    }
    if (tags.getOrDefault("minecraft:item", Map.of()).isEmpty()) throw new IllegalStateException("No vanilla item tags loaded");
    Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(tags));
    resources.close();
  }
}
