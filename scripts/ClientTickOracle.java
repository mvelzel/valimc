import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.network.PacketProcessor;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.game.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import java.nio.file.*;
import java.lang.reflect.*;
import java.util.*;

/** Original handler-order probe. No world startup, network listener or EULA acceptance. */
public class ClientTickOracle {
  private static sun.misc.Unsafe unsafe;
  private static MinecraftServer server;
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel() { super(null,null,null,null,null,null,false,0L,List.of(),false); }
    public MinecraftServer getServer() { return server; }
  }
  private static class ProbeListener extends ServerGamePacketListenerImpl {
    boolean rejected;
    private ProbeListener() { super(null,null,null,null); }
    public void disconnect(Component reason) { rejected=true; }
  }
  private static void field(Object target,Class<?> owner,String name,Object value) throws Exception {
    var f=owner.getDeclaredField(name);f.setAccessible(true);f.set(target,value);
  }
  private static boolean position(ProbeListener listener) throws Exception {
    var f=ServerGamePacketListenerImpl.class.getDeclaredField("receivedPositionThisTick");
    f.setAccessible(true);return f.getBoolean(listener);
  }
  private static ProbeListener listener(boolean wonGame) throws Exception {
    var l=(ProbeListener)unsafe.allocateInstance(ProbeListener.class);
    var p=(ServerPlayer)unsafe.allocateInstance(ServerPlayer.class);
    field(p,net.minecraft.world.entity.Entity.class,"level",unsafe.allocateInstance(ProbeLevel.class));
    // Native won-game or pre-load gates return after admission, before simulation.
    p.wonGame=wonGame;l.player=p;
    field(l,ServerGamePacketListenerImpl.class,"tickCount",1);
    field(l,ServerGamePacketListenerImpl.class,"clientLoadedTimeoutTimer",60);
    return l;
  }
  private static void event(ProbeListener l,String name) {
    switch(name) {
      case "pos" -> l.handleMovePlayer(new ServerboundMovePlayerPacket.Pos(.5,64,.5,true,false));
      case "pos_rot" -> l.handleMovePlayer(new ServerboundMovePlayerPacket.PosRot(.5,64,.5,0,0,true,false));
      case "rot" -> l.handleMovePlayer(new ServerboundMovePlayerPacket.Rot(0,0,true,false));
      case "status" -> l.handleMovePlayer(new ServerboundMovePlayerPacket.StatusOnly(true,false));
      case "end" -> l.handleClientTickEnd(new ServerboundClientTickEndPacket());
      default -> throw new AssertionError(name);
    }
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);
    unsafe=(sun.misc.Unsafe)f.get(null);
    server=(MinecraftServer)unsafe.allocateInstance(DedicatedServer.class);
    field(server,MinecraftServer.class,"packetProcessor",new PacketProcessor(Thread.currentThread()));
    var output=new JsonArray();String[] events={"pos","pos_rot","rot","status","end"};
    for(boolean wonGame:new boolean[]{false,true})for(int code=0;code<625;code++) {
      var l=listener(wonGame);var trace=new JsonArray();int n=code;
      for(int step=0;step<4;step++) {
        String name=events[n%5];n/=5;event(l,name);
        var row=new JsonObject();row.addProperty("event",name);
        row.addProperty("rejected",l.rejected);row.addProperty("position",position(l));trace.add(row);
        if(l.rejected)break;
      }
      var c=new JsonObject();c.addProperty("gate",wonGame?"won_game":"pre_load");
      c.add("events",trace);output.add(c);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: 1,250 actual native client-tick handler traces through pre-load/won-game gates; no simulation.");
  }
}
