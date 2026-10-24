import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.memory.MemoryModuleType;
import net.minecraft.world.entity.animal.axolotl.Axolotl;
import net.minecraft.world.entity.animal.fish.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.CustomData;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.util.Prediction;

/** Original probe of native bucket data and components, without starting a server. */
public class BucketMobOracle {
  static final List<String> TYPES = List.of("cod", "salmon", "pufferfish", "tropical_fish", "axolotl");
  static RegistryAccess registries;
  static MobAiOracle.Probe level;

  static String encode(ItemStack stack) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      ItemStack.OPTIONAL_STREAM_CODEC.encode(buf, stack);
      byte[] bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes);
      return HexFormat.of().formatHex(bytes);
    } finally { buf.release(); }
  }

  static Mob mob(String type) { return MobAiOracle.mob("minecraft:" + type, level); }

  static JsonArray enumRows(Enum<?>[] values) {
    var out = new JsonArray();
    for (var value : values) {
      var row = new JsonArray(); row.add(value.ordinal());
      row.add(((net.minecraft.util.StringRepresentable)value).getSerializedName()); out.add(row);
    }
    return out;
  }

  static String data(ItemStack stack) {
    var tag = ItemStack.CODEC.encodeStart(registries.createSerializationContext(net.minecraft.nbt.NbtOps.INSTANCE), stack).getOrThrow();
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      buf.writeNbt(tag); byte[] bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes);
      return HexFormat.of().formatHex(bytes);
    } finally { buf.release(); }
  }

  static JsonObject facts() throws Exception {
    var out = new JsonObject(); out.addProperty("version", "26.3");
    var types = new JsonObject();
    for (String type : TYPES) {
      var bucket = (Bucketable)mob(type);
      var row = new JsonObject();
      row.addProperty("item", BuiltInRegistries.ITEM.getKey(bucket.getBucketItemStack().getItem()).toString());
      row.addProperty("pickup_sound", bucket.getPickupSound().location().toString());
      types.add("minecraft:" + type, row);
    }
    out.add("types", types);
    var patterns = new JsonArray();
    for (var pattern : TropicalFish.Pattern.values()) {
      var fish = (TropicalFish)mob("tropical_fish");
      fish.setComponent(DataComponents.TROPICAL_FISH_PATTERN, pattern);
      fish.setComponent(DataComponents.TROPICAL_FISH_BASE_COLOR, DyeColor.WHITE);
      fish.setComponent(DataComponents.TROPICAL_FISH_PATTERN_COLOR, DyeColor.WHITE);
      var packed = TropicalFish.class.getDeclaredMethod("getPackedVariant"); packed.setAccessible(true);
      var row = new JsonArray(); row.add((Integer)packed.invoke(fish)); row.add(pattern.getSerializedName());
      patterns.add(row);
    }
    var enums = new JsonObject(); enums.add("fish_pattern", patterns);
    enums.add("salmon_size", enumRows(Salmon.Variant.values()));
    enums.add("axolotl_variant", enumRows(Axolotl.Variant.values()));
    enums.add("dye_color", enumRows(DyeColor.values())); out.add("enums", enums);
    var components = new JsonObject();
    components.addProperty(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(DataComponents.SALMON_SIZE).toString(), "salmon_size");
    components.addProperty(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(DataComponents.AXOLOTL_VARIANT).toString(), "axolotl_variant");
    components.addProperty(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(DataComponents.TROPICAL_FISH_PATTERN).toString(), "fish_pattern");
    components.addProperty(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(DataComponents.TROPICAL_FISH_BASE_COLOR).toString(), "dye_color");
    components.addProperty(BuiltInRegistries.DATA_COMPONENT_TYPE.getKey(DataComponents.TROPICAL_FISH_PATTERN_COLOR).toString(), "dye_color");
    out.add("components", components); return out;
  }

  static JsonObject scene(String type, int variant, int color, int profile) throws Exception {
    var m = mob(type); var input = new JsonObject();
    input.addProperty("type", "minecraft:" + type); input.addProperty("profile", profile);
    input.addProperty("variant", variant); input.addProperty("color", color);
    if (m instanceof Salmon) m.setComponent(DataComponents.SALMON_SIZE, Salmon.Variant.values()[variant]);
    if (m instanceof TropicalFish) {
      m.setComponent(DataComponents.TROPICAL_FISH_PATTERN, TropicalFish.Pattern.values()[variant]);
      m.setComponent(DataComponents.TROPICAL_FISH_BASE_COLOR, DyeColor.byId(color));
      m.setComponent(DataComponents.TROPICAL_FISH_PATTERN_COLOR, DyeColor.byId((color + 5) % 16));
      var packed = TropicalFish.class.getDeclaredMethod("getPackedVariant"); packed.setAccessible(true);
      input.addProperty("packed", (Integer)packed.invoke(m));
    }
    if (m instanceof Axolotl a) {
      m.setComponent(DataComponents.AXOLOTL_VARIANT, Axolotl.Variant.values()[variant]);
      a.setAge(profile == 1 ? -1200 : profile == 2 ? 6000 : 0);
      var lock = AgeableMob.class.getDeclaredMethod("setAgeLocked", boolean.class); lock.setAccessible(true);
      lock.invoke(a, profile == 1);
      if (profile == 1) a.getBrain().setMemoryWithExpiry(MemoryModuleType.HAS_HUNTING_COOLDOWN, true, 1234);
    }
    if (profile == 1) {
      m.setNoAi(true); m.setNoGravity(true); m.setPersistenceRequired();
      m.setCustomName(Component.literal("Bucket friend")); m.setHealth(1.25F);
    }
    if (profile == 2) m.setHealth(m.getMaxHealth() / 2);
    if (profile == 2) ((Bucketable)m).setFromBucket(true);
    if (profile == 1 && m instanceof Pufferfish p) p.setPuffState(2);
    input.addProperty("health", m.getHealth());
    var bucketable = (Bucketable)m; var stack = bucketable.getBucketItemStack();
    bucketable.saveToBucketTag(stack);
    var out = new JsonObject(); out.add("input", input); out.addProperty("captured", encode(stack));
    out.addProperty("data", data(stack));
    var released = mob(type); released.applyComponentsFromItemStack(stack);
    var restored = (Bucketable)released;
    restored.loadFromBucketTag(stack.getOrDefault(DataComponents.BUCKET_ENTITY_DATA, CustomData.EMPTY).copyTag());
    restored.setFromBucket(true);
    var again = restored.getBucketItemStack(); restored.saveToBucketTag(again);
    out.addProperty("released", encode(again)); out.addProperty("from_bucket", restored.fromBucket());
    out.addProperty("persistent", released.isPersistenceRequired());
    if (released instanceof Pufferfish p) out.addProperty("puff", p.getPuffState());
    // The native pickup contract accepts a live mob and exactly a water bucket.
    out.addProperty("water", bucketable.canBePickedUpWithBucket(new ItemStack(Items.WATER_BUCKET)));
    out.addProperty("empty", bucketable.canBePickedUpWithBucket(new ItemStack(Items.BUCKET)));
    return out;
  }

  static class BucketPlayer extends MobAiOracle.Fighter {
    final List<ItemStack> dropped = new ArrayList<>();
    BucketPlayer(boolean creative) {
      super(level, 77, creative ? net.minecraft.world.level.GameType.CREATIVE : net.minecraft.world.level.GameType.SURVIVAL);
      getAbilities().instabuild = creative;
    }
    public ItemEntity drop(ItemStack stack, boolean random, Prediction prediction) {
      dropped.add(stack.copy()); return null;
    }
  }

  static JsonArray inventory(BucketPlayer player) {
    var out = new JsonArray();
    for (int slot = 0; slot <= 40; slot++) {
      var row = new JsonArray(); row.add(slot); row.add(encode(player.getInventory().getItem(slot))); out.add(row);
    }
    return out;
  }

  static JsonArray inventories() {
    var out = new JsonArray();
    var animal = (Bucketable)mob("cod"); var captured = animal.getBucketItemStack(); animal.saveToBucketTag(captured);
    for (boolean creative : new boolean[]{false, true}) for (boolean off : new boolean[]{false, true})
      for (boolean full : new boolean[]{false, true}) for (boolean duplicate : new boolean[]{false, true}) {
        var player = new BucketPlayer(creative); var inv = player.getInventory();
        if (full) for (int i = 0; i < 36; i++) inv.setItem(i, new ItemStack(Items.STONE, 64));
        if (duplicate) inv.setItem(1, captured.copy());
        var hand = off ? net.minecraft.world.InteractionHand.OFF_HAND : net.minecraft.world.InteractionHand.MAIN_HAND;
        player.setItemInHand(hand, new ItemStack(Items.WATER_BUCKET));
        var row = new JsonObject(); row.addProperty("creative", creative); row.addProperty("off", off);
        row.add("before", inventory(player)); row.addProperty("captured", encode(captured));
        player.setItemInHand(hand, ItemUtils.createFilledResult(player.getItemInHand(hand), player, captured.copy(), false));
        row.add("after", inventory(player)); var drops = new JsonArray();
        player.dropped.forEach(stack -> drops.add(encode(stack))); row.add("drops", drops); out.add(row);
      }
    return out;
  }

  static JsonArray positions() throws Exception {
    var out = new JsonArray(); var at = new BlockPos(0, 64, 0);
    var blocks = List.of(net.minecraft.world.level.block.Blocks.AIR.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.STONE.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.WATER.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.OAK_SLAB.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.OAK_SLAB.defaultBlockState().setValue(
          net.minecraft.world.level.block.SlabBlock.TYPE, net.minecraft.world.level.block.state.properties.SlabType.TOP),
        net.minecraft.world.level.block.Blocks.OAK_STAIRS.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.OAK_FENCE.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.OAK_TRAPDOOR.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.CHEST.defaultBlockState(),
        net.minecraft.world.level.block.Blocks.SNOW.defaultBlockState().setValue(
          net.minecraft.world.level.block.SnowLayerBlock.LAYERS, 4));
    var method = EntityType.class.getDeclaredMethod("getYOffset", net.minecraft.world.level.LevelReader.class,
        BlockPos.class, boolean.class, net.minecraft.world.phys.AABB.class); method.setAccessible(true);
    for (String type : TYPES) for (var block : blocks) {
      level.blocks.clear(); level.blocks.put(at, block);
      var m = mob(type); m.setPos(.5, 65, .5);
      double offset = (Double)method.invoke(null, level, at, false, m.getBoundingBox());
      if (block.is(net.minecraft.world.level.block.Blocks.STONE) && offset != 1)
        throw new AssertionError("Probe must expose solid collision shapes");
      var row = new JsonObject(); row.addProperty("type", "minecraft:" + type);
      row.addProperty("state", net.minecraft.world.level.block.Block.getId(block)); row.addProperty("offset", offset);
      out.add(row);
    }
    level.blocks.clear(); return out;
  }

  @SuppressWarnings({"unchecked", "rawtypes"})
  static JsonArray spawns() throws Exception {
    var out = new JsonArray();
    var seedField = MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class, "seed");
    var at = new BlockPos(0, 64, 0);
    level.blocks.clear(); level.blocks.put(at, net.minecraft.world.level.block.Blocks.WATER.defaultBlockState());
    for (String type : TYPES) for (int profile = 0; profile < 3; profile++) for (long seed : new long[]{0, 1, 42, -7}) {
      var original = scene(type, 0, 0, profile);
      var buf = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(original.get("captured").getAsString())), registries);
      ItemStack stack;
      try { stack = ItemStack.OPTIONAL_STREAM_CODEC.decode(buf); } finally { buf.release(); }
      EntityType factory = mob(type).getType();
      level.getRandom().setSeed(seed);
      var made = (Mob)factory.create(level, EntityType.createDefaultStackConfig(level, stack, null), at,
          EntitySpawnReason.BUCKET, true, false);
      var bucketable = (Bucketable)made;
      bucketable.loadFromBucketTag(stack.getOrDefault(DataComponents.BUCKET_ENTITY_DATA, CustomData.EMPTY).copyTag());
      bucketable.setFromBucket(true);
      var recaptured = bucketable.getBucketItemStack(); bucketable.saveToBucketTag(recaptured);
      var row = new JsonObject(); row.addProperty("seed", seed); row.addProperty("bucket", encode(stack));
      row.addProperty("yaw", Float.floatToRawIntBits(made.getYRot()));
      row.addProperty("level_after", ((java.util.concurrent.atomic.AtomicLong)seedField.get(level.getRandom())).get());
      row.addProperty("recaptured", encode(recaptured)); out.add(row);
    }
    level.blocks.clear(); return out;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    var entries = new ArrayList<Registry<?>>();
    var damage = MobAiOracle.registry(Registries.DAMAGE_TYPE, lookup); entries.add(damage);
    BuiltInRegistries.REGISTRY.forEach(entries::add);
    registries = new RegistryAccess.ImmutableRegistryAccess(entries).freeze();
    level = MobAiOracle.probe(lookup, registries, new net.minecraft.world.damagesource.DamageSources(registries));
    JsonElement result;
    if (args[0].equals("facts")) result = facts();
    else if (args[0].equals("inventory")) result = inventories();
    else if (args[0].equals("positions")) result = positions();
    else if (args[0].equals("spawns")) result = spawns();
    else {
      var cases = new JsonArray();
      for (String type : TYPES) {
        int variants = type.equals("salmon") ? 3 : type.equals("axolotl") ? 5 : type.equals("tropical_fish") ? 12 : 1;
        int colors = type.equals("tropical_fish") ? 16 : 1;
        for (int v = 0; v < variants; v++) for (int c = 0; c < colors; c++)
          for (int p = 0; p < 3; p++) cases.add(scene(type, v, c, p));
      }
      result = cases;
    }
    Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().disableHtmlEscaping().create().toJson(result) + "\n");
    System.out.println("PASS: native bucket " + args[0]);
  }
}
