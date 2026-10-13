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
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.phys.*;

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
  private Object readGame() throws Exception {
    Object packet = read(gameIn);
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
  private void await(java.util.function.Predicate<Object> predicate) throws Exception {
    for (int i = 0; i < 300; i++) if (predicate.test(readGame())) return;
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
      first.send(gameOut, new ServerboundSetCreativeModeSlotPacket(36, new ItemStack(Blocks.STONE)));
      first.send(gameOut, new ServerboundUseItemOnPacket(InteractionHand.MAIN_HAND,
        new BlockHitResult(new Vec3(2.5, 64, 0.5), Direction.UP, new BlockPos(2, 63, 0), false), 1));
      first.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(2,64,0)) && b.getBlockState().is(Blocks.STONE));
      second.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(2,64,0)) && b.getBlockState().is(Blocks.STONE));
      first.send(gameOut, new ServerboundPlayerActionPacket(ServerboundPlayerActionPacket.Action.START_DESTROY_BLOCK, new BlockPos(2,64,0), Direction.UP, 2));
      first.await(p -> p instanceof ClientboundBlockUpdatePacket b && b.getPos().equals(new BlockPos(2,64,0)) && b.getBlockState().isAir());
      first.send(gameOut, new ServerboundMovePlayerPacket.PosRot(1.5,64,0.5,90,0,true,false));
      second.await(p -> p instanceof ClientboundMoveEntityPacket.PosRot);
      first.send(gameOut, new ServerboundChatCommandPacket("stats"));
      first.await(p -> p instanceof ClientboundSystemChatPacket c && c.content().getString().contains("schedulers"));
      System.out.println("PASS: Mojang 26.3 codecs validated compressed login, network registry/tag dependency loading, " + first.chunks + " chunks, two-player visibility, movement, block placement/breaking and commands.");
      System.out.println(first.seen);
    }
  }
}
