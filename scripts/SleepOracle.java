import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.network.chat.*;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.players.SleepStatus;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.attribute.BedRule;
import net.minecraft.world.attribute.EnvironmentAttributeSystem;
import net.minecraft.world.attribute.EnvironmentAttributes;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.monster.Monster;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BedPart;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.storage.LevelData;
import net.minecraft.world.phys.*;

/**
 * Vanilla's beds, sleep and respawn points (VMC-040a).
 *
 * `facts OUT`: what sleeping and respawning read beyond the block facts: each
 * dimension type's bed rules (`gameplay/bed_rule`, `gameplay/straw_bed_rule`),
 * whether respawn anchors work there and whether its time is fixed (no biome
 * changes them, which this checks); each bed block's rule and sleep heights;
 * the entity types that keep a player from resting (`Monster`s, and those
 * that only do when angry); and per block state, as hex bytes, the
 * `DismountHelper` inputs: whether it suffocates (`Player.freeAt`), is
 * dangerous to a player, is `invalid_spawn_inside`, and the top of its
 * non-climbable collision shape (`nonClimbableShape`, an index into
 * `floors`, 0 for an empty shape).
 *
 * `fixtures OUT`: over seeded scenes of a probe level, the stand-up position
 * of `AbstractBedBlock.findStandUpPosition` (beds, straw beds, bunk beds) for
 * several yaws and of `RespawnAnchorBlock.findStandUpPosition`;
 * `ServerPlayer.findRespawnAndUseSpawnBlock` for beds, anchors of every
 * charge and missing blocks in each dimension, with the look-at yaw and the
 * anchor's charge after; `bedInRange` and `bedBlocked`; `SleepStatus` over
 * player counts and percentages; and the packets: the wake-up animation, the
 * sleeping position's entity data, the missing-respawn-block game event and
 * the bad respawn point's death message.
 */
public class SleepOracle {
  static sun.misc.Unsafe unsafe;
  static RegistryAccess registries;
  static final int REACH = 4, LOW = -2, HIGH = 3;

  static Field field(Class<?> c, String n) throws Exception { var f = c.getDeclaredField(n); f.setAccessible(true); return f; }
  static String bits(double d) { return HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d)); }
  static JsonArray cell(BlockPos p) { var a = new JsonArray(); a.add(p.getX()); a.add(p.getY()); a.add(p.getZ()); return a; }
  static JsonElement vec(Vec3 v) {
    if (v == null) return JsonNull.INSTANCE;
    var a = new JsonArray(); a.add(bits(v.x)); a.add(bits(v.y)); a.add(bits(v.z)); return a;
  }

  // ---------------------------------------------------------------- probe

  static class Probe extends ServerLevel {
    Map<BlockPos, BlockState> blocks; EnvironmentAttributeSystem env; WorldBorder border;
    Holder<DimensionType> type; ResourceKey<Level> key;
    private Probe() { super(null, null, null, null, null, null, false, 0L, List.of(), false); }
    public BlockState getBlockState(BlockPos p) { return blocks.getOrDefault(p, Blocks.AIR.defaultBlockState()); }
    public FluidState getFluidState(BlockPos p) { return getBlockState(p).getFluidState(); }
    public BlockGetter getChunkForCollisions(int x, int z) { return this; }
    public boolean setBlock(BlockPos p, BlockState s, int flags, int depth) { blocks.put(p.immutable(), s); return true; }
    public int getMinY() { return -64; }
    public int getHeight() { return 384; }
    public boolean isLoaded(BlockPos p) { return true; }
    public WorldBorder getWorldBorder() { return border; }
    public EnvironmentAttributeSystem environmentAttributes() { return env; }
    public DimensionType dimensionType() { return type.value(); }
    public Holder<DimensionType> dimensionTypeRegistration() { return type; }
    public ResourceKey<Level> dimension() { return key; }
    public RegistryAccess registryAccess() { return registries; }
  }

  static Probe probe(String dimension, Map<BlockPos, BlockState> blocks) throws Exception {
    var level = (Probe) unsafe.allocateInstance(Probe.class);
    level.blocks = new HashMap<>(blocks);
    level.border = new WorldBorder();
    level.type = registries.lookupOrThrow(Registries.DIMENSION_TYPE)
      .getOrThrow(ResourceKey.create(Registries.DIMENSION_TYPE, Identifier.parse(dimension)));
    level.key = ResourceKey.create(Registries.DIMENSION, Identifier.parse(dimension));
    level.env = EnvironmentAttributeSystem.builder().addConstantLayer(level.type.value().attributes()).build();
    return level;
  }

  // ---------------------------------------------------------------- facts

  static JsonObject rule(BedRule r) {
    var o = new JsonObject();
    o.addProperty("can_sleep", r.canSleep().getSerializedName());
    o.addProperty("can_set_spawn", r.canSetSpawn().getSerializedName());
    o.addProperty("destroy_on_use", r.destroyOnUse());
    o.addProperty("destroy_on_leave", r.destroyOnLeave());
    r.errorMessage().ifPresent(m -> o.addProperty("error", ((net.minecraft.network.chat.contents.TranslatableContents) m.getContents()).getKey()));
    return o;
  }

  static String hex(byte[] bytes) { return HexFormat.of().formatHex(bytes); }

  static void facts(Path out) throws Exception {
    var facts = new JsonObject();
    facts.addProperty("version", SharedConstants.getCurrentVersion().id());
    facts.addProperty("server_sha1", VersionMetadata.serverSha1());

    var dimensions = new JsonObject();
    var attributes = List.of(EnvironmentAttributes.BED_RULE, EnvironmentAttributes.STRAW_BED_RULE);
    for (var holder : registries.lookupOrThrow(Registries.DIMENSION_TYPE).listElements().sorted(Comparator.comparing(h -> h.key().identifier().toString())).toList()) {
      var env = EnvironmentAttributeSystem.builder().addConstantLayer(holder.value().attributes()).build();
      var d = new JsonObject();
      d.add("bed_rule", rule(env.getDimensionValue(EnvironmentAttributes.BED_RULE)));
      d.add("straw_bed_rule", rule(env.getDimensionValue(EnvironmentAttributes.STRAW_BED_RULE)));
      d.addProperty("respawn_anchor_works", env.getDimensionValue(EnvironmentAttributes.RESPAWN_ANCHOR_WORKS));
      d.addProperty("fixed_time", holder.value().hasFixedTime());
      dimensions.add(holder.key().identifier().toString(), d);
    }
    facts.add("dimensions", dimensions);
    // No biome changes a bed rule or the anchors: the dimension decides.
    for (var biome : registries.lookupOrThrow(Registries.BIOME).listElements().toList()) {
      var a = biome.value().getAttributes();
      for (var attribute : attributes)
        if (a.contains(attribute)) throw new IllegalStateException("biome sets a bed rule: " + biome.key());
      if (a.contains(EnvironmentAttributes.RESPAWN_ANCHOR_WORKS)) throw new IllegalStateException("biome sets anchors: " + biome.key());
    }

    var beds = new JsonObject();
    var empty = probe("minecraft:overworld", Map.of());
    for (var block : BuiltInRegistries.BLOCK) {
      if (!(block instanceof AbstractBedBlock bed)) continue;
      var o = new JsonObject();
      var m = AbstractBedBlock.class.getDeclaredMethod("getBedEnvironmentAttribute"); m.setAccessible(true);
      o.addProperty("rule", m.invoke(bed) == EnvironmentAttributes.BED_RULE ? "bed_rule" : "straw_bed_rule");
      o.addProperty("explodes", bed instanceof BedBlock);
      var foot = block.defaultBlockState().setValue(AbstractBedBlock.PART, BedPart.FOOT).setValue(HorizontalDirectionalBlock.FACING, Direction.NORTH);
      var head = foot.setValue(AbstractBedBlock.PART, BedPart.HEAD);
      var at = new BlockPos(0, 64, 0);
      empty.blocks.clear(); empty.blocks.put(at, foot); empty.blocks.put(at.north(), head);
      o.addProperty("foot_height", bed.getSleepHeight(foot, empty, at).orElseThrow());
      o.addProperty("head_height", bed.getSleepHeight(head, empty, at.north()).orElseThrow());
      // A straw bed's head sleeps at its foot's height and needs the foot.
      empty.blocks.remove(at);
      o.addProperty("head_needs_foot", bed.getSleepHeight(head, empty, at.north()).isEmpty());
      beds.add(BuiltInRegistries.BLOCK.getKey(block).toString(), o);
    }
    facts.add("beds", beds);

    // Rest: create every type in a probe and ask what it is.
    NaturalSpawnOracle.unsafe = unsafe; NaturalSpawnOracle.registries = registries;
    var spawnLevel = NaturalSpawnOracle.probe(new NaturalSpawnOracle.Scene("rest", "minecraft:overworld", "minecraft:plains"));
    // A wither names its boss bar from the scoreboard.
    var server = spawnLevel.server;
    unsafe.putObject(spawnLevel, unsafe.objectFieldOffset(ServerLevel.class.getDeclaredField("server")), server);
    unsafe.putObject(server, unsafe.objectFieldOffset(net.minecraft.server.MinecraftServer.class.getDeclaredField("scoreboard")),
      new net.minecraft.server.ServerScoreboard(server));
    var monsters = new JsonArray(); var angry = new JsonArray();
    for (var type : BuiltInRegistries.ENTITY_TYPE) {
      if (type == EntityTypes.PLAYER) continue;
      Entity entity;
      try { entity = type.create(spawnLevel, EntitySpawnReason.COMMAND); } catch (Throwable t) { System.err.println(type + ": " + t); t.printStackTrace(); entity = null; }
      if (entity == null) {
        if (type.getCategory() == MobCategory.MONSTER) throw new IllegalStateException("cannot create " + type);
        continue;
      }
      if (!(entity instanceof Monster)) continue;
      var id = BuiltInRegistries.ENTITY_TYPE.getKey(type).toString();
      var declared = entity.getClass().getMethod("isPreventingPlayerRest", ServerLevel.class, Player.class).getDeclaringClass();
      if (declared == Monster.class) monsters.add(id);
      else if (declared == net.minecraft.world.entity.monster.zombie.ZombifiedPiglin.class) angry.add(id);
      else throw new IllegalStateException("unknown rest rule " + declared);
    }
    facts.add("rest_preventing", monsters);
    facts.add("rest_preventing_when_angry", angry);

    // Per state: flags (1 suffocating, 2 dangerous, 4 invalid inside) and the floor index.
    var floors = new ArrayList<Double>(); floors.add(null);
    var flags = new byte[Block.BLOCK_STATE_REGISTRY.size()]; var floor = new byte[Block.BLOCK_STATE_REGISTRY.size()];
    var origin = new BlockPos(0, 64, 0);
    for (int id = 0; id < flags.length; id++) {
      var state = Block.stateById(id);
      empty.blocks.clear(); empty.blocks.put(origin, state);
      int f = 0;
      if (state.isSuffocating(empty, origin)) f |= 1;
      if (EntityTypes.PLAYER.isBlockDangerous(state)) f |= 2;
      if (state.is(BlockTags.INVALID_SPAWN_INSIDE)) f |= 4;
      flags[id] = (byte) f;
      var shape = net.minecraft.world.entity.vehicle.DismountHelper.nonClimbableShape(empty, origin);
      Double top = shape.isEmpty() ? null : shape.max(Direction.Axis.Y);
      int index = floors.indexOf(top);
      if (index < 0) { index = floors.size(); floors.add(top); }
      if (index > 255) throw new IllegalStateException("too many floors");
      floor[id] = (byte) index;
    }
    var floorList = new JsonArray(); for (var f : floors) { if (f == null) floorList.add(JsonNull.INSTANCE); else floorList.add(f); }
    facts.add("floors", floorList);
    facts.addProperty("flags", hex(flags));
    facts.addProperty("floor_states", hex(floor));
    Files.writeString(out, new GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(facts) + "\n");
  }

  // ---------------------------------------------------------------- scenes

  /** Loaded after the bootstrap. */
  static class Palette {
  static final Block[] FLOORS = {Blocks.STONE, Blocks.STONE, Blocks.STONE, Blocks.STONE, Blocks.DIRT, Blocks.AIR, Blocks.LAVA, Blocks.MAGMA_BLOCK,
    Blocks.WATER, Blocks.SOUL_SAND, Blocks.FARMLAND, Blocks.HONEY_BLOCK, Blocks.CAMPFIRE, Blocks.FIRE, Blocks.OAK_FENCE, Blocks.SCAFFOLDING,
    Blocks.POWDER_SNOW, Blocks.LADDER};
  static final Block[] CELLS = {Blocks.STONE, Blocks.GLASS, Blocks.OAK_SLAB, Blocks.OAK_FENCE, Blocks.CACTUS, Blocks.SWEET_BERRY_BUSH, Blocks.FIRE,
    Blocks.LAVA, Blocks.POWDER_SNOW, Blocks.LADDER, Blocks.OAK_TRAPDOOR, Blocks.SCAFFOLDING, Blocks.SNOW, Blocks.CARPET.white(), Blocks.WATER,
    Blocks.COBWEB, Blocks.WITHER_ROSE, Blocks.END_PORTAL, Blocks.NETHER_PORTAL, Blocks.OAK_LEAVES, Blocks.VINE, Blocks.SHORT_GRASS,
    Blocks.TORCH, Blocks.OAK_STAIRS, Blocks.CHEST, Blocks.SOUL_SAND, Blocks.IRON_BARS, Blocks.OAK_DOOR, Blocks.STONE_PRESSURE_PLATE,
    Blocks.MAGMA_BLOCK, Blocks.BEDROCK};
  }

  static BlockState pick(Random r, Block b) {
    var state = b.defaultBlockState();
    if (b == Blocks.OAK_TRAPDOOR) state = state.setValue(TrapDoorBlock.OPEN, r.nextBoolean());
    if (b == Blocks.OAK_SLAB) state = state.setValue(SlabBlock.TYPE, net.minecraft.world.level.block.state.properties.SlabType.values()[r.nextInt(3)]);
    if (b == Blocks.SNOW) state = state.setValue(SnowLayerBlock.LAYERS, 1 + r.nextInt(8));
    if (b == Blocks.LADDER) state = state.setValue(LadderBlock.FACING, Direction.Plane.HORIZONTAL.getRandomDirection(net.minecraft.util.RandomSource.create(r.nextLong())));
    return state;
  }

  /** A scene around `origin`: a floor at y - 1, random cells above it, a ceiling now and then. */
  static Map<BlockPos, BlockState> scene(Random r, BlockPos origin, double density) {
    var blocks = new HashMap<BlockPos, BlockState>();
    for (int z = -REACH; z <= REACH; z++) for (int x = -REACH; x <= REACH; x++) {
      var p = origin.offset(x, -1, z);
      blocks.put(p, r.nextDouble() < 0.7 ? Blocks.STONE.defaultBlockState() : pick(r, Palette.FLOORS[r.nextInt(Palette.FLOORS.length)]));
      blocks.put(p.below(), Blocks.STONE.defaultBlockState());
      for (int y = 0; y <= 2; y++) if (r.nextDouble() < density) blocks.put(origin.offset(x, y, z), pick(r, Palette.CELLS[r.nextInt(Palette.CELLS.length)]));
      if (r.nextDouble() < 0.15) blocks.put(origin.offset(x, 2 + r.nextInt(2), z), Blocks.STONE.defaultBlockState());
    }
    return blocks;
  }

  static JsonObject encode(Map<BlockPos, BlockState> blocks) {
    var cells = new JsonArray();
    new TreeMap<Long, BlockState>(blocks.entrySet().stream().collect(java.util.stream.Collectors.toMap(e -> e.getKey().asLong(), Map.Entry::getValue)))
      .forEach((k, s) -> { var p = BlockPos.of(k); var a = cell(p); a.add(Block.getId(s)); cells.add(a); });
    var o = new JsonObject(); o.add("cells", cells); return o;
  }

  static void placeBed(Map<BlockPos, BlockState> blocks, Block bed, BlockPos foot, Direction facing) {
    var state = bed.defaultBlockState().setValue(HorizontalDirectionalBlock.FACING, facing);
    blocks.put(foot, state.setValue(AbstractBedBlock.PART, BedPart.FOOT));
    blocks.put(foot.relative(facing), state.setValue(AbstractBedBlock.PART, BedPart.HEAD));
  }

  static Object respawnPosAngle(Object o, String accessor) throws Exception {
    var m = o.getClass().getDeclaredMethod(accessor); m.setAccessible(true); return m.invoke(o);
  }

  static void fixtures(Path out) throws Exception {
    var r = new Random(4040L);
    var scenes = new JsonArray(); var standUps = new JsonArray(); var respawns = new JsonArray(); var blocked = new JsonArray();
    var findRespawn = ServerPlayer.class.getDeclaredMethod("findRespawnAndUseSpawnBlock", ServerLevel.class, ServerPlayer.RespawnConfig.class, boolean.class);
    findRespawn.setAccessible(true);
    var bedBlockedMethod = ServerPlayer.class.getDeclaredMethod("bedBlocked", BlockPos.class, Direction.class); bedBlockedMethod.setAccessible(true);
    var sleeper = (ServerPlayer) unsafe.allocateInstance(ServerPlayer.class);
    float[] yaws = {0f, 90f, 180f, -90f, 45f, -135.5f, 300f};
    String[] dimensions = {"minecraft:overworld", "minecraft:the_nether", "minecraft:the_end"};
    var origin = new BlockPos(100, 64, -200);

    for (int n = 0; n < 240; n++) {
      double density = n < 40 ? 0.0 : n < 120 ? 0.25 : n < 180 ? 0.5 : 0.92;
      var blocks = scene(r, origin, density);
      // The last scenes are sealed: stone all around, a gap now and then.
      if (n >= 220) for (int z = -REACH; z <= REACH; z++) for (int x = -REACH; x <= REACH; x++) for (int y = 0; y <= 2; y++)
        if (r.nextDouble() < 0.97) blocks.put(origin.offset(x, y, z), Blocks.STONE.defaultBlockState());
      var facing = Direction.Plane.HORIZONTAL.getRandomDirection(net.minecraft.util.RandomSource.create(n));
      int kind = n % 6; // 0..3 beds, 4 straw bed, 5 anchor
      var foot = origin; var head = origin.relative(facing);
      Block bed = kind == 4 ? Blocks.STRAW_BED : kind == 0 ? Blocks.BED.pick(net.minecraft.world.item.DyeColor.RED) : Blocks.BED.white();
      if (kind == 3) placeBed(blocks, Blocks.BED.white(), foot.below(), facing); // a bunk bed
      int charge = r.nextInt(5);
      if (kind == 5) blocks.put(origin, Blocks.RESPAWN_ANCHOR.defaultBlockState().setValue(RespawnAnchorBlock.CHARGE, charge));
      else placeBed(blocks, bed, foot, facing);
      int index = scenes.size(); scenes.add(encode(blocks));
      var level = probe("minecraft:overworld", blocks);

      if (kind == 5) {
        var row = new JsonObject(); row.addProperty("scene", index); row.addProperty("kind", "anchor"); row.add("position", cell(origin));
        row.add("result", vec(RespawnAnchorBlock.findStandUpPosition(EntityTypes.PLAYER, level, origin).orElse(null)));
        standUps.add(row);
      } else {
        for (float yaw : yaws) {
          var row = new JsonObject(); row.addProperty("scene", index); row.addProperty("kind", "bed"); row.add("position", cell(head));
          row.addProperty("facing", facing.getSerializedName()); row.addProperty("yaw", Float.floatToRawIntBits(yaw));
          row.add("result", vec(AbstractBedBlock.findStandUpPosition(EntityTypes.PLAYER, level, head, facing, yaw).orElse(null)));
          standUps.add(row);
        }
        field(Entity.class, "level").set(sleeper, level);
        var b = new JsonObject(); b.addProperty("scene", index); b.add("position", cell(head)); b.addProperty("facing", facing.getSerializedName());
        b.addProperty("blocked", (boolean) bedBlockedMethod.invoke(sleeper, head, facing));
        blocked.add(b);
      }

      // Respawning at the scene's block (or at a cell where it is gone) in each dimension.
      for (var dimension : dimensions) for (boolean missing : new boolean[]{false, true}) {
        var at = kind == 5 ? origin : head;
        var here = new HashMap<>(blocks);
        if (missing) here.put(at, r.nextBoolean() ? Blocks.AIR.defaultBlockState() : Blocks.STONE.defaultBlockState());
        var world = probe(dimension, here);
        float yaw = yaws[r.nextInt(yaws.length)];
        var config = new ServerPlayer.RespawnConfig(LevelData.RespawnData.of(world.key, at, yaw, 12.5f), false);
        var before = world.getBlockState(at);
        var result = (Optional<?>) findRespawn.invoke(null, world, config, true);
        var row = new JsonObject(); row.addProperty("scene", index); row.addProperty("dimension", dimension); row.addProperty("missing", missing);
        row.add("position", cell(at)); row.addProperty("state", Block.getId(before)); row.addProperty("yaw", Float.floatToRawIntBits(yaw));
        if (result.isPresent()) {
          var o = result.get();
          row.add("result", vec((Vec3) respawnPosAngle(o, "position")));
          row.addProperty("result_yaw", Float.floatToRawIntBits((float) respawnPosAngle(o, "yaw")));
          row.addProperty("result_pitch", Float.floatToRawIntBits((float) respawnPosAngle(o, "pitch")));
        } else row.add("result", JsonNull.INSTANCE);
        row.addProperty("after", Block.getId(world.getBlockState(at)));
        respawns.add(row);
      }
    }

    // `bedInRange`: a player's position around a bed's head.
    var inRange = ServerPlayer.class.getDeclaredMethod("bedInRange", BlockPos.class, Direction.class); inRange.setAccessible(true);
    var ranges = new JsonArray();
    for (int n = 0; n < 2000; n++) {
      var facing = Direction.Plane.HORIZONTAL.getRandomDirection(net.minecraft.util.RandomSource.create(n));
      double x = origin.getX() + 0.5 + (r.nextDouble() - 0.5) * 10, y = origin.getY() + (r.nextDouble() - 0.5) * 6, z = origin.getZ() + 0.5 + (r.nextDouble() - 0.5) * 10;
      if (n % 7 == 0) x = origin.getX() + 0.5 + Math.round((x - origin.getX()) * 2) / 2.0;
      if (n % 5 == 0) y = origin.getY() + Math.round((y - origin.getY()) * 2) / 2.0;
      field(Entity.class, "position").set(sleeper, new Vec3(x, y, z));
      var row = new JsonObject(); row.add("position", cell(origin)); row.addProperty("facing", facing.getSerializedName());
      row.add("player", vec(new Vec3(x, y, z))); row.addProperty("in_range", (boolean) inRange.invoke(sleeper, origin, facing));
      ranges.add(row);
    }

    // `SleepStatus`: how many must sleep, and whether enough do.
    var status = new JsonArray();
    var active = field(SleepStatus.class, "activePlayers"); var sleeping = field(SleepStatus.class, "sleepingPlayers");
    for (int players = 0; players <= 7; players++) for (int asleep = 0; asleep <= players; asleep++)
      for (int percentage : new int[]{0, 1, 25, 33, 50, 51, 99, 100, 101}) {
        var s = new SleepStatus(); active.setInt(s, players); sleeping.setInt(s, asleep);
        var row = new JsonObject(); row.addProperty("active", players); row.addProperty("sleeping", asleep); row.addProperty("percentage", percentage);
        row.addProperty("needed", s.sleepersNeeded(percentage)); row.addProperty("enough", s.areEnoughSleeping(percentage));
        status.add(row);
      }

    var fixtures = new JsonObject();
    fixtures.addProperty("version", SharedConstants.getCurrentVersion().id());
    fixtures.add("scenes", scenes); fixtures.add("stand_ups", standUps); fixtures.add("respawns", respawns);
    fixtures.add("blocked", blocked); fixtures.add("ranges", ranges); fixtures.add("sleep_status", status);
    fixtures.add("packets", packets());
    Files.writeString(out, new GsonBuilder().serializeNulls().create().toJson(fixtures));
  }

  // ---------------------------------------------------------------- packets

  static byte[] encode(Object packet) {
    var buffer = new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.buffer(), registries);
    try {
      net.minecraft.network.protocol.game.GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new net.minecraft.network.RegistryFriendlyByteBuf(b, registries)).codec()
        .encode(buffer, (net.minecraft.network.protocol.Packet) packet);
      var bytes = new byte[buffer.readableBytes()]; buffer.readBytes(bytes); return bytes;
    } finally { buffer.release(); }
  }

  @SuppressWarnings("unchecked")
  static JsonObject packets() throws Exception {
    var out = new JsonObject();
    var player = (ServerPlayer) unsafe.allocateInstance(ServerPlayer.class);
    field(Entity.class, "id").setInt(player, 4242);
    out.addProperty("wake_up", hex(encode(new net.minecraft.network.protocol.game.ClientboundAnimatePacket(player, net.minecraft.network.protocol.game.ClientboundAnimatePacket.WAKE_UP))));
    var sleepingPos = (net.minecraft.network.syncher.EntityDataAccessor<Optional<BlockPos>>) field(LivingEntity.class, "SLEEPING_POS_ID").get(null);
    var pose = (net.minecraft.network.syncher.EntityDataAccessor<Pose>) field(Entity.class, "DATA_POSE").get(null);
    out.addProperty("sleeping", hex(encode(new net.minecraft.network.protocol.game.ClientboundSetEntityDataPacket(4242, List.of(
      SynchedEntityData.DataValue.create(pose, Pose.SLEEPING),
      SynchedEntityData.DataValue.create(sleepingPos, Optional.of(new BlockPos(-123, 70, 4567))))))));
    out.addProperty("awake", hex(encode(new net.minecraft.network.protocol.game.ClientboundSetEntityDataPacket(4242, List.of(
      SynchedEntityData.DataValue.create(pose, Pose.STANDING),
      SynchedEntityData.DataValue.create(sleepingPos, Optional.empty()))))));
    out.addProperty("no_respawn_block", hex(encode(new net.minecraft.network.protocol.game.ClientboundGameEventPacket(
      net.minecraft.network.protocol.game.ClientboundGameEventPacket.NO_RESPAWN_BLOCK_AVAILABLE, 0.0F))));
    // `announceSleepStatus`'s overlays and the spawn message.
    out.addProperty("players_sleeping", hex(encode(new net.minecraft.network.protocol.game.ClientboundSystemChatPacket(
      Component.translatable("sleep.players_sleeping", 1, 2), true))));
    out.addProperty("skipping_night", hex(encode(new net.minecraft.network.protocol.game.ClientboundSystemChatPacket(
      Component.translatable("sleep.skipping_night"), true))));
    var spawnSet = (Component) field(ServerPlayer.class, "SPAWN_SET_MESSAGE").get(null);
    out.addProperty("spawn_set", hex(encode(new net.minecraft.network.protocol.game.ClientboundSystemChatPacket(spawnSet, false))));

    // The bad respawn point's death message (`CombatTracker.getDeathMessage`).
    var body = (DamageMessageOracle.Body) unsafe.allocateInstance(DamageMessageOracle.Body.class);
    body.name = "ValiMCTest";
    var source = new DamageSource(registries.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(DamageTypes.BAD_RESPAWN_POINT), new Vec3(0.5, 64.5, 0.5));
    var tracker = new CombatTracker(body);
    ((List<CombatEntry>) field(CombatTracker.class, "entries").get(tracker)).add(new CombatEntry(source, 5.0F, null, 0.0F));
    out.add("bad_respawn_point", ComponentSerialization.CODEC.encodeStart(JsonOps.INSTANCE, tracker.getDeathMessage()).getOrThrow());
    out.addProperty("bad_respawn_point_exhaustion", (double) source.getFoodExhaustion());
    return out;
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    unsafe = (sun.misc.Unsafe) field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    registries = WorldgenFactsOracle.loadRegistries(List.of());
    switch (args[0]) {
      case "facts" -> facts(Path.of(args[1]));
      case "fixtures" -> fixtures(Path.of(args[1]));
      default -> throw new IllegalArgumentException(args[0]);
    }
  }
}
