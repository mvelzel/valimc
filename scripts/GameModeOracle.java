import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.dimension.DimensionType;
import net.minecraft.world.level.dimension.BuiltinDimensionTypes;
import java.nio.file.*;
import java.util.*;

/** Original mode/spawn codec probe using real vanilla dimension values; no gameplay server. */
public class GameModeOracle {
  private static RegistryAccess.Frozen access;
  private static Holder<DimensionType> overworld;
  private static RegistryFriendlyByteBuf buffer() { return new RegistryFriendlyByteBuf(Unpooled.buffer(),access); }
  private static String hex(RegistryFriendlyByteBuf buf) {
    byte[] bytes=new byte[buf.readableBytes()];buf.getBytes(buf.readerIndex(),bytes);return HexFormat.of().formatHex(bytes);
  }
  private static final int VIEW_DISTANCE=10,SIMULATION_DISTANCE=10;
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup().lookupOrThrow(Registries.DIMENSION_TYPE);
    var dimensions=new MappedRegistry<DimensionType>(Registries.DIMENSION_TYPE,Lifecycle.stable());
    for(var key:lookup.listElementIds().sorted(Comparator.comparing(k -> k.identifier().toString())).toList())
      dimensions.register(key,lookup.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);
    dimensions.freeze(); access=new RegistryAccess.ImmutableRegistryAccess(List.of(dimensions)).freeze();
    overworld=dimensions.getOrThrow(BuiltinDimensionTypes.OVERWORLD);
    if(args[0].equals("verify")) { verify(args[1]);return; }
    var output=new JsonObject();var logins=new JsonArray();var requests=new JsonArray();
    for(var current:GameType.values()) for(int previous=-1;previous<4;previous++) {
      var prior=previous==-1?Optional.<GameType>empty():Optional.of(GameType.byId(previous));
      var spawn=new CommonPlayerSpawnInfo(overworld,Level.OVERWORLD,0L,current,prior,false,true,Optional.empty(),0,63);
      // Vanilla's default view-distance and simulation-distance (VMC-070).
      var login=new ClientboundLoginPacket(42,false,Set.of(Level.OVERWORLD),512,VIEW_DISTANCE,SIMULATION_DISTANCE,false,true,false,spawn,false,false);
      var buf=buffer();try {
        ClientboundLoginPacket.STREAM_CODEC.encode(buf,login);
        var c=new JsonObject();c.addProperty("current",current.getId());c.addProperty("previous",previous);
        c.addProperty("login",hex(buf));logins.add(c);
        if(!ClientboundLoginPacket.STREAM_CODEC.decode(buf).equals(login)||buf.isReadable())throw new AssertionError("Login round trip");
      } finally {buf.release();}
    }
    for(int id:new int[]{-1,0,1,2,3,4,127,Integer.MAX_VALUE,Integer.MIN_VALUE}) {
      var buf=buffer();try {
        buf.writeVarInt(id);var request=ServerboundChangeGameModePacket.STREAM_CODEC.decode(buf);
        if(buf.isReadable())throw new AssertionError("Request tail");
        var c=new JsonObject();c.addProperty("id",id);c.addProperty("mode",request.mode().getId());requests.add(c);
      } finally {buf.release();}
    }
    output.addProperty("view_distance",VIEW_DISTANCE);output.addProperty("simulation_distance",SIMULATION_DISTANCE);
    output.add("logins",logins);output.add("requests",requests);Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: 20 native current/previous-mode login packets and nine request enum boundaries.");
  }
  private static void verify(String path) throws Exception {
    var fixtures=JsonParser.parseString(Files.readString(Path.of(path))).getAsJsonArray();int count=0;
    for(var element:fixtures) {
      var c=element.getAsJsonObject();var buf=buffer();try {
        buf.writeBytes(HexFormat.of().parseHex(c.get("login").getAsString()));
        var spawn=ClientboundLoginPacket.STREAM_CODEC.decode(buf).commonPlayerSpawnInfo();
        if(buf.isReadable()||spawn.gameType().getId()!=c.get("current").getAsInt()||
          spawn.previousGameType().map(GameType::getId).orElse(-1)!=c.get("previous").getAsInt())throw new AssertionError("Elixir spawn modes");
        buf.clear();buf.writeBytes(HexFormat.of().parseHex(c.get("info").getAsString()));
        var packet=ClientboundPlayerInfoUpdatePacket.STREAM_CODEC.decode(buf);
        if(buf.isReadable()||packet.entries().size()!=1||packet.entries().getFirst().gameMode()!=spawn.gameType())
          throw new AssertionError("Elixir player-info mode");count++;
      } finally {buf.release();}
    }
    System.out.println("PASS: native decoding of "+count+" Elixir login/player-info mode pairs.");
  }
}
