import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.*;
import net.minecraft.network.syncher.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.phys.Vec3;

/** Original observations of native XP splitting/icons and native entity codecs. */
public class ExperienceOrbOracle {
  static RegistryAccess.Frozen registries;
  static final UUID UUID_VALUE = UUID.fromString("00010203-0405-0607-0809-0a0b0c0d0e0f");
  static final HexFormat HEX = HexFormat.of();
  static EntityDataAccessor<Integer> valueAccessor;
  static EntityDataAccessor<Boolean> gravityAccessor;
  static CookingExperienceOracle.World world;

  static Map<Integer,Integer> split(int remaining) {
    var counts = new TreeMap<Integer,Integer>();
    while (remaining > 0) {
      int value = ExperienceOrb.getExperienceValue(remaining);
      counts.merge(value, 1, Integer::sum); remaining -= value;
    }
    return counts;
  }

  static Vec3 vector(JsonArray row) {
    return new Vec3(row.get(0).getAsDouble(), row.get(1).getAsDouble(), row.get(2).getAsDouble());
  }

  static Map<String,Object> packets(JsonObject row) {
    int id = row.get("id").getAsInt(), value = row.get("value").getAsInt();
    var pos = vector(row.getAsJsonArray("position"));
    var velocity = vector(row.getAsJsonArray("velocity"));
    var result = new TreeMap<String,Object>();
    result.put("spawn", new ClientboundAddEntityPacket(id, UUID_VALUE, pos.x, pos.y, pos.z,
      0, 0, EntityTypes.EXPERIENCE_ORB, 0, velocity, 0));
    result.put("metadata", new ClientboundSetEntityDataPacket(id, List.of(
      new SynchedEntityData.DataValue<>(gravityAccessor.id(), gravityAccessor.serializer(), true),
      new SynchedEntityData.DataValue<>(valueAccessor.id(), valueAccessor.serializer(), value))));
    result.put("motion", new ClientboundSetEntityMotionPacket(id, velocity));
    result.put("position", new ClientboundEntityPositionSyncPacket(id, PositionPath.of(pos), 0, 0, false));
    result.put("remove", new ClientboundRemoveEntitiesPacket(id));
    return result;
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  static String encode(Object packet) {
    var buffer = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      var protocol = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, registries));
      protocol.codec().encode(buffer, (net.minecraft.network.protocol.Packet)packet);
      byte[] bytes = new byte[buffer.readableBytes()]; buffer.readBytes(bytes);
      return HEX.formatHex(bytes);
    } finally { buffer.release(); }
  }

  static void verifyPacket(Object expected, String wire) {
    if (!encode(expected).equals(wire)) throw new AssertionError("Native encoding differs");
    var buffer = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HEX.parseHex(wire)), registries);
    try {
      var protocol = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, registries));
      var decoded = protocol.codec().decode(buffer);
      if (buffer.isReadable() || decoded.getClass() != expected.getClass() || !encode(decoded).equals(wire))
        throw new AssertionError("Native decoding differs or has trailing bytes");
    } finally { buffer.release(); }
  }

  @SuppressWarnings("unchecked")
  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    registries = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    CookingExperienceOracle.access = registries;
    var unsafeField = sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); unsafeField.setAccessible(true);
    var unsafe = (sun.misc.Unsafe)unsafeField.get(null);
    world = (CookingExperienceOracle.World)unsafe.allocateInstance(CookingExperienceOracle.World.class);
    world.random = RandomSource.create(17);
    var field = ExperienceOrb.class.getDeclaredField("DATA_VALUE"); field.setAccessible(true);
    valueAccessor = (EntityDataAccessor<Integer>)field.get(null);
    field = Entity.class.getDeclaredField("DATA_NO_GRAVITY"); field.setAccessible(true);
    gravityAccessor = (EntityDataAccessor<Boolean>)field.get(null);

    if (args[0].equals("generate")) {
      var amounts = new TreeSet<Integer>();
      for (int amount = 0; amount <= 16384; amount++) amounts.add(amount);
      for (int amount = Integer.MAX_VALUE - 8; amount < Integer.MAX_VALUE; amount++) amounts.add(amount);
      amounts.add(Integer.MAX_VALUE);
      var random = new Random(2603);
      for (int i = 0; i < 64; i++) amounts.add(random.nextInt(Integer.MAX_VALUE));
      var splits = new JsonArray();
      for (int amount : amounts) {
        var row = new JsonObject(); row.addProperty("amount", amount);
        row.add("groups", new Gson().toJsonTree(split(amount))); splits.add(row);
      }
      var entities = new JsonArray();
      for (int value : new int[]{1,3,7,17,37,73,149,307,617,1237,2477,128,Integer.MAX_VALUE})
        for (int index = 0; index < 3; index++) {
          var row = new JsonObject(); row.addProperty("id", new int[]{1,128,Integer.MAX_VALUE}[index]);
          row.addProperty("value", value);
          row.addProperty("icon", new ExperienceOrb(world, 0, 64, 0, value).getIcon());
          row.add("position", new Gson().toJsonTree(new double[][]{
            {0,64,0},{-3.25,-64,16.000001},{29_999_984,1_000_000,-29_999_984}}[index]));
          row.add("velocity", new Gson().toJsonTree(new double[][]{{0,0,0},{.1,.2,-.3},{-4,2.5,-1.75}}[index]));
          var wires = new TreeMap<String,String>(); packets(row).forEach((kind, packet) -> wires.put(kind, encode(packet)));
          row.add("wires", new Gson().toJsonTree(wires)); entities.add(row);
        }
      Files.writeString(Path.of(args[1]), new Gson().toJson(Map.of("version", "26.3", "server_sha1",
        "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c", "splits", splits, "entities", entities)));
      System.out.println("PASS: native " + splits.size() + " XP histograms and 195 orb packets/icons generated.");
    } else {
      var raw = JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonObject();
      var rows = raw.getAsJsonArray("entities");
      if (rows.size() != 39) throw new AssertionError("Missing entities");
      for (var element : rows) {
        var row = element.getAsJsonObject();
        for (var entry : packets(row).entrySet())
          verifyPacket(entry.getValue(), row.getAsJsonObject("wires").get(entry.getKey()).getAsString());
      }
      System.out.println("PASS: native decoded 195 Elixir XP spawn/metadata/motion/position/removal packets.");
    }
  }
}
