import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.LevelHeightAccessor;
import net.minecraft.world.level.biome.Biomes;
import net.minecraft.world.level.biome.FixedBiomeSource;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.chunk.ChunkAccess;
import net.minecraft.world.level.chunk.ProtoChunk;
import net.minecraft.world.level.chunk.UpgradeData;
import net.minecraft.world.level.levelgen.Aquifer;
import net.minecraft.world.level.levelgen.NoiseBasedChunkGenerator;
import net.minecraft.world.level.levelgen.NoiseChunk;
import net.minecraft.world.level.levelgen.NoiseGeneratorSettings;
import net.minecraft.world.level.levelgen.RandomState;
import net.minecraft.world.level.levelgen.blending.Blender;
import net.minecraft.world.level.levelgen.densityfunction.DensityVolume;

/**
 * Vanilla noise terrain (VMC-024a): for three seeds and every noise settings
 * entry, chunks near the origin and up to 30,000,000 blocks away are filled by
 * vanilla's own `NoiseBasedChunkGenerator.doFill` on a fresh proto chunk, with
 * a noise chunk built as chunk generation builds it but without structures
 * (no beardifier) or blending. Per chunk: the state ids run-length encoded in
 * volume order (Y fastest from the bottom, then X, then Z) as [id, count]
 * pairs, and the positions marked for fluid post-processing.
 */
public class TerrainOracle {
  public static void main(String[] args) throws Exception {
    var factory = ChunkOracle.factory();
    var lookup = VanillaRegistries.createWorldLookup();
    var noises = lookup.lookupOrThrow(Registries.NOISE);
    var plains = lookup.lookupOrThrow(Registries.BIOME).getOrThrow(Biomes.PLAINS);
    var settingsList = lookup.lookupOrThrow(Registries.NOISE_SETTINGS).listElements()
        .sorted(Comparator.comparing(h -> h.key().identifier().toString())).toList();
    var doFill = NoiseBasedChunkGenerator.class.getDeclaredMethod("doFill", NoiseChunk.class, ChunkAccess.class);
    doFill.setAccessible(true);
    var createFluidPicker = NoiseBasedChunkGenerator.class.getDeclaredMethod("createFluidPicker", NoiseGeneratorSettings.class);
    createFluidPicker.setAccessible(true);
    var gen = new Random(20261020L);
    long[] seeds = {20261020L, -8172645723L, gen.nextLong()};
    var cases = new JsonArray();
    long blocks = 0;

    for (long seed : seeds) {
      for (var holder : settingsList) {
        var settings = holder.value();
        var state = RandomState.create(noises, seed, settings);
        var generator = new NoiseBasedChunkGenerator(new FixedBiomeSource(plains), holder);
        var picker = (Aquifer.FluidPicker) createFluidPicker.invoke(null, settings);
        int minY = settings.noiseSettings().minY(), height = settings.noiseSettings().height();
        var heights = LevelHeightAccessor.create(minY, height);
        var positions = new ArrayList<>(List.of(new ChunkPos(0, 0), new ChunkPos(-1, 2)));
        positions.add(new ChunkPos(gen.nextInt(4001) - 2000, gen.nextInt(4001) - 2000));
        positions.add(new ChunkPos(gen.nextInt(4001) - 2000, gen.nextInt(4001) - 2000));
        positions.add(new ChunkPos(gen.nextInt(3_750_001) - 1_875_000, gen.nextInt(3_750_001) - 1_875_000));
        for (var pos : positions) {
          var chunk = new ProtoChunk(pos, UpgradeData.EMPTY, heights, factory, null);
          var volume = new DensityVolume(16, height, 16, pos.getMinBlockX(), minY, pos.getMinBlockZ());
          try (var noiseChunk = new NoiseChunk(state, null, settings, picker, Blender.empty(), volume)) {
            doFill.invoke(generator, noiseChunk, chunk);
          }
          var runs = new JsonArray();
          int last = -1, count = 0;
          var cursor = new BlockPos.MutableBlockPos();
          for (int z = 0; z < 16; z++)
            for (int x = 0; x < 16; x++)
              for (int y = 0; y < height; y++) {
                int id = Block.getId(chunk.getBlockState(cursor.set(pos.getMinBlockX() + x, minY + y, pos.getMinBlockZ() + z)));
                if (id != last && count > 0) {
                  runs.add(last);
                  runs.add(count);
                  count = 0;
                }
                last = id;
                count++;
                blocks++;
              }
          runs.add(last);
          runs.add(count);
          var updates = new TreeSet<String>();
          var lists = chunk.getPostProcessing();
          for (int i = 0; i < lists.length; i++) {
            if (lists[i] == null) continue;
            for (short packed : lists[i]) {
              var p = ProtoChunk.unpackOffsetCoordinates(packed, chunk.getSectionYFromSectionIndex(i), pos);
              updates.add(p.getX() + "," + p.getY() + "," + p.getZ());
            }
          }
          var row = new JsonObject();
          row.addProperty("seed", Long.toString(seed));
          row.addProperty("settings", holder.key().identifier().toString());
          row.addProperty("x", pos.x());
          row.addProperty("z", pos.z());
          row.add("runs", runs);
          row.add("fluid_updates", new Gson().toJsonTree(updates));
          cases.add(row);
        }
      }
    }
    var out = new JsonObject();
    out.add("cases", cases);
    Files.writeString(Path.of(args[0]), new Gson().toJson(out));
    System.out.println("PASS: " + cases.size() + " vanilla noise-filled chunks over " + seeds.length + " seeds and "
        + settingsList.size() + " noise settings (" + blocks + " blocks)");
  }
}
