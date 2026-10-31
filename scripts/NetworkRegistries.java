import java.util.*;
import com.mojang.serialization.Lifecycle;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.TagLoader;

/**
 * The registries a client holds after ValiMC's configuration phase: the built-in
 * ones, and every synchronized data-driven registry in identifier order (the order
 * a data pack lists, and `priv/protocol/registries.json` sends), with the vanilla
 * pack's tags bound. Holders from `lookup` keep their identity, so prototype
 * components encode against it.
 */
public final class NetworkRegistries {
  private NetworkRegistries() {}

  public static RegistryAccess.Frozen load(HolderLookup.Provider lookup) throws Exception {
    var all = new ArrayList<Registry<?>>(BuiltInRegistries.REGISTRY.stream().toList());
    for (var data : RegistryDataLoader.SYNCHRONIZED_REGISTRIES) all.add(mapped(lookup, data.key()));
    var access = new RegistryAccess.ImmutableRegistryAccess(all).freeze();
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
        List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      TagLoader.loadTagsForExistingRegistries(resources, access).forEach(Registry.PendingTags::apply);
    }
    return access;
  }

  private static <T> Registry<T> mapped(HolderLookup.Provider lookup, ResourceKey<? extends Registry<T>> key) {
    var registry = new MappedRegistry<T>(key, Lifecycle.stable());
    lookup.lookupOrThrow(key).listElements()
      .sorted(Comparator.comparing(h -> h.key().identifier().toString()))
      .forEach(h -> registry.register(h.key(), h.value(), RegistrationInfo.BUILT_IN));
    registry.bindAllTagsToEmpty();
    return registry.freeze();
  }
}
