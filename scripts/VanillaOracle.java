import java.io.*;
import java.net.*;
import java.util.*;
import java.util.zip.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.*;
import net.minecraft.network.protocol.*;
import net.minecraft.network.protocol.handshake.*;
import net.minecraft.network.protocol.login.*;
import net.minecraft.network.protocol.configuration.*;
import net.minecraft.network.protocol.common.*;
import net.minecraft.network.protocol.game.*;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.tags.TagLoader;
import net.minecraft.tags.TagNetworkSerialization;
import net.minecraft.server.packs.repository.KnownPack;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.item.component.CustomData;
import net.minecraft.nbt.CompoundTag;
import net.minecraft.network.HashedStack;
import net.minecraft.world.inventory.ContainerInput;
import it.unimi.dsi.fastutil.ints.Int2ObjectOpenHashMap;
import net.minecraft.core.component.DataComponents;
import net.minecraft.network.chat.Component;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.phys.*;
import net.minecraft.commands.CommandBuildContext;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.resources.Identifier;
import com.mojang.brigadier.*;
import com.mojang.brigadier.arguments.ArgumentType;
import com.mojang.brigadier.builder.*;
import com.mojang.brigadier.exceptions.CommandSyntaxException;

/** A real TCP client using Mojang's 26.3 encoders and decoders as an independent oracle. */
public class VanillaOracle implements AutoCloseable {
  private static RegistryAccess.Frozen registries;
  private static ProtocolInfo<?> gameIn;
  private static ProtocolInfo<?> gameOut;
  private final Socket socket;
  private final InputStream input;
  private final OutputStream output;
  private int threshold = -1;
  private final Map<String, Integer> seen = new TreeMap<>();
  private int chunks;
  private int expectedChunks;
  private ClientboundContainerSetContentPacket initialInventory;

  private VanillaOracle(int port, String name) throws Exception {
    socket = new Socket("127.0.0.1", port);
    socket.setSoTimeout(10000);
    input = socket.getInputStream();
    output = socket.getOutputStream();
    send(HandshakeProtocols.SERVERBOUND, new ClientIntentionPacket(777, "localhost", port, ClientIntent.LOGIN));
    send(LoginProtocols.SERVERBOUND, new ServerboundHelloPacket(name, UUID.randomUUID()));
    Object login;
    do {
      login = read(LoginProtocols.CLIENTBOUND);
      if (login instanceof ClientboundLoginCompressionPacket compression) threshold = compression.getCompressionThreshold();
    } while (!(login instanceof ClientboundLoginFinishedPacket));
    send(LoginProtocols.SERVERBOUND, ServerboundLoginAcknowledgedPacket.INSTANCE);
    Map<ResourceKey<? extends Registry<?>>, List<RegistrySynchronization.PackedRegistryEntry>> entries = new HashMap<>();
    Map<ResourceKey<? extends Registry<?>>, TagNetworkSerialization.NetworkPayload> tags = new HashMap<>();
    while (true) {
      Object packet = read(ConfigurationProtocols.CLIENTBOUND);
      if (packet instanceof ClientboundSelectKnownPacks packs) {
        if (!packs.knownPacks().equals(List.of(new KnownPack("minecraft", "core", "26.3")))) throw new AssertionError("Wrong known pack");
        send(ConfigurationProtocols.SERVERBOUND, new ServerboundSelectKnownPacks(packs.knownPacks()));
      }
      if (packet instanceof ClientboundRegistryDataPacket registry) entries.put(registry.registry(), registry.entries());
      if (packet instanceof ClientboundUpdateTagsPacket update) tags.putAll(update.tags());
      if (packet instanceof ClientboundFinishConfigurationPacket) {
        loadNetworkRegistries(entries, tags);
        send(ConfigurationProtocols.SERVERBOUND, ServerboundFinishConfigurationPacket.INSTANCE);
        break;
      }
    }
    while (expectedChunks == 0 || chunks < expectedChunks) {
      Object packet = readGame();
      if (packet instanceof ClientboundLoginPacket world) {
        expectedChunks = (world.chunkRadius() * 2 + 1) * (world.chunkRadius() * 2 + 1);
        if (world.commonPlayerSpawnInfo().gameType() != net.minecraft.world.level.GameType.CREATIVE) throw new AssertionError("Wrong game type");
        if (world.commonPlayerSpawnInfo().dimensionType().value().minY() != -64) throw new AssertionError("Wrong dimension");
      }
    }
    if (seen.getOrDefault("ClientboundRegistryDataPacket", 0) != RegistryDataLoader.SYNCHRONIZED_REGISTRIES.size()) throw new AssertionError("Missing registry");
    if (seen.getOrDefault("ClientboundCommandsPacket", 0) != 1) throw new AssertionError("Missing command graph");
    if (initialInventory == null || initialInventory.containerId() != 0 || initialInventory.items().size() != 46 ||
        initialInventory.items().stream().anyMatch(s -> !s.isEmpty()) || !initialInventory.carriedItem().isEmpty())
      throw new AssertionError("Invalid initial player inventory");
    if (seen.getOrDefault("ClientboundSetHeldSlotPacket", 0) != 1) throw new AssertionError("Missing initial selection");
  }

  /** Exercise the dependency loading that the graphical client's configuration collector performs. */
  @SuppressWarnings({"rawtypes", "unchecked"})
  private static void loadNetworkRegistries(
    Map<ResourceKey<? extends Registry<?>>, List<RegistrySynchronization.PackedRegistryEntry>> entries,
    Map<ResourceKey<? extends Registry<?>>, TagNetworkSerialization.NetworkPayload> tags) {
    var builtin = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    List<Registry.PendingTags<?>> pending = new ArrayList<>();
    builtin.registries().forEach(entry -> {
      var payload = tags.get(entry.key());
      if (payload != null) pending.add(((Registry) entry.value()).prepareTagReload(payload.resolve(entry.value())));
    });
    Map<ResourceKey<? extends Registry<?>>, RegistryDataLoader.NetworkedRegistryData> data = new HashMap<>();
    entries.forEach((key, values) -> data.put(key, new RegistryDataLoader.NetworkedRegistryData(
      values, tags.getOrDefault(key, TagNetworkSerialization.NetworkPayload.EMPTY))));
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
      List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var dynamic = RegistryDataLoader.load(data, resources,
        TagLoader.buildUpdatedLookups(builtin, pending), RegistryDataLoader.SYNCHRONIZED_REGISTRIES, Runnable::run).join();
      if (dynamic.registries().count() != RegistryDataLoader.SYNCHRONIZED_REGISTRIES.size()) throw new AssertionError("Registry loading incomplete");
    }
    pending.forEach(Registry.PendingTags::apply);
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  private void send(ProtocolInfo info, Packet packet) throws IOException {
    ByteBuf buffer = Unpooled.buffer();
    try {
      info.codec().encode(buffer, packet);
      byte[] data = new byte[buffer.readableBytes()]; buffer.readBytes(data);
      ByteArrayOutputStream body = new ByteArrayOutputStream();
      if (threshold >= 0) {
        if (data.length >= threshold) {
          writeVarInt(body, data.length);
          try (var deflater = new DeflaterOutputStream(body)) { deflater.write(data); }
        } else { writeVarInt(body, 0); body.write(data); }
      } else body.write(data);
      writeVarInt(output, body.size()); output.write(body.toByteArray()); output.flush();
    } finally { buffer.release(); }
  }
  private Object read(ProtocolInfo<?> info) throws Exception {
    int length = readVarInt(input);
    if (length < 1 || length > 2097152) throw new AssertionError("Invalid frame length");
    byte[] data = input.readNBytes(length);
    if (data.length != length) throw new EOFException();
    if (threshold >= 0) {
      var bytes = new ByteArrayInputStream(data);
      int uncompressed = readVarInt(bytes);
      if (uncompressed == 0) data = bytes.readAllBytes();
      else {
        data = new InflaterInputStream(bytes).readAllBytes();
        if (data.length != uncompressed) throw new AssertionError("Bad compressed size");
      }
    }
    ByteBuf buffer = Unpooled.wrappedBuffer(data);
    try {
      Object packet = info.codec().decode(buffer);
      if (buffer.isReadable()) throw new AssertionError("Trailing bytes in " + packet.getClass().getSimpleName() + ": " + buffer.readableBytes());
      seen.merge(packet.getClass().getSimpleName(), 1, Integer::sum);
      return packet;
    } catch (Throwable failure) {
      System.err.println("Frame bytes: " + data.length + "; prefix: " + HexFormat.of().formatHex(Arrays.copyOf(data, Math.min(data.length, 96))));
      throw failure;
    } finally { buffer.release(); }
  }
  private ClientboundSetTimePacket lastTime;
  private int timePacketsSeen;
  private boolean rainInitialized, thunderInitialized;
  private Object readGame() throws Exception {
    Object packet = read(gameIn);
    if (packet instanceof ClientboundSetTimePacket time) {
      if (time.clockUpdates().size()!=2 || time.gameTime()<0) throw new AssertionError("Invalid core clock map");
      for (var state:time.clockUpdates().values())
        if (state.totalTicks()!=time.gameTime() || state.partialTick()!=0f || state.rate()!=1f)
          throw new AssertionError("Default clock differs from actual delivered game ticks");
      if (timePacketsSeen>=2 && time.gameTime()-lastTime.gameTime()!=20)
        throw new AssertionError("Clock synchronization did not advance 20 delivered ticks");
      lastTime=time; timePacketsSeen++;
    }

    if (packet instanceof ClientboundGameEventPacket weather) {
      if (weather.getEvent()==ClientboundGameEventPacket.RAIN_LEVEL_CHANGE || weather.getEvent()==ClientboundGameEventPacket.THUNDER_LEVEL_CHANGE) {
        if (weather.getParam()!=0f) throw new AssertionError("Unexpected fresh-world weather intensity");
        if (weather.getEvent()==ClientboundGameEventPacket.RAIN_LEVEL_CHANGE) rainInitialized=true;
        else thunderInitialized=true;
      }
    }
    if (packet instanceof ClientboundCommandsPacket commands) validateCommands(commands);
    if (packet instanceof ClientboundContainerSetContentPacket inventory && initialInventory == null) initialInventory = inventory;
    if (packet instanceof ClientboundPlayerPositionPacket teleport) {
      var change = teleport.change(); var pos = change.position();
      send(gameOut, new ServerboundAcceptTeleportationPacket(teleport.id(), pos.x, pos.y, pos.z, change.yRot(), change.xRot()));
    }
    if (packet instanceof ClientboundKeepAlivePacket ping) send(gameOut, new ServerboundKeepAlivePacket(ping.getId()));
    if (packet instanceof ClientboundChunkBatchFinishedPacket) send(gameOut, new ServerboundChunkBatchReceivedPacket(8.0f));
    if (packet instanceof ClientboundLevelChunkWithLightPacket chunk) {
      chunks++;
      var buffer = chunk.chunkData().getReadBuffer();
      try {
        var factory = PalettedContainerFactory.create(registries);
        for (int sy = -4; sy <= 19; sy++) {
          var section = new LevelChunkSection(factory);
          section.read(buffer);
          int y = sy * 16;
          var expected = y == -64 ? Blocks.BEDROCK : y < 60 ? Blocks.STONE : y < 63 ? Blocks.DIRT : y == 63 ? Blocks.GRASS_BLOCK : Blocks.AIR;
          if (!section.getBlockState(0, 0, 0).is(expected)) throw new AssertionError("Unexpected terrain at " + y);
        }
        if (buffer.isReadable()) throw new AssertionError("Trailing chunk section bytes");
      } finally { buffer.release(); }
    }
    return packet;
  }

  private static void validateCommands(ClientboundCommandsPacket packet) throws Exception {
    var root = packet.getRoot(CommandBuildContext.simple(registries, FeatureFlags.DEFAULT_FLAGS),
      new ClientboundCommandsPacket.NodeBuilder<Object>() {
        public ArgumentBuilder<Object, ?> createLiteral(String name) { return LiteralArgumentBuilder.literal(name); }
        public ArgumentBuilder<Object, ?> createArgument(String name, ArgumentType<?> type, Identifier suggestion) {
          throw new AssertionError("Unexpected argument node in literal-only preview");
        }
        public ArgumentBuilder<Object, ?> configure(ArgumentBuilder<Object, ?> builder, boolean executable, boolean restricted) {
          if (restricted) throw new AssertionError("Public preview command marked restricted");
          return executable ? builder.executes(context -> 1) : builder;
        }
      });
    var names = root.getChildren().stream().map(n -> n.getName()).sorted().toList();
    if (!names.equals(List.of("help", "spawn", "stats"))) throw new AssertionError("Wrong command graph: " + names);
    var dispatcher = new CommandDispatcher<Object>(root);
    Object source = new Object();
    for (String name : names) {
      if (dispatcher.execute(name, source) != 1) throw new AssertionError("Non-executable command: " + name);
    }
    var suggestions = dispatcher.getCompletionSuggestions(dispatcher.parse("sta", source)).join()
      .getList().stream().map(s -> s.getText()).toList();
    if (!suggestions.equals(List.of("stats"))) throw new AssertionError("Wrong local completion: " + suggestions);
    for (String invalid : List.of("stats extra", "stats ", "stats  ", "STATS", "missing", "stats\t")) {
      try {
        dispatcher.execute(invalid, source);
        throw new AssertionError("Invalid command accepted by graph: " + invalid);
      } catch (CommandSyntaxException expected) { }
    }
  }
  private void await(java.util.function.Predicate<Object> predicate) throws Exception {
    long deadline = System.nanoTime() + 15_000_000_000L;
    for (int i = 0; i < 300 && System.nanoTime() < deadline; i++) if (predicate.test(readGame())) return;
    throw new AssertionError("Expected packet not received");
  }
  private static int readVarInt(InputStream in) throws IOException {
    int value = 0;
    for (int shift = 0; shift < 35; shift += 7) {
      int b = in.read(); if (b < 0) throw new EOFException();
      value |= (b & 127) << shift;
      if ((b & 128) == 0) return value;
    }
    throw new IOException("Invalid VarInt");
  }
  private static void writeVarInt(OutputStream out, int value) throws IOException {
    do { int b = value & 127; value >>>= 7; out.write(value == 0 ? b : b | 128); } while (value != 0);
  }
  @Override public void close() throws IOException { socket.close(); }

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    List<Registry<?>> all = new ArrayList<>(BuiltInRegistries.REGISTRY.stream().toList());
    for (var data : RegistryDataLoader.SYNCHRONIZED_REGISTRIES) {
      var source = lookup.lookupOrThrow(data.key());
      MappedRegistry mapped = new MappedRegistry(data.key(), Lifecycle.stable());
      source.listElements().sorted(Comparator.comparing(h -> h.key().identifier().toString()))
        .forEach(h -> mapped.register(h.key(), h.value(), RegistrationInfo.BUILT_IN));
      mapped.bindAllTagsToEmpty(); mapped.freeze(); all.add(mapped);
    }
    registries = new RegistryAccess.ImmutableRegistryAccess(all).freeze();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    gameIn = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, registries));
    gameOut = GameProtocols.SERVERBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, registries), new GameProtocols.Context() {
      public boolean hasInfiniteMaterials() { return true; }
      public boolean canUseCommandBlocks() { return false; }
    });
    int port = args.length > 0 ? Integer.parseInt(args[0]) : 25565;
    try (var first = new VanillaOracle(port, "OracleOne"); var second = new VanillaOracle(port, "OracleTwo")) {
      first.await(p -> p instanceof ClientboundAddEntityPacket);
      if (first.lastTime==null || second.lastTime==null) throw new AssertionError("Missing initial clock synchronization");
      if (!first.rainInitialized || !first.thunderInitialized || !second.rainInitialized || !second.thunderInitialized)
        throw new AssertionError("Missing initial weather intensity synchronization");
      long initialClockTime=first.lastTime.gameTime();
      first.await(p -> p instanceof ClientboundSetTimePacket t && t.gameTime()>initialClockTime);
      System.out.println("PASS: Mojang decoded initial/periodic 26.3 registered clocks, all holders and 20-tick cadence.");

      var stone = new ItemStack(Blocks.STONE, 17);
      stone.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE, true);
      var customData = new CompoundTag(); customData.putString("probe", "ValiMC \u0000😀é");
      stone.set(DataComponents.CUSTOM_DATA, CustomData.of(customData));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(36, stone));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getContainerId() == 0 && s.getSlot() == 36 && ItemStack.matches(s.getItem(), stone));
      var unsupported = stone.copy();
      var unsupportedName = new net.minecraft.nbt.CompoundTag();
      unsupportedName.putString("selector", "@p");
      unsupported.set(DataComponents.CUSTOM_NAME, net.minecraft.network.chat.ComponentSerialization.CODEC
        .parse(net.minecraft.nbt.NbtOps.INSTANCE, unsupportedName).getOrThrow());
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(36, unsupported));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 36 && ItemStack.matches(s.getItem(), stone));
      var enchantmentRegistry = registries.lookupOrThrow(Registries.ENCHANTMENT);
      var enchanted = new net.minecraft.world.item.enchantment.ItemEnchantments.Mutable(
        net.minecraft.world.item.enchantment.ItemEnchantments.EMPTY);
      enchanted.set(enchantmentRegistry.getOrThrow(ResourceKey.create(Registries.ENCHANTMENT,
        net.minecraft.resources.Identifier.parse("minecraft:unbreaking"))), 3);
      var enchantedStone = stone.copy(); enchantedStone.set(DataComponents.ENCHANTMENTS, enchanted.toImmutable());
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(36, enchantedStone));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 36 && ItemStack.matches(s.getItem(), enchantedStone));
      var stored = new net.minecraft.world.item.enchantment.ItemEnchantments.Mutable(
        net.minecraft.world.item.enchantment.ItemEnchantments.EMPTY);
      stored.set(enchantmentRegistry.getOrThrow(ResourceKey.create(Registries.ENCHANTMENT,
        net.minecraft.resources.Identifier.parse("minecraft:sharpness"))), 5);
      var enchantedBook = new ItemStack(Items.ENCHANTED_BOOK);
      enchantedBook.set(DataComponents.STORED_ENCHANTMENTS, stored.toImmutable());
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(13, enchantedBook));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 13 && ItemStack.matches(s.getItem(), enchantedBook));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(13, ItemStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 13 && s.getItem().isEmpty());
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(36, stone));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 36 && ItemStack.matches(s.getItem(), stone));
      System.out.println("PASS: Mojang 26.3 negotiated enchantment holder IDs, active Unbreaking III and stored Sharpness V accepted through ordinary creative packets.");
      var hiddenStone = stone.copy();
      hiddenStone.set(DataComponents.TOOLTIP_DISPLAY, net.minecraft.world.item.component.TooltipDisplay.DEFAULT
        .withHidden(DataComponents.CUSTOM_DATA, true).withHidden(DataComponents.ENCHANTMENTS, true));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(13, hiddenStone));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 13 && ItemStack.matches(s.getItem(), hiddenStone));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(13, ItemStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 13 && s.getItem().isEmpty());
      System.out.println("PASS: Mojang 26.3 tooltip component controls retained through ordinary creative packets without deleting underlying data.");
      first.send(gameOut, new ServerboundUseItemOnPacket(InteractionHand.MAIN_HAND,
        new BlockHitResult(new Vec3(2.5, 64, 0.5), Direction.UP, new BlockPos(2, 63, 0), false), 1));
      first.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(2,64,0)) && b.getBlockState().is(Blocks.STONE));
      second.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(2,64,0)) && b.getBlockState().is(Blocks.STONE));
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, new BlockPos(2,64,0), Direction.UP, 2));
      first.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(2,64,0)) && b.getBlockState().isAir());
      var eggs = new ItemStack(Items.EGG, 16);
      var planks = new ItemStack(Blocks.OAK_PLANKS, 8);
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(9, eggs));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 9 && ItemStack.matches(s.getItem(), eggs));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(44, stone));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 44 && ItemStack.matches(s.getItem(), stone));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(45, planks));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 45 && ItemStack.matches(s.getItem(), planks));
      first.send(gameOut, new ServerboundSetCarriedItemPacket(8));
      first.await(p -> p instanceof ClientboundSetHeldSlotPacket s && s.slot() == 8);
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.SWAP_ITEM_WITH_OFFHAND, BlockPos.ZERO, Direction.DOWN, 0));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 44 && ItemStack.matches(s.getItem(), planks));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 45 && ItemStack.matches(s.getItem(), stone));
      first.send(gameOut, new ServerboundUseItemOnPacket(InteractionHand.OFF_HAND,
        new BlockHitResult(new Vec3(3.5,64,0.5), Direction.UP, new BlockPos(3,63,0), false), 3));
      first.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(3,64,0)) && b.getBlockState().is(Blocks.STONE));
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, new BlockPos(3,64,0), Direction.UP, 4));
      first.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(3,64,0)) && b.getBlockState().isAir());
      var predictions = new Int2ObjectOpenHashMap<HashedStack>();
      predictions.put(9, HashedStack.create(stone, component -> 0x12345678));
      var invented = new ItemStack(Items.DIAMOND, 99);
      invented.remove(DataComponents.ITEM_NAME);
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)9, (byte)0, ContainerInput.PICKUP,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().size() == 46 &&
        c.items().get(9).isEmpty() && ItemStack.matches(c.items().get(44), planks) &&
        ItemStack.matches(c.items().get(45), stone) && ItemStack.matches(c.carriedItem(), eggs));
      first.await(p -> p instanceof ClientboundSetCursorItemPacket c && ItemStack.matches(c.contents(), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)9, (byte)1, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(9).getCount() == 1 && c.carriedItem().getCount() == 15);
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)9, (byte)0, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(9), eggs) && c.carriedItem().isEmpty());
      first.await(p -> p instanceof ClientboundSetCursorItemPacket c && c.contents().isEmpty());
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)9, (byte)0, ContainerInput.QUICK_MOVE,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(9).isEmpty() && ItemStack.matches(c.items().get(37), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)37, (byte)8, ContainerInput.SWAP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(37), planks) && ItemStack.matches(c.items().get(44), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)37, (byte)40, ContainerInput.SWAP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(37), stone) && ItemStack.matches(c.items().get(45), planks));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)44, (byte)0, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)0, ContainerInput.QUICK_CRAFT,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs));
      for (short slot : new short[]{9, 10, 11}) {
        first.send(gameOut, new ServerboundContainerClickPacket(0, 0, slot, (byte)1, ContainerInput.QUICK_CRAFT,
          new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
        first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs));
      }
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)2, ContainerInput.QUICK_CRAFT,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().getCount() == 1 &&
        c.items().get(9).getCount() == 5 && c.items().get(10).getCount() == 5 && c.items().get(11).getCount() == 5 &&
        c.items().get(9).is(Items.EGG) && c.items().get(44).isEmpty());
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)12, (byte)0, ContainerInput.PICKUP_ALL,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs) &&
        c.items().get(9).isEmpty() && c.items().get(10).isEmpty() && c.items().get(11).isEmpty());
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)44, (byte)0, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty() && ItemStack.matches(c.items().get(44), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)44, (byte)2, ContainerInput.CLONE,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs) && ItemStack.matches(c.items().get(44), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)8, ContainerInput.QUICK_CRAFT,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs));
      for (short slot : new short[]{9, 10}) {
        first.send(gameOut, new ServerboundContainerClickPacket(0, 0, slot, (byte)9, ContainerInput.QUICK_CRAFT,
          new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
        first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs));
      }
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)10, ContainerInput.QUICK_CRAFT,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty() &&
        ItemStack.matches(c.items().get(9), eggs) && ItemStack.matches(c.items().get(10), eggs) && ItemStack.matches(c.items().get(44), eggs));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)44, (byte)0, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), eggs) && c.items().get(44).isEmpty());
      first.send(gameOut, new ServerboundContainerClosePacket(99));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty() &&
        ItemStack.matches(c.items().get(38), eggs) && c.items().get(44).isEmpty() &&
        ItemStack.matches(c.items().get(9), eggs) && ItemStack.matches(c.items().get(10), eggs));
      first.send(gameOut, new ServerboundMovePlayerPacket.PosRot(1.5,64,0.5,90,0,true,false));
      second.await(p -> p instanceof ClientboundMoveEntityPacket.PosRot);
      first.send(gameOut, new ServerboundChatCommandPacket("stats"));
      first.await(p -> p instanceof ClientboundSystemChatPacket c && c.content().getString().contains("schedulers"));
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(44, stone.copyWithCount(7)));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 44 && s.getItem().getCount() == 7);
      first.send(gameOut, new ServerboundSetCarriedItemPacket(8));
      first.await(p -> p instanceof ClientboundSetHeldSlotPacket s && s.slot() == 8);
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.DROP_ITEM, BlockPos.ZERO, Direction.DOWN, 0));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(44), stone.copyWithCount(6)));
      second.await(p -> p instanceof ClientboundSetEntityDataPacket d && d.packedItems().stream().anyMatch(v -> v.value() instanceof ItemStack s && ItemStack.matches(s, stone.copyWithCount(1))));
      // Source completion sends a second inventory update; wait for it before the next action.
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(44), stone.copyWithCount(6)));
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.DROP_ALL_ITEMS, BlockPos.ZERO, Direction.DOWN, 0));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(44).isEmpty());
      second.await(p -> p instanceof ClientboundSetEntityDataPacket d && d.packedItems().stream().anyMatch(v -> v.value() instanceof ItemStack s && ItemStack.matches(s, stone.copyWithCount(6))));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(44).isEmpty());
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.DROP_ITEM, BlockPos.ZERO, Direction.DOWN, 0));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(44).isEmpty());
      System.out.println("PASS: Mojang 26.3 Q/Ctrl+Q action codecs, authoritative depleted inventory, exact patched item metadata and empty-hand correction.");
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(9, stone.copyWithCount(7)));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot() == 9 && s.getItem().getCount() == 7);
      first.send(gameOut, new ServerboundContainerClickPacket(0, 32767, (short)9, (byte)0, ContainerInput.THROW,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(9), stone.copyWithCount(6)));
      second.await(p -> p instanceof ClientboundSetEntityDataPacket d && d.packedItems().stream().anyMatch(v -> v.value() instanceof ItemStack s && ItemStack.matches(s, stone.copyWithCount(1))));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(9), stone.copyWithCount(6)));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)9, (byte)0, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(9).isEmpty() && ItemStack.matches(c.carriedItem(), stone.copyWithCount(6)));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)45, (byte)1, ContainerInput.THROW,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), stone.copyWithCount(6)) && ItemStack.matches(c.items().get(45), planks));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)1, ContainerInput.PICKUP,
        predictions, HashedStack.create(invented, component -> 0x12345678)));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), stone.copyWithCount(5)));
      second.await(p -> p instanceof ClientboundSetEntityDataPacket d && d.packedItems().stream().anyMatch(v -> v.value() instanceof ItemStack s && ItemStack.matches(s, stone.copyWithCount(1))));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.carriedItem(), stone.copyWithCount(5)));
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)0, ContainerInput.QUICK_MOVE,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty());
      second.await(p -> p instanceof ClientboundSetEntityDataPacket d && d.packedItems().stream().anyMatch(v -> v.value() instanceof ItemStack s && ItemStack.matches(s, stone.copyWithCount(5))));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty());
      first.send(gameOut, new ServerboundContainerClickPacket(0, 0, (short)-999, (byte)0, ContainerInput.PICKUP,
        new Int2ObjectOpenHashMap<>(), HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty());
      System.out.println("PASS: Mojang 26.3 ordinary menu THROW and outside cursor drop codecs, forged predictions, depleted inventory/cursor and exact world stack patches.");
      var creativeSource = new ItemStack(Items.EGG,4);
      creativeSource.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(36,creativeSource));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot()==36 && ItemStack.matches(s.getItem(),creativeSource));
      var creativeDrop = creativeSource.copyWithCount(2);
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(-32768,creativeDrop));
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(36,creativeDrop));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot()==36 && ItemStack.matches(s.getItem(),creativeDrop));
      second.await(p -> p instanceof ClientboundSetEntityDataPacket d && d.packedItems().stream().anyMatch(v -> v.value() instanceof ItemStack s && ItemStack.matches(s,creativeDrop)));
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(-1,ItemStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(36),creativeDrop));
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(0,creativeSource));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && ItemStack.matches(c.items().get(36),creativeDrop));
      System.out.println("PASS: Mojang 26.3 creative negative-slot creation codecs, independent paired slot write, exact glint item metadata and empty/invalid-slot correction.");
      for (int slot=9; slot<=44; slot++) {
        first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(slot,stone.copyWithCount(64)));
        final int expectedSlot=slot;
        first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot()==expectedSlot && ItemStack.matches(s.getItem(),stone.copyWithCount(64)));
      }
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(44,stone.copyWithCount(63)));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot()==44 && s.getItem().getCount()==63);
      first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(45,stone.copyWithCount(10)));
      first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot()==45 && s.getItem().getCount()==10);
      first.send(gameOut,new ServerboundContainerClickPacket(0,0,(short)45,(byte)0,ContainerInput.PICKUP,new Int2ObjectOpenHashMap<>(),HashedStack.EMPTY));
      first.await(p -> p instanceof ClientboundContainerSetContentPacket c && c.items().get(45).isEmpty() && ItemStack.matches(c.carriedItem(),stone.copyWithCount(10)));
      var grid = new ItemStack[]{new ItemStack(Items.EGG,3),new ItemStack(Items.DIRT,4),new ItemStack(Items.IRON_SWORD),new ItemStack(Items.DIAMOND)};
      grid[2].set(DataComponents.DAMAGE,17);
      for (int i=0; i<4; i++) {
        first.send(gameOut,new ServerboundSetCreativeModeSlotPacket(i+1,grid[i]));
        final int expectedSlot=i+1; final ItemStack expectedStack=grid[i];
        first.await(p -> p instanceof ClientboundContainerSetSlotPacket s && s.getSlot()==expectedSlot && ItemStack.matches(s.getItem(),expectedStack));
      }
      first.send(gameOut,new ServerboundContainerClosePacket(99));
      java.util.function.Predicate<Object> returnedMenu = p -> p instanceof ClientboundContainerSetContentPacket c && c.carriedItem().isEmpty() && c.items().get(1).isEmpty() && c.items().get(2).isEmpty() && c.items().get(3).isEmpty() && c.items().get(4).isEmpty() && ItemStack.matches(c.items().get(44),stone.copyWithCount(64));
      first.await(returnedMenu);
      var wanted = new java.util.ArrayList<ItemStack>(); wanted.add(stone.copyWithCount(9)); wanted.addAll(java.util.Arrays.asList(grid));
      second.await(p -> {
        if (p instanceof ClientboundSetEntityDataPacket d) for (var value : d.packedItems()) {
          if (value.value() instanceof ItemStack stack) wanted.removeIf(expected -> ItemStack.matches(stack,expected));
        }
        return wanted.isEmpty();
      });
      first.await(returnedMenu);
      first.send(gameOut,new ServerboundContainerClosePacket(0));
      first.await(returnedMenu);
      System.out.println("PASS: Mojang 26.3 connected close partial merge, cleared cursor/grid, exact patched/damaged five-item overflow batch and repeated close contents.");
      System.out.println("PASS: Mojang 26.3 codecs validated compressed login, network registry/tag dependency loading, command graph/local completion, " + first.chunks + " chunks, inventory/selection/hand swaps, authoritative pickup/split/merge/shift/swap/quick-craft/collect/clone/fill with forged predictions, menu-close return, creative scalar stacks/corrections, two-player visibility, movement, block placement/breaking and commands.");
      System.out.println(first.seen);
    }
  }
}
