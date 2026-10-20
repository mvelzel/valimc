import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.Registries;
import net.minecraft.nbt.*;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.biome.Biome;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.chunk.storage.*;

/**
 * Chunk sections as vanilla loads them (VMC-021b). `generate DIR OUT` runs the
 * pinned server into DIR and records, for every chunk of the overworld region
 * files, its status and, for full chunks, a digest per section of what
 * `SerializableChunkData.parse` loads: the 4,096 block state ids in index order
 * and the 64 biome names. `verify OUT DIR` decodes ValiMC's network section data
 * (`chunk-<i>.bin`) with `LevelChunkSection.read` and compares the same digests.
 */
public class ChunkOracle {
  static final LevelHeightAccessor HEIGHT = LevelHeightAccessor.create(-64, 384);

  public static void main(String[] args) throws Exception {
    var factory = factory();
    if (args[0].equals("generate")) generate(factory, Path.of(args[1]), Path.of(args[2]));
    else verify(factory, Path.of(args[1]), Path.of(args[2]));
  }

  static PalettedContainerFactory factory() throws Exception {
    var base = MiningToolOracle.initialize();
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA,
        List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var loaded = RegistryDataLoader.load(resources, base.listRegistries().toList(),
          RegistryDataLoader.WORLD_REGISTRIES, Runnable::run).join();
      return PalettedContainerFactory.create(loaded);
    }
  }

  static String digest(LevelChunkSection section) throws Exception {
    var bytes = new ByteArrayOutputStream();
    var out = new DataOutputStream(bytes);
    for (int y = 0; y < 16; y++)
      for (int z = 0; z < 16; z++)
        for (int x = 0; x < 16; x++) out.writeShort(Block.getId(section.getBlockState(x, y, z)));
    var biomes = section.getBiomes();
    for (int y = 0; y < 4; y++)
      for (int z = 0; z < 4; z++)
        for (int x = 0; x < 4; x++) {
          Holder<Biome> biome = biomes.get(x, y, z);
          out.write((biome.unwrapKey().orElseThrow().identifier().toString() + "\n").getBytes(StandardCharsets.UTF_8));
        }
    return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()));
  }

  static void generate(PalettedContainerFactory factory, Path dir, Path out) throws Exception {
    // A 16×16-chunk force-loaded area around spawn becomes full chunks.
    var commands = new ArrayList<>(WorldNbtOracle.FIXTURES);
    commands.add("forceload add ~-128 ~-128 ~127 ~127");
    commands.add("#sleep 25000");
    WorldNbtOracle.runServer(dir, Map.of(), commands);
    var regionDir = dir.resolve("universe/w/dimensions/minecraft/overworld/region");
    List<Path> files;
    try (var list = Files.list(regionDir)) { files = list.filter(p -> p.toString().endsWith(".mca")).sorted().toList(); }
    var chunks = new JsonArray();
    var statuses = new TreeMap<String, Integer>();
    var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
    for (var file : files) {
      var copy = Files.createTempDirectory("valimc-chunks");
      Files.copy(file, copy.resolve(file.getFileName()));
      var name = file.getFileName().toString().split("\\.");
      int rx = Integer.parseInt(name[1]), rz = Integer.parseInt(name[2]);
      try (var region = new RegionFile(info, copy.resolve(file.getFileName()), copy, false)) {
        for (int index = 0; index < 1024; index++) {
          var pos = new ChunkPos(rx * 32 + (index & 31), rz * 32 + (index >> 5));
          CompoundTag tag;
          try (var stream = region.getChunkDataInputStream(pos)) {
            if (stream == null) continue;
            tag = NbtIo.read(stream);
          }
          var status = SerializableChunkData.getChunkStatusFromTag(tag);
          var row = new JsonObject();
          row.addProperty("path", file.toString());
          row.addProperty("index", index);
          row.addProperty("x", pos.x());
          row.addProperty("z", pos.z());
          row.addProperty("status", status.toString());
          statuses.merge(status.toString(), 1, Integer::sum);
          if (status == ChunkStatus.FULL) {
            var data = SerializableChunkData.parse(HEIGHT, factory, tag);
            var byY = new HashMap<Integer, LevelChunkSection>();
            for (var section : data.sectionData()) if (section.chunkSection() != null) byY.put(section.y(), section.chunkSection());
            var sections = new JsonArray();
            for (int y = -4; y < 20; y++) sections.add(digest(byY.getOrDefault(y, new LevelChunkSection(factory))));
            row.add("sections", sections);
          }
          chunks.add(row);
        }
      }
    }
    if (statuses.getOrDefault("minecraft:full", 0) < 100) throw new IllegalStateException("too few full chunks: " + statuses);
    var facts = new JsonObject();
    facts.add("chunks", chunks);
    Files.writeString(out, new Gson().toJson(facts));
    System.out.println("PASS: vanilla loaded " + chunks.size() + " overworld chunks " + statuses + "; section digests for every full chunk");
  }

  static void verify(PalettedContainerFactory factory, Path facts, Path dir) throws Exception {
    var chunks = JsonParser.parseString(Files.readString(facts)).getAsJsonObject().getAsJsonArray("chunks");
    int checked = 0;
    for (int i = 0; i < chunks.size(); i++) {
      var row = chunks.get(i).getAsJsonObject();
      if (!row.has("sections")) continue;
      var buf = new FriendlyByteBuf(Unpooled.wrappedBuffer(Files.readAllBytes(dir.resolve("chunk-" + i + ".bin"))));
      var expected = row.getAsJsonArray("sections");
      for (int s = 0; s < 24; s++) {
        var section = new LevelChunkSection(factory);
        section.read(buf);
        if (!digest(section).equals(expected.get(s).getAsString()))
          throw new AssertionError("chunk " + row.get("x") + "," + row.get("z") + " section " + (s - 4) + " decodes differently from vanilla's load");
      }
      if (buf.readableBytes() != 0) throw new AssertionError("trailing section bytes in chunk " + i);
      checked++;
    }
    if (checked == 0) throw new AssertionError("nothing verified");
    System.out.println("PASS: vanilla decodes ValiMC's chunk packet sections for " + checked + " imported chunks to the blocks and biomes vanilla loaded");
  }
}
