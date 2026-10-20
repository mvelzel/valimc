import com.google.gson.*;
import java.io.*;
import java.nio.ByteBuffer;
import java.nio.file.*;
import java.util.*;
import net.minecraft.nbt.*;
import net.minecraft.resources.ResourceKey;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.chunk.storage.*;

/**
 * Region files as vanilla reads them (VMC-021a). `generate DIR OUT` makes a
 * deflate world and an LZ4 world (`region-file-compression=lz4`) whose entity
 * chunk is too large for its region file (an external `.mcc` chunk), derives
 * damaged copies of a real region file, and records for every region file what
 * the pinned `RegionFile` returns per slot: no chunk, an error while reading, or
 * the chunk's canonical digest (see WorldNbtOracle).
 */
public class RegionOracle {
  public static void main(String[] args) throws Exception {
    var dir = Path.of(args[0]);
    var out = Path.of(args[1]);
    WorldNbtOracle.runServer(dir.resolve("deflate"), Map.of(), WorldNbtOracle.FIXTURES);
    var heavy = new ArrayList<>(WorldNbtOracle.FIXTURES);
    var random = new Random(20261020);
    // About 1.9 MB of poorly compressible names in one chunk's entities: external.
    for (int i = 0; i < 48; i++) {
      var name = new StringBuilder();
      for (int k = 0; k < 40_000; k++) name.append((char) ('!' + random.nextInt(90)));
      var text = name.toString().replace("\\", "/").replace("\"", "'");
      heavy.add("summon minecraft:marker ~8 300 ~8 {data:{blob:\"" + text + "\"}}");
    }
    WorldNbtOracle.runServer(dir.resolve("lz4"), Map.of("region-file-compression", "lz4"), heavy);

    net.minecraft.SharedConstants.tryDetectVersion();
    net.minecraft.server.Bootstrap.bootStrap();
    var files = new ArrayList<Path>();
    for (var world : List.of("deflate", "lz4"))
      try (var walk = Files.walk(dir.resolve(world).resolve("universe/w"))) {
        files.addAll(walk.filter(p -> p.toString().endsWith(".mca")).sorted().toList());
      }
    boolean external;
    try (var walk = Files.walk(dir.resolve("lz4"))) { external = walk.anyMatch(p -> p.toString().endsWith(".mcc")); }
    if (!external) throw new IllegalStateException("the LZ4 world has no external chunk");
    files.addAll(damaged(dir, files));

    var rows = new JsonArray();
    int present = 0, absent = 0, errors = 0;
    for (var file : files) {
      var slots = vanillaView(file);
      var row = new JsonObject();
      row.addProperty("path", file.toString());
      row.add("slots", slots);
      rows.add(row);
      for (var e : slots.entrySet()) {
        var v = e.getValue().getAsString();
        if (v.equals("error")) errors++; else present++;
      }
      absent += 1024 - slots.size();
    }
    var facts = new JsonObject();
    facts.add("files", rows);
    Files.writeString(out, new Gson().toJson(facts));
    System.out.println("PASS: vanilla read " + files.size() + " region files: " + present + " chunks, "
        + errors + " read errors, " + absent + " empty or dropped slots (external and LZ4 chunks included)");
  }

  /** Per slot index: the chunk digest, or "error"; slots vanilla reads as no chunk are left out. */
  static JsonObject vanillaView(Path file) throws Exception {
    // RegionFile opens files for writing: give it a copy (with the external chunks).
    var copy = Files.createTempDirectory("valimc-region-view");
    try {
      try (var siblings = Files.list(file.getParent())) {
        for (var p : siblings.filter(p -> p.toString().endsWith(".mcc") || p.equals(file)).toList())
          Files.copy(p, copy.resolve(p.getFileName()));
      }
      var name = file.getFileName().toString().split("\\.");
      int rx = Integer.parseInt(name[1]), rz = Integer.parseInt(name[2]);
      var slots = new JsonObject();
      var info = new RegionStorageInfo("oracle", Level.OVERWORLD, "chunk");
      try (var region = new RegionFile(info, copy.resolve(file.getFileName()), copy, false)) {
        for (int index = 0; index < 1024; index++) {
          var pos = new ChunkPos(rx * 32 + (index & 31), rz * 32 + (index >> 5));
          try (var stream = region.getChunkDataInputStream(pos)) {
            if (stream == null) continue;
            slots.addProperty(Integer.toString(index), WorldNbtOracle.digest(NbtIo.read(stream, NbtAccounter.unlimitedHeap())));
          } catch (IOException | RuntimeException error) {
            slots.addProperty(Integer.toString(index), "error");
          }
        }
      }
      return slots;
    } finally {
      try (var walk = Files.walk(copy)) { walk.sorted(Comparator.reverseOrder()).forEach(p -> p.toFile().delete()); }
    }
  }

  /** Damaged copies of the deflate world's fullest region file, one directory each. */
  static List<Path> damaged(Path dir, List<Path> files) throws Exception {
    Path source = null;
    int best = -1;
    for (var f : files) {
      if (!f.toString().contains("deflate") || !f.getParent().getFileName().toString().equals("region")) continue;
      int used = used(Files.readAllBytes(f)).size();
      if (used > best) { best = used; source = f; }
    }
    var bytes = Files.readAllBytes(source);
    var slots = used(bytes);
    var name = source.getFileName().toString();
    var parts = name.split("\\.");
    int rx = Integer.parseInt(parts[1]), rz = Integer.parseInt(parts[2]);
    var out = new ArrayList<Path>();
    var cases = new LinkedHashMap<String, byte[]>();
    int fileSectors = bytes.length / 4096;

    cases.put("short_header", Arrays.copyOf(bytes, 3000));
    cases.put("header_only", Arrays.copyOf(bytes, 8192));
    cases.put("cut_mid_chunk", Arrays.copyOf(bytes, bytes.length - 2500));
    cases.put("overlaps_header", entry(bytes, slots.get(0), 1, 1));
    cases.put("no_sectors", entry(bytes, slots.get(1), sector(bytes, slots.get(1)), 0));
    cases.put("past_end", entry(bytes, slots.get(2), fileSectors + 1, 1));
    cases.put("at_end", entry(bytes, slots.get(3), fileSectors, 1));
    cases.put("length_zero", chunkHeader(bytes, slots.get(4), 0, null));
    cases.put("length_negative", chunkHeader(bytes, slots.get(5), -5, null));
    cases.put("length_too_long", chunkHeader(bytes, slots.get(6), 1 << 20, null));
    cases.put("compression_9", chunkHeader(bytes, slots.get(7), null, (byte) 9));
    cases.put("compression_custom", chunkHeader(bytes, slots.get(8), null, (byte) 127));
    cases.put("external_missing", chunkHeader(bytes, slots.get(9), null, (byte) (2 | 128)));
    var flipped = bytes.clone();
    int s = sector(bytes, slots.get(10)) * 4096;
    for (int k = 20; k < 60; k++) flipped[s + k] ^= 0x5A;
    cases.put("corrupt_zlib", flipped);
    cases.put("external_present", chunkHeader(bytes, slots.get(11), null, (byte) (2 | 128)));

    for (var c : cases.entrySet()) {
      var caseDir = dir.resolve("damaged").resolve(c.getKey());
      Files.createDirectories(caseDir);
      var path = caseDir.resolve(name);
      Files.write(path, c.getValue());
      if (c.getKey().equals("external_present")) {
        // The chunk's own zlib payload, moved to its external file.
        int index = slots.get(11);
        int start = sector(bytes, index) * 4096;
        int length = ByteBuffer.wrap(bytes, start, 4).getInt();
        var payload = Arrays.copyOfRange(bytes, start + 5, start + 4 + length);
        Files.write(caseDir.resolve("c." + (rx * 32 + (index & 31)) + "." + (rz * 32 + (index >> 5)) + ".mcc"), payload);
      }
      out.add(path);
    }
    return out;
  }

  static List<Integer> used(byte[] bytes) {
    var list = new ArrayList<Integer>();
    for (int i = 0; i < 1024; i++) if (ByteBuffer.wrap(bytes).getInt(i * 4) != 0) list.add(i);
    if (list.size() < 12) throw new IllegalStateException("region file has too few chunks");
    return list;
  }

  static int sector(byte[] bytes, int index) { return ByteBuffer.wrap(bytes).getInt(index * 4) >>> 8; }

  static byte[] entry(byte[] bytes, int index, int sector, int count) {
    var copy = bytes.clone();
    ByteBuffer.wrap(copy).putInt(index * 4, (sector << 8) | count);
    return copy;
  }

  static byte[] chunkHeader(byte[] bytes, int index, Integer length, Byte type) {
    var copy = bytes.clone();
    int start = sector(bytes, index) * 4096;
    if (length != null) ByteBuffer.wrap(copy).putInt(start, length);
    if (type != null) copy[start + 4] = type;
    return copy;
  }
}
