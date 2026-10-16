import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.PositionPath;
import net.minecraft.world.phys.Vec3;

/** Original actual 26.3 linear entity-position packet encoding and decoding. */
public class EntityPositionOracle {
  static RegistryAccess.Frozen registries;
  static final HexFormat HEX = HexFormat.of();

  static ClientboundEntityPositionSyncPacket packet(JsonObject row) {
    var position = new Vec3(row.get("x").getAsDouble(), row.get("y").getAsDouble(), row.get("z").getAsDouble());
    return new ClientboundEntityPositionSyncPacket(row.get("id").getAsInt(), PositionPath.of(position),
      row.get("yaw").getAsFloat(), row.get("pitch").getAsFloat(), row.get("ground").getAsBoolean());
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  static String encode(ClientboundEntityPositionSyncPacket packet) {
    var buffer = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      var protocol = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, registries));
      protocol.codec().encode(buffer, (net.minecraft.network.protocol.Packet) packet);
      byte[] bytes = new byte[buffer.readableBytes()]; buffer.readBytes(bytes);
      return HEX.formatHex(bytes);
    } finally { buffer.release(); }
  }

  static void verify(JsonObject row) {
    var expected = packet(row);
    String wire = row.get("wire").getAsString();
    if (!encode(expected).equals(wire)) throw new AssertionError("Position bytes differ: " + row);
    var buffer = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HEX.parseHex(wire)), registries);
    try {
      var protocol = GameProtocols.CLIENTBOUND_TEMPLATE.bind(b -> new RegistryFriendlyByteBuf(b, registries));
      var decoded = protocol.codec().decode(buffer);
      if (buffer.isReadable() || !(decoded instanceof ClientboundEntityPositionSyncPacket actual) ||
          !actual.equals(expected) || !(actual.position() instanceof PositionPath.Linear))
        throw new AssertionError("Decoded position differs: " + row);
    } finally { buffer.release(); }
  }

  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    registries = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    if (args[0].equals("generate")) {
      var rows = new JsonArray();
      var positions = List.of(Vec3.ZERO, new Vec3(8.5,64.25,12.5), new Vec3(-.5,-64,16.000001),
        new Vec3(29_999_984,1_000_000,-29_999_984), new Vec3(-29_999_984,-1_000_000,29_999_984),
        new Vec3(Math.nextDown(16.0),Math.nextUp(64.0),Math.nextDown(-16.0)));
      float[][] rotations = {{0,0},{180,-90},{359.9f,15.3f},{-1_000_000,1_000_000},{Float.MIN_VALUE,-Float.MIN_VALUE}};
      for (int id : new int[]{1,127,128,300,Integer.MAX_VALUE}) for (Vec3 pos : positions)
        for (float[] rotation : rotations) for (boolean ground : new boolean[]{false,true}) {
          var row = new JsonObject(); row.addProperty("id",id);
          row.addProperty("x",pos.x); row.addProperty("y",pos.y); row.addProperty("z",pos.z);
          row.addProperty("yaw",(double)rotation[0]); row.addProperty("pitch",(double)rotation[1]);
          row.addProperty("ground",ground); row.addProperty("wire",encode(packet(row))); rows.add(row);
        }
      Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
      System.out.println("PASS: generated " + rows.size() + " native linear entity-position packets.");
    } else {
      var rows = JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      if (rows.size()!=300) throw new AssertionError("Incomplete position observations");
      for (var row : rows) verify(row.getAsJsonObject());
      System.out.println("PASS: native decoded 300 Elixir linear entity-position packets, exact fields/path and no trailing bytes.");
    }
  }
}
