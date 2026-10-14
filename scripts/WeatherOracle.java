import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.dedicated.DedicatedPlayerList;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.saveddata.WeatherData;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.util.RandomSource;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.ClientboundGameEventPacket;
import net.minecraft.resources.ResourceKey;
import sun.misc.Unsafe;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import java.nio.file.*;

/** Original constructor-free probe of the actual vanilla weather method; no server/world is launched. */
public class WeatherOracle {
  private static WeatherData weather;
  private static GameRules rules;
  private static boolean enabled;
  private static DedicatedPlayerList players;
  private static final List<String> events=new ArrayList<>();
  private static class ProbePlayers extends DedicatedPlayerList {
    ProbePlayers(){super(null,null,null);}
    public void broadcastAll(Packet<?> packet){capture(packet);}
    public void broadcastAll(Packet<?> packet, ResourceKey<Level> dimension){capture(packet);}
  }
  private static class ProbeServer extends DedicatedServer {
    ProbeServer(){super(null,null,null,null,null,null,null,null,null,null);}
    public DedicatedPlayerList getPlayerList(){return players;}
  }
  private static class ProbeLevel extends ServerLevel {
    ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public WeatherData getWeatherData(){return weather;}
    public GameRules getGameRules(){return rules;}
    public boolean canHaveWeather(){return enabled;}
  }
  private static void capture(Packet<?> p){
    if (!(p instanceof ClientboundGameEventPacket event)) throw new AssertionError("Unexpected packet");
    var buf=new FriendlyByteBuf(Unpooled.buffer());
    try {ClientboundGameEventPacket.STREAM_CODEC.encode(buf,event); byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);events.add(HexFormat.of().formatHex(bytes));}
    finally {buf.release();}
  }
  private static Field field(Class<?> type,String name) throws Exception {var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(Unsafe)field(Unsafe.class,"theUnsafe").get(null);
    players=(DedicatedPlayerList)unsafe.allocateInstance(ProbePlayers.class);
    var server=(DedicatedServer)unsafe.allocateInstance(ProbeServer.class);
    var level=(ServerLevel)unsafe.allocateInstance(ProbeLevel.class);
    field(ServerLevel.class,"server").set(level,server);
    var step=ServerLevel.class.getDeclaredMethod("advanceWeatherCycle");step.setAccessible(true);
    rules=new GameRules(FeatureFlagSet.of()); enabled=true;
    var all=new JsonArray();
    for(long seed:new long[]{0L,1L,-1L,8675309L})
    for(int timer:new int[]{-1,0,1,2,100})
    for(int clear:new int[]{0,1,2})
    for(int flags=0;flags<4;flags++)
    for(boolean advance:new boolean[]{false,true}) {
      weather=new WeatherData(clear,timer,timer,(flags&1)!=0,(flags&2)!=0);
      rules.set(GameRules.ADVANCE_WEATHER,advance,null);
      RandomSource random=RandomSource.create(seed);field(Level.class,"random").set(level,random);
      long initial=((AtomicLong)field(random.getClass(),"seed").get(random)).get();
      field(Level.class,"rainLevel").setFloat(level,0.0f);field(Level.class,"thunderLevel").setFloat(level,0.0f);
      field(Level.class,"oRainLevel").setFloat(level,0.0f);field(Level.class,"oThunderLevel").setFloat(level,0.0f);
      var c=new JsonObject();c.addProperty("seed",initial);c.addProperty("timer",timer);c.addProperty("clear",clear);c.addProperty("flags",flags);c.addProperty("advance",advance);
      var trace=new JsonArray();
      for(int tick=0;tick<105;tick++) {
        events.clear();step.invoke(level);
        var state=new JsonObject();state.addProperty("clear",weather.getClearWeatherTime());state.addProperty("rain_time",weather.getRainTime());state.addProperty("thunder_time",weather.getThunderTime());
        state.addProperty("raining",weather.isRaining());state.addProperty("thundering",weather.isThundering());
        state.addProperty("rain",(double)field(Level.class,"rainLevel").getFloat(level));state.addProperty("thunder",(double)field(Level.class,"thunderLevel").getFloat(level));
        state.addProperty("seed",((AtomicLong)field(random.getClass(),"seed").get(random)).get());state.add("events",new Gson().toJsonTree(events));trace.add(state);
      }
      c.add("trace",trace);all.add(c);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(all));
    System.out.println("PASS: "+all.size()+" actual vanilla weather traces, "+(all.size()*105)+" ticks.");
  }
}
