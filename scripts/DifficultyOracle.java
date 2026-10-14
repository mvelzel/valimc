import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.dedicated.DedicatedPlayerList;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.Difficulty;
import net.minecraft.world.level.storage.WorldData;
import net.minecraft.network.protocol.game.ClientboundChangeDifficultyPacket;
import sun.misc.Unsafe;
import java.lang.reflect.*;
import java.util.*;
import java.nio.file.*;

/** Original isolated probe of actual vanilla difficulty controls/codecs; no world/server is started. */
public class DifficultyOracle {
  private static Difficulty difficulty;
  private static boolean locked;
  private static DedicatedPlayerList players;
  private static class ProbePlayers extends DedicatedPlayerList {
    ProbePlayers(){super(null,null,null);}
    public List<ServerPlayer> getPlayers(){return List.of();}
  }
  private static class ProbeServer extends DedicatedServer {
    ProbeServer(){super(null,null,null,null,null,null,null,null,null,null);}
    public DedicatedPlayerList getPlayerList(){return players;}
    public void updateMobSpawningFlags(){}
  }
  private static Field field(Class<?> type,String name) throws Exception {
    var f=type.getDeclaredField(name);f.setAccessible(true);return f;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(Unsafe)field(Unsafe.class,"theUnsafe").get(null);
    players=(DedicatedPlayerList)unsafe.allocateInstance(ProbePlayers.class);
    var server=(MinecraftServer)unsafe.allocateInstance(ProbeServer.class);
    var data=(WorldData)java.lang.reflect.Proxy.newProxyInstance(WorldData.class.getClassLoader(),new Class<?>[]{WorldData.class},(proxy,method,values)-> {
      return switch(method.getName()) {
        case "isHardcore" -> false;
        case "getDifficulty" -> difficulty;
        case "isDifficultyLocked" -> locked;
        case "setDifficulty" -> {difficulty=(Difficulty)values[0];yield null;}
        case "setDifficultyLocked" -> {locked=(Boolean)values[0];yield null;}
        default -> throw new AssertionError(method);
      };
    });
    field(MinecraftServer.class,"worldData").set(server,data);
    var result=new JsonObject();var changes=new JsonArray();var packets=new JsonArray();
    result.addProperty("default",new net.minecraft.server.dedicated.DedicatedServerProperties(new Properties()).difficulty.get().getId());
    for(var initial:Difficulty.values()) for(var target:Difficulty.values())
    for(boolean lock:new boolean[]{false,true}) for(boolean force:new boolean[]{false,true}) {
      difficulty=initial;locked=lock;server.setDifficulty(target,force);
      var c=new JsonObject();c.addProperty("initial",initial.getId());c.addProperty("target",target.getId());
      c.addProperty("locked",lock);c.addProperty("force",force);c.addProperty("result",difficulty.getId());changes.add(c);
      server.setDifficultyLocked(!lock);if(locked==lock)throw new AssertionError("Lock was not changed");
    }
    for(var level:Difficulty.values()) for(boolean lock:new boolean[]{false,true}) {
      var packet=new ClientboundChangeDifficultyPacket(level,lock);var buf=Unpooled.buffer();
      try {
        ClientboundChangeDifficultyPacket.STREAM_CODEC.encode(buf,packet);
        byte[] bytes=new byte[buf.readableBytes()];buf.getBytes(0,bytes);
        if(!ClientboundChangeDifficultyPacket.STREAM_CODEC.decode(buf).equals(packet)||buf.isReadable())throw new AssertionError("Codec mismatch");
        var c=new JsonObject();c.addProperty("level",level.getId());c.addProperty("locked",lock);
        c.addProperty("payload",HexFormat.of().formatHex(bytes));packets.add(c);
      } finally {buf.release();}
    }
    result.add("changes",changes);result.add("packets",packets);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+changes.size()+" actual native lock/force cases and "+packets.size()+" difficulty codec cases.");
  }
}
