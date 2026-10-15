import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundSectionBlocksUpdatePacket;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import java.nio.file.*;
import java.util.*;

/** Original native codec probe of Elixir-prepared block batches; no world server. */
public class BlockBatchOracle {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var cases=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonArray();
    int updates=0;
    for(var entry:cases) {
      var c=entry.getAsJsonObject();var bytes=HexFormat.of().parseHex(c.get("payload").getAsString());
      var buffer=new FriendlyByteBuf(Unpooled.wrappedBuffer(bytes));
      var encoded=new FriendlyByteBuf(Unpooled.buffer());
      try {
        var packet=ClientboundSectionBlocksUpdatePacket.STREAM_CODEC.decode(buffer);
        if(buffer.isReadable())throw new AssertionError("Trailing packet data");
        var actual=new JsonArray();packet.runUpdates((pos,state)->{
          if(state==null)throw new AssertionError("Invalid block state");
          var row=new JsonArray();row.add(pos.getX());row.add(pos.getY());row.add(pos.getZ());row.add(Block.getId(state));actual.add(row);
        });
        if(!actual.equals(c.getAsJsonArray("edits")))throw new AssertionError("Native coordinates/state/order mismatch");
        ClientboundSectionBlocksUpdatePacket.STREAM_CODEC.encode(encoded,packet);
        byte[] roundtrip=new byte[encoded.readableBytes()];encoded.readBytes(roundtrip);
        if(!Arrays.equals(bytes,roundtrip))throw new AssertionError("Native re-encoding mismatch");
        updates+=actual.size();
      } finally {buffer.release();encoded.release();}
    }
    System.out.println("PASS: "+cases.size()+" native section codecs, "+updates+" ordered block updates and byte-identical re-encoding.");
  }
}
