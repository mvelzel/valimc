import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponentType;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.util.RandomSource;
import net.minecraft.util.Unit;
import net.minecraft.world.RandomSequences;
import net.minecraft.world.entity.npc.villager.Villager;
import net.minecraft.world.entity.npc.villager.VillagerProfession;
import net.minecraft.world.entity.npc.villager.VillagerType;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.DyeColor;
import net.minecraft.world.item.trading.*;
import net.minecraft.world.level.levelgen.structure.Structure;
import net.minecraft.world.level.saveddata.maps.MapId;
import net.minecraft.world.level.saveddata.maps.MapItemSavedData;
import net.minecraft.world.level.storage.loot.*;
import net.minecraft.world.level.storage.loot.parameters.*;
import net.minecraft.world.phys.Vec3;

/**
 * Trades (VMC-044b1). `facts OUT` writes the data pack's trades as the
 * evaluator reads them: every `villager_trade` through its codec, every
 * `trade_set` with its trades in holder-set order, each profession's set by
 * level, the wandering trader's sets in the order it draws them, the potion
 * tags trades name and the dye colours (`DyeColor.VALUES`). `cases OUT`
 * draws offers as `AbstractVillager.addOffersFromTradeSet` does, from the
 * server's `RandomSequences` of several world seeds: per seed, merchants
 * one after another (every profession and villager type through its five
 * levels, then wandering traders) share the sequences, so each draw starts
 * where the one before left its set's sequence.
 */
public class TradeOracle {
  static final List<Long> SEEDS = List.of(0L, 12345L, -987654321L, 31337L);
  static final Vec3 ORIGIN = new Vec3(8.5, 64.0, -3.5);

  static class ProbeServer extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    RandomSequences sequences;
    long seed;
    private ProbeServer() { super(null, null, null, null, Optional.empty(), null, null, null, null, null); }
    @Override public ReloadableServerRegistries.Holder reloadableRegistries() { return registries; }
    @Override public RandomSource getRandomSequence(Identifier id) { return sequences.get(id, seed); }
  }

  static class ProbeLevel extends ServerLevel {
    ProbeServer server;
    RegistryAccess access;
    BlockPos destination;
    int nextMap;
    Map<MapId, MapItemSavedData> maps;
    private ProbeLevel() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    @Override public MinecraftServer getServer() { return server; }
    @Override public RegistryAccess registryAccess() { return access; }
    @Override public FeatureFlagSet enabledFeatures() { return FeatureFlags.DEFAULT_FLAGS; }
    // A found map renders its biome preview (into the map's data, not the item).
    @Override public int getSeaLevel() { return 63; }
    @Override public Holder<net.minecraft.world.level.biome.Biome> getBiome(BlockPos pos) {
      return access.lookupOrThrow(Registries.BIOME).getOrThrow(net.minecraft.world.level.biome.Biomes.PLAINS);
    }
    @Override public net.minecraft.world.level.StructureManager structureManager() {
      // Claiming a structure at the merchant finds none.
      return new net.minecraft.world.level.StructureManager(this, null, null) {
        @Override public net.minecraft.world.level.levelgen.structure.StructureStart getStructureAt(BlockPos pos, HolderSet<Structure> structures) {
          return net.minecraft.world.level.levelgen.structure.StructureStart.INVALID_START;
        }
      };
    }
    @Override public BlockPos findNearestMapStructure(HolderSet<Structure> structures, BlockPos origin, int radius, boolean createReference) {
      return destination;
    }
    @Override public MapId getFreeMapId() { return new MapId(nextMap++); }
    @Override public MapItemSavedData getMapData(MapId id) { return maps.get(id); }
    @Override public void setMapData(MapId id, MapItemSavedData data) { maps.put(id, data); }
  }

  /** The merchant a trade's predicate reads: its villager type. */
  static class Merchant extends Villager {
    Holder<VillagerType> variant;
    private Merchant() { super(null, null); }
    @SuppressWarnings("unchecked")
    @Override public <T> T get(DataComponentType<? extends T> type) {
      return type == DataComponents.VILLAGER_VARIANT ? (T)variant : null;
    }
  }

  static String name(Holder<?> holder) { return holder.unwrapKey().orElseThrow().identifier().toString(); }

  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) unsafeField.get(null);
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA, List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      // As `WorldLoader` loads them (LootOracle): static tags, world registries, reloadable ones.
      var layered = RegistryLayer.createRegistryAccess();
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, layered.getLayer(RegistryLayer.STATIC));
      var context = net.minecraft.tags.TagLoader.buildUpdatedLookups(layered.getAccessForLoading(RegistryLayer.WORLD), pending);
      var world = net.minecraft.resources.RegistryDataLoader.load(resources, context,
          net.minecraft.resources.RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      pending.forEach(Registry.PendingTags::apply);
      var worldContext = Stream.concat(context.stream(), world.listRegistries()).toList();
      var reloadable = net.minecraft.resources.RegistryDataLoader.load(resources, worldContext,
          net.minecraft.resources.RegistryDataLoader.RELOADABLE_REGISTRIES, Runnable::run).join();
      var lookup = HolderLookup.Provider.create(Stream.concat(worldContext.stream(), reloadable.listRegistries()));
      BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
      var access = new RegistryAccess.ImmutableRegistryAccess(Stream.concat(
          Stream.of(BuiltInRegistries.REGISTRY).flatMap(r -> r.stream().map(x -> (Registry<?>) x)),
          Stream.concat(world.registries().map(e -> e.value()), reloadable.registries().map(e -> e.value()))).toList())
          .freeze();
      var ops = lookup.createSerializationContext(JsonOps.INSTANCE);
      var server = (ProbeServer) unsafe.allocateInstance(ProbeServer.class);
      server.registries = new ReloadableServerRegistries.Holder(lookup);
      var level = (ProbeLevel) unsafe.allocateInstance(ProbeLevel.class);
      level.server = server;
      level.access = access;
      level.maps = new HashMap<>();
      var out = args[0].equals("facts") ? facts(access, ops) : cases(access, ops, server, level, unsafe);
      Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create().toJson(out) + "\n");
    }
  }

  static JsonObject facts(RegistryAccess access, com.mojang.serialization.DynamicOps<JsonElement> ops) {
    var out = new JsonObject();
    out.addProperty("version", "26.3");
    out.addProperty("server_sha1", "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var trades = new JsonObject();
    var tradeRegistry = access.lookupOrThrow(Registries.VILLAGER_TRADE);
    tradeRegistry.listElements().sorted(Comparator.comparing(h -> name(h)))
        .forEach(h -> trades.add(name(h), VillagerTrade.CODEC.encodeStart(ops, h.value()).getOrThrow()));
    out.add("trades", trades);
    var sets = new JsonObject();
    access.lookupOrThrow(Registries.TRADE_SET).listElements().sorted(Comparator.comparing(h -> name(h))).forEach(h -> {
      TradeSet set = h.value();
      var o = new JsonObject();
      o.add("amount", net.minecraft.world.level.storage.loot.providers.number.ints.ContextIntProviders.CODEC
          .encodeStart(ops, set.amount()).getOrThrow());
      o.addProperty("allow_duplicates", set.allowDuplicates());
      o.addProperty("random_sequence", set.randomSequence().map(Identifier::toString).orElse(null));
      var list = new JsonArray();
      for (var t : set.trades()) list.add(name(t));
      o.add("trades", list);
      sets.add(name(h), o);
    });
    out.add("sets", sets);
    var professions = new JsonObject();
    for (var p : BuiltInRegistries.VILLAGER_PROFESSION.listElements().toList()) {
      var levels = new JsonObject();
      for (int l = 1; l <= 5; l++) {
        var key = p.value().getTrades(l);
        if (key != null) levels.addProperty(Integer.toString(l), key.identifier().toString());
      }
      professions.add(name(p), levels);
    }
    out.add("professions", professions);
    var wandering = new JsonArray();
    for (var key : List.of(TradeSets.WANDERING_TRADER_BUYING, TradeSets.WANDERING_TRADER_UNCOMMON, TradeSets.WANDERING_TRADER_COMMON))
      wandering.add(key.identifier().toString());
    out.add("wandering_trader", wandering);
    var potionTags = new JsonObject();
    var potions = access.lookupOrThrow(Registries.POTION);
    potions.listTags().sorted(Comparator.comparing(t -> t.key().location().toString())).forEach(tag -> {
      var members = new JsonArray();
      tag.stream().forEach(h -> members.add(name(h)));
      potionTags.add(tag.key().location().toString(), members);
    });
    var tags = new JsonObject();
    tags.add("minecraft:potion", potionTags);
    out.add("tags", tags);
    var dyes = new JsonArray();
    for (var dye : DyeColor.VALUES) {
      var d = new JsonArray(); d.add(dye.getSerializedName()); d.add(dye.getTextureDiffuseColor()); dyes.add(d);
    }
    out.add("dyes", dyes);
    return out;
  }

  /** The `minecraft:trade_set` keys a merchant draws from, by level (a wandering trader's at level 0). */
  static List<ResourceKey<TradeSet>> setsOf(VillagerProfession profession, int level) {
    if (profession == null)
      return List.of(TradeSets.WANDERING_TRADER_BUYING, TradeSets.WANDERING_TRADER_UNCOMMON, TradeSets.WANDERING_TRADER_COMMON);
    var key = profession.getTrades(level);
    return key == null ? List.of() : List.of(key);
  }

  static JsonObject cases(RegistryAccess access, com.mojang.serialization.DynamicOps<JsonElement> ops, ProbeServer server,
      ProbeLevel level, sun.misc.Unsafe unsafe) throws Exception {
    Method withDuplicates = AbstractVillagerAccess.method("addOffersFromItemListings");
    Method withoutDuplicates = AbstractVillagerAccess.method("addOffersFromItemListingsWithoutDuplicates");
    var setRegistry = access.lookupOrThrow(Registries.TRADE_SET);
    var professions = BuiltInRegistries.VILLAGER_PROFESSION.listElements()
        .filter(p -> p.value().getTrades(1) != null).toList();
    var types = BuiltInRegistries.VILLAGER_TYPE.listElements().toList();
    var cases = new JsonArray();
    for (long seed : SEEDS) {
      server.seed = seed;
      server.sequences = new RandomSequences();
      // The structure a map's search finds, or none for one seed.
      level.destination = seed == 31337L ? null : new BlockPos((int)(seed % 3000), 64, (int)((seed / 7) % 3000));
      level.nextMap = 0;
      var merchants = new ArrayList<Object[]>();
      for (var type : types) for (var p : professions) merchants.add(new Object[]{p, type});
      for (int i = 0; i < 3; i++) merchants.add(new Object[]{null, types.get(0)});
      int index = 0;
      for (var m : merchants) {
        @SuppressWarnings("unchecked") var p = (Holder.Reference<VillagerProfession>)m[0];
        @SuppressWarnings("unchecked") var type = (Holder.Reference<VillagerType>)m[1];
        var merchant = (Merchant) unsafe.allocateInstance(Merchant.class);
        merchant.variant = type;
        var offers = new MerchantOffers();
        for (int l = (p == null ? 0 : 1); l <= (p == null ? 0 : 5); l++) {
          int before = offers.size();
          for (var key : setsOf(p == null ? null : p.value(), l)) {
            TradeSet set = setRegistry.getOrThrow(key).value();
            // `addOffersFromTradeSet`'s context.
            var context = new LootContext.Builder(new LootParams.Builder(level)
                .withParameter(LootContextParams.ORIGIN, ORIGIN)
                .withParameter(LootContextParams.THIS_ENTITY, merchant)
                .withParameter(LootContextParams.ADDITIONAL_COST_COMPONENT_ALLOWED, Unit.INSTANCE)
                .create(LootContextParamSets.VILLAGER_TRADE)).create(set.randomSequence());
            int amount = set.calculateNumberOfTrades(context);
            (set.allowDuplicates() ? withDuplicates : withoutDuplicates).invoke(null, context, offers, set.trades(), amount);
          }
          var row = new JsonObject();
          row.addProperty("seed", Long.toString(seed));
          row.addProperty("merchant", index);
          row.addProperty("profession", p == null ? null : name(p));
          row.addProperty("type", name(type));
          row.addProperty("level", l);
          row.add("destination", level.destination == null ? JsonNull.INSTANCE : pos(level.destination));
          var added = new JsonArray();
          for (int i = before; i < offers.size(); i++) added.add(MerchantOffer.CODEC.encodeStart(ops, offers.get(i)).getOrThrow());
          row.add("offers", added);
          cases.add(row);
        }
        index++;
      }
    }
    var out = new JsonObject();
    out.add("origin", vec(ORIGIN));
    out.add("cases", cases);
    return out;
  }

  static JsonArray pos(BlockPos p) { var a = new JsonArray(); a.add(p.getX()); a.add(p.getY()); a.add(p.getZ()); return a; }
  static JsonArray vec(Vec3 v) { var a = new JsonArray(); a.add(v.x); a.add(v.y); a.add(v.z); return a; }

  /** The static draws `AbstractVillager` keeps to itself. */
  static class AbstractVillagerAccess {
    static Method method(String name) throws Exception {
      for (var m : net.minecraft.world.entity.npc.villager.AbstractVillager.class.getDeclaredMethods())
        if (m.getName().equals(name)) { m.setAccessible(true); return m; }
      throw new NoSuchMethodException(name);
    }
  }
}
