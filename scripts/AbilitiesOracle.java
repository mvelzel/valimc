import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.GameType;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundPlayerAbilitiesPacket;
import net.minecraft.network.protocol.game.ServerboundPlayerAbilitiesPacket;
import java.nio.file.*;
import java.util.*;

/** Original ability transition/codec probe. No vanilla world or gameplay server is started. */
public class AbilitiesOracle {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var output = new JsonObject(); var transitions = new JsonArray(); var requests = new JsonArray();
    for(var mode:GameType.values()) for(int flags=0;flags<16;flags++) {
      var a=new Abilities(); a.invulnerable=(flags&1)!=0; a.flying=(flags&2)!=0;
      a.mayfly=(flags&4)!=0; a.instabuild=(flags&8)!=0; a.mayBuild=false;
      a.setFlyingSpeed(0.2f); a.setWalkingSpeed(0.3f); mode.updatePlayerAbilities(a);
      var buf=new FriendlyByteBuf(Unpooled.buffer());
      try {
        ClientboundPlayerAbilitiesPacket.STREAM_CODEC.encode(buf,new ClientboundPlayerAbilitiesPacket(a));
        byte[] bytes=new byte[buf.readableBytes()];buf.getBytes(0,bytes);
        var decoded=ClientboundPlayerAbilitiesPacket.STREAM_CODEC.decode(buf);
        if(buf.isReadable()||decoded.isFlying()!=a.flying||decoded.canFly()!=a.mayfly||
           decoded.isInvulnerable()!=a.invulnerable||decoded.canInstabuild()!=a.instabuild||
           decoded.getFlyingSpeed()!=a.getFlyingSpeed()||decoded.getWalkingSpeed()!=a.getWalkingSpeed())
          throw new AssertionError("Ability round trip");
        var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("initial",flags);
        c.addProperty("build",a.mayBuild);c.addProperty("payload",HexFormat.of().formatHex(bytes));transitions.add(c);
      } finally {buf.release();}
    }
    for(int flags=0;flags<256;flags++) {
      var buf=new FriendlyByteBuf(Unpooled.buffer());
      try {
        buf.writeByte(flags);var packet=ServerboundPlayerAbilitiesPacket.STREAM_CODEC.decode(buf);
        if(buf.isReadable())throw new AssertionError("Unconsumed request");
        var c=new JsonObject();c.addProperty("flags",flags);c.addProperty("flying",packet.isFlying());
        ServerboundPlayerAbilitiesPacket.STREAM_CODEC.encode(buf,packet);
        c.addProperty("canonical",buf.readUnsignedByte());requests.add(c);
      } finally {buf.release();}
    }
    output.add("transitions",transitions);output.add("requests",requests);
    Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: 64 native mode/ability transitions and 256 native client flag decodes.");
  }
}
