import com.google.gson.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.SectionPos;
import net.minecraft.nbt.*;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.LightLayer;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.storage.*;
import net.minecraft.world.level.lighting.LevelLightEngine;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.ticks.ProtoChunkTicks;

/**
 * Vanilla light computed by vanilla's own `LevelLightEngine` (VMC-022b), from the
 * blocks of every full chunk in a ChunkOracle world: each chunk is a ProtoChunk
 * of its parsed sections; sources are initialized and propagated as when a chunk
 * is first lit, and updates run to completion. For every chunk whose eight
 * neighbours are full (they decide its light), the sky then block light of each
 * of its 24 sections is written as nibble arrays to OUT.bin, in the order listed
 * in OUT.json.
 */
public class LightOracle {
  public static void main(String[] args) throws Exception {
    var factory = ChunkOracle.factory();
    var facts = JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();
    var chunks = new HashMap<Long, ProtoChunk>();
    var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
    var regions = new HashMap<String, RegionFile>();
    var copies = Files.createTempDirectory("valimc-light");
    for (var element : facts.getAsJsonArray("chunks")) {
      var row = element.getAsJsonObject();
      if (!row.has("sections")) continue;
      var path = Path.of(row.get("path").getAsString());
      var region = regions.get(path.toString());
      if (region == null) {
        var dir = copies.resolve(Integer.toString(regions.size()));
        Files.createDirectories(dir);
        Files.copy(path, dir.resolve(path.getFileName()));
        region = new RegionFile(info, dir.resolve(path.getFileName()), dir, false);
        regions.put(path.toString(), region);
      }
      var pos = new ChunkPos(row.get("x").getAsInt(), row.get("z").getAsInt());
      CompoundTag tag;
      try (var stream = region.getChunkDataInputStream(pos)) { tag = NbtIo.read(stream); }
      var data = SerializableChunkData.parse(ChunkOracle.HEIGHT, factory, tag);
      var sections = new LevelChunkSection[24];
      for (int i = 0; i < 24; i++) sections[i] = new LevelChunkSection(factory);
      for (var section : data.sectionData())
        if (section.chunkSection() != null && section.y() >= -4 && section.y() < 20) sections[section.y() + 4] = section.chunkSection();
      var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, sections, new ProtoChunkTicks<>(), new ProtoChunkTicks<>(),
          ChunkOracle.HEIGHT, factory, null);
      chunk.initializeLightSources();
      chunks.put(pos.pack(), chunk);
    }
    for (var region : regions.values()) region.close();

    var level = new BlockGetter() {
      public BlockEntity getBlockEntity(BlockPos pos) { return null; }
      public BlockState getBlockState(BlockPos pos) {
        var chunk = chunks.get(ChunkPos.pack(pos.getX() >> 4, pos.getZ() >> 4));
        return chunk == null ? Blocks.AIR.defaultBlockState() : chunk.getBlockState(pos);
      }
      public FluidState getFluidState(BlockPos pos) { return getBlockState(pos).getFluidState(); }
      public int getHeight() { return 384; }
      public int getMinY() { return -64; }
    };
    var getter = new LightChunkGetter() {
      public LightChunk getChunkForLighting(int x, int z) { return chunks.get(ChunkPos.pack(x, z)); }
      public BlockGetter getLevel() { return level; }
    };
    var engine = new LevelLightEngine(getter, true, true);
    for (var chunk : chunks.values()) {
      var pos = chunk.getPos();
      var sections = chunk.getSections();
      for (int i = 0; i < sections.length; i++) engine.updateSectionStatus(SectionPos.of(pos, i - 4), sections[i].hasOnlyAir());
      engine.setLightEnabled(pos, true);
    }
    for (var chunk : chunks.values()) engine.propagateLightSources(chunk.getPos());
    while (engine.hasLightWork()) engine.runLightUpdates();

    var listed = new JsonArray();
    var sky = engine.getLayerListener(LightLayer.SKY);
    var block = engine.getLayerListener(LightLayer.BLOCK);
    var mutable = new BlockPos.MutableBlockPos();
    try (var out = new BufferedOutputStream(Files.newOutputStream(Path.of(args[2])))) {
      for (var chunk : chunks.values()) {
        var pos = chunk.getPos();
        boolean surrounded = true;
        for (int dx = -1; dx <= 1; dx++) for (int dz = -1; dz <= 1; dz++)
          surrounded &= chunks.containsKey(ChunkPos.pack(pos.x() + dx, pos.z() + dz));
        if (!surrounded) continue;
        for (int s = 0; s < 24; s++)
          for (var layer : List.of(sky, block)) {
            var bytes = new byte[2048];
            for (int i = 0; i < 4096; i++) {
              mutable.set(pos.getMinBlockX() + (i & 15), (s - 4) * 16 + (i >> 8), pos.getMinBlockZ() + ((i >> 4) & 15));
              bytes[i >> 1] |= (byte) ((layer.getLightValue(mutable) & 15) << ((i & 1) * 4));
            }
            out.write(bytes);
          }
        var row = new JsonObject();
        row.addProperty("x", pos.x());
        row.addProperty("z", pos.z());
        listed.add(row);
      }
    }
    var result = new JsonObject();
    result.add("chunks", listed);
    Files.writeString(Path.of(args[1]), new Gson().toJson(result));
    System.out.println("PASS: vanilla's light engine lit " + chunks.size() + " full chunks; light of " + listed.size() + " chunks with full neighbours written");
  }
}
