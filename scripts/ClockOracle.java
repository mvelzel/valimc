import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.clock.ClockState;
import net.minecraft.world.clock.ClockNetworkState;
import net.minecraft.world.clock.ServerClockManager.ServerClockInstance;
import java.nio.file.*;
import java.util.HexFormat;

/** Original probe of Mojang's clock arithmetic and value codec; no gameplay server is started. */
public class ClockOracle {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    if (args[0].equals("verify")) {
      JsonArray cases=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for (var value:cases) {
        var c=value.getAsJsonObject();
        var buf=Unpooled.wrappedBuffer(HexFormat.of().parseHex(c.get("encoded").getAsString()));
        try {
          var actual=ClockNetworkState.STREAM_CODEC.decode(buf);
          var expected=new ClockNetworkState(c.get("total").getAsLong(),c.get("partial").getAsFloat(),c.get("rate").getAsFloat());
          if (buf.isReadable() || !actual.equals(expected)) throw new AssertionError("Clock network mismatch: "+c);
        } finally { buf.release(); }
      }
      System.out.println("PASS: Mojang decoded "+cases.size()+" Elixir clock network values.");
      return;
    }
    var cases=new JsonArray();
    for (float rate:new float[]{0f,.1f,.25f,.5f,1f,1.1f,2f,20f,1024f})
    for (float partial:new float[]{0f,-0f,.1f,.99999994f})
    for (long total:new long[]{0L,23999L,Long.MAX_VALUE,Long.MIN_VALUE,-1L})
    for (boolean paused:new boolean[]{false,true})
    for (boolean advance:new boolean[]{false,true})
    for (int ticks:new int[]{0,1,2,20,101}) {
      var clock=new ServerClockInstance(); clock.loadFrom(new ClockState(total,partial,rate,paused));
      if (advance) for(int i=0;i<ticks;i++) clock.tick();
      var end=clock.packState();
      var network=new ClockNetworkState(end.totalTicks(),end.partialTick(),paused||!advance?0f:end.rate());
      var c=new JsonObject();
      c.addProperty("initial_total",total);c.addProperty("initial_partial",(double)partial);
      c.addProperty("initial_rate",(double)rate);c.addProperty("paused",paused);
      c.addProperty("advance",advance);c.addProperty("ticks",ticks);
      c.addProperty("total",end.totalTicks());c.addProperty("partial",(double)end.partialTick());
      c.addProperty("rate",(double)network.rate());
      var buf=Unpooled.buffer();
      try { ClockNetworkState.STREAM_CODEC.encode(buf,network);
        byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);
        c.addProperty("encoded",HexFormat.of().formatHex(bytes));
      } finally {buf.release();}
      cases.add(c);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: generated "+cases.size()+" actual Mojang clock arithmetic/value fixtures.");
  }
}
