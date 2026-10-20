import com.google.gson.*;
import java.io.*;
import java.net.ServerSocket;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.zip.*;
import net.minecraft.nbt.*;

/**
 * Golden world NBT (VMC-020). `generate DIR OUT` runs the pinned dedicated server
 * into DIR, adds entities, block entities and points of interest by console
 * command, and writes every NBT payload (compressed bytes as stored) with vanilla's
 * canonical digest, plus vanilla's verdict on synthetic edge cases.
 * `verify OUT REENCODED` reads ValiMC's re-encodings with vanilla and compares
 * digests. The digest walks vanilla's tags: compound keys sorted by UTF-8 bytes,
 * strings as UTF-8, floats as raw bits, list elements each with their own type
 * (vanilla unwraps `{"": tag}` list elements on load).
 */
public class WorldNbtOracle {
  static final HexFormat HEX = HexFormat.of();

  public static void main(String[] args) throws Exception {
    if (args[0].equals("generate")) generate(Path.of(args[1]), Path.of(args[2]));
    else if (args[0].equals("verify")) verify(Path.of(args[1]), Path.of(args[2]));
    else throw new IllegalArgumentException(args[0]);
  }

  // ---- canonical digest ----

  static String digest(Tag tag) throws Exception {
    var bytes = new ByteArrayOutputStream();
    canon(tag, new DataOutputStream(bytes));
    return HEX.formatHex(MessageDigest.getInstance("SHA-256").digest(bytes.toByteArray()));
  }

  static void utf8(String s, DataOutputStream out) throws IOException {
    var raw = s.getBytes(StandardCharsets.UTF_8);
    out.writeInt(raw.length);
    out.write(raw);
  }

  static void canon(Tag tag, DataOutputStream out) throws IOException {
    out.writeByte(tag.getId());
    switch (tag) {
      case ByteTag t -> out.writeByte(t.value());
      case ShortTag t -> out.writeShort(t.value());
      case IntTag t -> out.writeInt(t.value());
      case LongTag t -> out.writeLong(t.value());
      case FloatTag t -> out.writeInt(Float.floatToRawIntBits(t.value()));
      case DoubleTag t -> out.writeLong(Double.doubleToRawLongBits(t.value()));
      case ByteArrayTag t -> { out.writeInt(t.size()); out.write(t.getAsByteArray()); }
      case IntArrayTag t -> { out.writeInt(t.size()); for (int v : t.getAsIntArray()) out.writeInt(v); }
      case LongArrayTag t -> { out.writeInt(t.size()); for (long v : t.getAsLongArray()) out.writeLong(v); }
      case StringTag t -> utf8(t.value(), out);
      case ListTag t -> { out.writeInt(t.size()); for (Tag e : t) canon(e, out); }
      case CompoundTag t -> {
        var keys = new ArrayList<>(t.keySet());
        keys.sort((a, b) -> Arrays.compareUnsigned(a.getBytes(StandardCharsets.UTF_8), b.getBytes(StandardCharsets.UTF_8)));
        out.writeInt(keys.size());
        for (var key : keys) { utf8(key, out); canon(t.get(key), out); }
      }
      default -> throw new IllegalStateException("tag " + tag);
    }
  }

  // ---- compression as stored ----

  static byte[] inflate(byte[] raw, String compression) throws IOException {
    InputStream in = switch (compression) {
      case "gzip" -> new GZIPInputStream(new ByteArrayInputStream(raw));
      case "zlib" -> new InflaterInputStream(new ByteArrayInputStream(raw));
      case "none" -> new ByteArrayInputStream(raw);
      default -> throw new IOException("compression " + compression);
    };
    return in.readAllBytes();
  }

  static CompoundTag readDisk(byte[] raw, String compression) throws IOException {
    var in = new DataInputStream(new ByteArrayInputStream(inflate(raw, compression)));
    return NbtIo.read(in, NbtAccounter.unlimitedHeap());
  }

  // ---- world generation ----

  /** The golden world's console commands: block entities, entities and points of interest. */
  static final List<String> FIXTURES = List.of(
      "forceload add ~ ~",
      // Commands stay ASCII; SNBT escapes supply NUL, accented and astral characters.
      "setblock ~2 300 ~2 minecraft:chest{Items:[{Slot:0b,id:\"minecraft:diamond_sword\",count:1,components:{\"minecraft:custom_name\":\"\\u00dcn\\u00efc\\u00f8d\\u00e9 \\U0001d11e \\u2713 \\u0000\"}},{Slot:5b,id:\"minecraft:stone\",count:64}]}",
      "setblock ~3 300 ~2 minecraft:bell",
      "setblock ~4 300 ~2 minecraft:lectern",
      "setblock ~5 300 ~2 minecraft:furnace",
      "summon minecraft:armor_stand ~2 302 ~2 {CustomName:\"Stand \\u2713\",NoGravity:1b,Tags:[\"valimc\",\"\\U0001d11e\"]}",
      "summon minecraft:villager ~4 302 ~4 {NoAI:1b,NoGravity:1b}",
      "summon minecraft:item ~5 302 ~5 {Item:{id:\"minecraft:stone\",count:3},Age:-32768s,PickupDelay:32767s,NoGravity:1b}",
      "summon minecraft:experience_orb ~6 302 ~6 {Value:7s,NoGravity:1b}");

  static void generate(Path dir, Path out) throws Exception {
    runServer(dir, Map.of(), FIXTURES);
    var world = dir.resolve("universe/w");
    var files = new JsonArray();
    var kinds = new TreeMap<String, Integer>();
    List<Path> paths;
    try (var walk = Files.walk(world)) { paths = walk.filter(Files::isRegularFile).sorted().toList(); }
    for (var path : paths) {
      var name = path.getFileName().toString();
      var relative = world.relativize(path).toString();
      if (name.endsWith(".dat")) {
        var raw = Files.readAllBytes(path);
        var kind = name.equals("level.dat") ? "level" : "data";
        files.add(entry(relative, kind, "gzip", raw, null, NbtIo.readCompressed(path, NbtAccounter.unlimitedHeap())));
        kinds.merge(kind, 1, Integer::sum);
      } else if (name.endsWith(".mca")) {
        var kind = path.getParent().getFileName().toString(); // region, entities or poi
        var bytes = Files.readAllBytes(path);
        if (bytes.length < 8192) continue;
        var header = java.nio.ByteBuffer.wrap(bytes);
        for (int i = 0; i < 1024; i++) {
          int location = header.getInt(i * 4);
          int offset = location >>> 8;
          if (offset == 0) continue;
          var chunk = java.nio.ByteBuffer.wrap(bytes, offset * 4096, bytes.length - offset * 4096);
          int length = chunk.getInt();
          byte type = chunk.get();
          var compression = switch (type) { case 1 -> "gzip"; case 2 -> "zlib"; case 3 -> "none"; default -> throw new IllegalStateException("chunk compression " + type); };
          var raw = new byte[length - 1];
          chunk.get(raw);
          files.add(entry(relative, kind, compression, raw, new int[]{i & 31, i >> 5}, readDisk(raw, compression)));
          kinds.merge(kind, 1, Integer::sum);
        }
      }
    }
    if (!kinds.containsKey("region") || !kinds.containsKey("entities") || !kinds.containsKey("poi") || !kinds.containsKey("level"))
      throw new IllegalStateException("world lacks expected files: " + kinds);

    var facts = new JsonObject();
    net.minecraft.SharedConstants.tryDetectVersion();
    facts.addProperty("data_version", net.minecraft.SharedConstants.getCurrentVersion().dataVersion().version());
    facts.add("files", files);
    facts.add("cases", cases());
    Files.writeString(out, new Gson().toJson(facts));
    System.out.println("PASS: generated " + files.size() + " vanilla world NBT payloads " + kinds + " and " + facts.getAsJsonArray("cases").size() + " edge cases");
  }

  /**
   * Run the pinned dedicated server headless in DIR (seed 20261020, extra
   * server.properties), send `commands` on its console ("#sleep MS" pauses), save,
   * stop, and refuse any error or rejected command. The world is DIR/universe/w.
   */
  static void runServer(Path dir, Map<String, String> properties, List<String> commands) throws Exception {
    Files.createDirectories(dir);
    int port;
    try (var socket = new ServerSocket(0)) { port = socket.getLocalPort(); }
    Files.writeString(dir.resolve("eula.txt"), "eula=true\n");
    var props = new TreeMap<>(Map.of("online-mode", "false", "server-port", Integer.toString(port),
        "level-seed", "20261020", "spawn-protection", "0", "sync-chunk-writes", "true"));
    props.putAll(properties);
    var text = new StringBuilder();
    props.forEach((k, v) -> text.append(k).append('=').append(v).append('\n'));
    Files.writeString(dir.resolve("server.properties"), text);
    var javaBin = ProcessHandle.current().info().command().orElseThrow();
    var process = new ProcessBuilder(javaBin, "-Dstdin.encoding=UTF-8", "-cp", System.getProperty("java.class.path"),
        "net.minecraft.server.Main", "--nogui", "--universe", dir.resolve("universe").toString(), "--world", "w")
        .directory(dir.toFile()).redirectErrorStream(true).start();
    var lines = new LinkedBlockingQueue<String>();
    var log = new StringBuilder();
    var reader = new Thread(() -> {
      try (var r = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
        for (String line; (line = r.readLine()) != null; ) { lines.add(line); synchronized (log) { log.append(line).append('\n'); } }
      } catch (IOException ignored) {}
    });
    reader.start();
    var console = new PrintWriter(new OutputStreamWriter(process.getOutputStream(), StandardCharsets.UTF_8), true);
    try {
      await(lines, "Done (", log);
      for (var command : commands) {
        // "#sleep MS" waits, e.g. for force-loaded chunks to generate.
        if (command.startsWith("#sleep ")) Thread.sleep(Long.parseLong(command.substring(7)));
        else console.println(command);
      }
      console.println("save-all flush");
      await(lines, "Saved the game", log);
      console.println("stop");
      if (!process.waitFor(120, TimeUnit.SECONDS)) throw new IllegalStateException("server did not stop");
    } finally {
      process.destroyForcibly();
    }
    synchronized (log) {
      for (var line : log.toString().split("\n"))
        if (line.contains("ERROR") || line.contains("Exception") || line.contains("Unknown or incomplete command")
            || line.contains("Expected") || line.contains("Invalid")) throw new IllegalStateException("server: " + line);
    }
  }

  static void await(BlockingQueue<String> lines, String marker, StringBuilder log) throws Exception {
    long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(180);
    while (System.nanoTime() < deadline) {
      var line = lines.poll(1, TimeUnit.SECONDS);
      if (line != null && line.contains(marker)) return;
    }
    synchronized (log) { throw new IllegalStateException("timed out waiting for " + marker + "\n" + log); }
  }

  static JsonObject entry(String path, String kind, String compression, byte[] raw, int[] chunk, CompoundTag tag) throws Exception {
    var row = new JsonObject();
    row.addProperty("path", path);
    row.addProperty("kind", kind);
    row.addProperty("compression", compression);
    if (chunk != null) row.add("chunk", new Gson().toJsonTree(chunk));
    row.addProperty("raw", HEX.formatHex(raw));
    row.addProperty("digest", digest(tag));
    if (tag.get("DataVersion") instanceof IntTag version) row.addProperty("data_version", version.value());
    else if (tag.get("Data") instanceof CompoundTag data && data.get("DataVersion") instanceof IntTag version) row.addProperty("data_version", version.value());
    return row;
  }

  // ---- synthetic edge cases ----

  static byte[] disk(CompoundTag tag) throws IOException {
    var bytes = new ByteArrayOutputStream();
    NbtIo.write(tag, new DataOutputStream(bytes));
    return bytes.toByteArray();
  }

  static JsonObject verdict(String name, String framing, byte[] raw) throws Exception {
    var row = new JsonObject();
    row.addProperty("name", name);
    row.addProperty("framing", framing);
    row.addProperty("raw", HEX.formatHex(raw));
    try {
      var in = new DataInputStream(new ByteArrayInputStream(raw));
      Tag tag = framing.equals("disk") ? NbtIo.read(in, NbtAccounter.unlimitedHeap()) : NbtIo.readAnyTag(in, NbtAccounter.unlimitedHeap());
      row.addProperty("accept", true);
      row.addProperty("digest", digest(tag));
    } catch (IOException | RuntimeException error) {
      row.addProperty("accept", false);
      row.addProperty("error", error.getClass().getSimpleName());
    }
    return row;
  }

  static Tag nest(boolean list, int depth) {
    Tag tag = new CompoundTag();
    for (int i = 1; i < depth; i++) {
      if (list) { var l = new ListTag(); l.add(tag); tag = l; }
      else { var c = new CompoundTag(); c.put("n", tag); tag = c; }
    }
    return tag;
  }

  static JsonArray cases() throws Exception {
    var all = new CompoundTag();
    all.putByte("byte", (byte) -128);
    all.putShort("short", (short) 32767);
    all.putInt("int", Integer.MIN_VALUE);
    all.putLong("long", Long.MAX_VALUE);
    all.putFloat("float", -0.0f);
    all.putFloat("nan", Float.intBitsToFloat(0x7fc00001));
    all.putDouble("double", Double.NEGATIVE_INFINITY);
    all.putByteArray("bytes", new byte[]{-1, 0, 1});
    all.putIntArray("ints", new int[]{-1, 0, Integer.MAX_VALUE});
    all.putLongArray("longs", new long[]{Long.MIN_VALUE, 0});
    all.putString("", "empty name");
    all.putString("ascii", "plain");
    all.putString("nul", "a\u0000b");
    all.putString("bmp", "é€✓");
    all.putString("astral", "𝄞😀");
    all.putString("long_string", "x".repeat(65535));
    var ints = new ListTag(); ints.add(IntTag.valueOf(1)); ints.add(IntTag.valueOf(2)); all.put("int_list", ints);
    all.put("empty_list", new ListTag());
    var mixed = new ListTag(); mixed.add(IntTag.valueOf(1)); mixed.add(StringTag.valueOf("two")); var inner = new CompoundTag(); inner.putByte("b", (byte) 1); mixed.add(inner); all.put("mixed_list", mixed);
    var lists = new ListTag(); lists.add(ints.copy()); lists.add(new ListTag()); all.put("list_of_lists", lists);
    var nested = new CompoundTag(); nested.put("all_types_copy", all.copy()); all.put("nested", nested);

    var rows = new JsonArray();
    var valid = disk(all);
    rows.add(verdict("all_types", "disk", valid));
    rows.add(verdict("empty_root", "disk", disk(new CompoundTag())));
    for (int depth : new int[]{511, 512, 513}) {
      var root = new CompoundTag();
      root.put("deep", nest(false, depth - 1));
      rows.add(verdict("compound_depth_" + depth, "disk", disk(root)));
      var listRoot = new CompoundTag();
      listRoot.put("deep", nest(true, depth - 1));
      rows.add(verdict("list_depth_" + depth, "disk", disk(listRoot)));
    }
    for (int cut : new int[]{1, 2, 3, 10, 100, valid.length / 2, valid.length - 1})
      rows.add(verdict("truncated_" + cut, "disk", Arrays.copyOf(valid, cut)));
    // Raw byte layouts that the tag classes cannot produce.
    rows.add(verdict("duplicate_name", "disk", HEX.parseHex("0a0000" + "030001610000000103000161000000020" + "0")));
    rows.add(verdict("unknown_tag", "disk", HEX.parseHex("0a0000" + "0d00017800" + "00")));
    rows.add(verdict("negative_list", "disk", HEX.parseHex("0a0000" + "0900016c03ffffffff" + "00")));
    rows.add(verdict("negative_array", "disk", HEX.parseHex("0a0000" + "0b000161ffffffff" + "00")));
    rows.add(verdict("end_list_nonempty", "disk", HEX.parseHex("0a0000" + "0900016c0000000001" + "00")));
    rows.add(verdict("end_list_empty", "disk", HEX.parseHex("0a0000" + "0900016c0000000000" + "00")));
    rows.add(verdict("bad_utf", "disk", HEX.parseHex("0a0000" + "08000173" + "0001ff" + "00")));
    rows.add(verdict("overlong_nul", "disk", HEX.parseHex("0a0000" + "08000173" + "0002c080" + "00")));
    rows.add(verdict("lone_surrogate", "disk", HEX.parseHex("0a0000" + "08000173" + "0003eda080" + "00")));
    rows.add(verdict("named_root", "disk", HEX.parseHex("0a0004726f6f74" + "0300016100000005" + "00")));
    rows.add(verdict("int_root", "disk", HEX.parseHex("03000000000005")));
    rows.add(verdict("end_root", "disk", HEX.parseHex("00")));
    rows.add(verdict("network_compound", "network", HEX.parseHex("0a" + "0300016100000005" + "00")));
    rows.add(verdict("network_string", "network", HEX.parseHex("08" + "0003" + "616263")));
    return rows;
  }

  // ---- verification of ValiMC's re-encodings ----

  static void verify(Path facts, Path dir) throws Exception {
    var root = JsonParser.parseString(Files.readString(facts)).getAsJsonObject();
    var files = root.getAsJsonArray("files");
    int checked = 0;
    for (int i = 0; i < files.size(); i++) {
      var row = files.get(i).getAsJsonObject();
      var raw = Files.readAllBytes(dir.resolve("file-" + i + ".bin"));
      var tag = readDisk(raw, row.get("compression").getAsString());
      if (!digest(tag).equals(row.get("digest").getAsString()))
        throw new AssertionError("re-encoded " + row.get("path").getAsString() + " differs");
      checked++;
    }
    var cases = root.getAsJsonArray("cases");
    int accepted = 0;
    for (int i = 0; i < cases.size(); i++) {
      var row = cases.get(i).getAsJsonObject();
      var path = dir.resolve("case-" + i + ".bin");
      if (!Files.exists(path)) continue;
      var in = new DataInputStream(new ByteArrayInputStream(Files.readAllBytes(path)));
      Tag tag = row.get("framing").getAsString().equals("disk") ? NbtIo.read(in, NbtAccounter.unlimitedHeap()) : NbtIo.readAnyTag(in, NbtAccounter.unlimitedHeap());
      if (in.available() != 0 || !digest(tag).equals(row.get("digest").getAsString()))
        throw new AssertionError("re-encoded case " + row.get("name").getAsString() + " differs");
      accepted++;
    }
    if (checked != files.size() || accepted == 0) throw new AssertionError("nothing verified");
    System.out.println("PASS: vanilla reads back " + checked + " ValiMC-encoded world payloads and " + accepted + " edge cases with equal values");
  }
}
