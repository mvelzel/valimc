import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.*;
import net.minecraft.network.syncher.*;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.item.ItemEntity;
import java.nio.file.*;
import java.lang.reflect.*;
import java.util.*;

/** Original native codec, metadata-setter and load-counter probe; no gameplay server. */
public class PlayerInputOracle {
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getNextEntityId(){return 300;}
  }
  private static final HexFormat HEX=HexFormat.of();
  private static sun.misc.Unsafe unsafe;
  private static String hex(FriendlyByteBuf b) {
    byte[] bytes=new byte[b.readableBytes()];b.getBytes(b.readerIndex(),bytes);return HEX.formatHex(bytes);
  }
  private static Method method(Class<?> owner,String name,Class<?>... args) throws Exception {
    var m=owner.getDeclaredMethod(name,args);m.setAccessible(true);return m;
  }
  public static void main(String[] args) throws Throwable {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);unsafe=(sun.misc.Unsafe)f.get(null);
    var output=new JsonObject();var inputs=new JsonArray();var commands=new JsonArray();
    var loads=new JsonArray();var metadata=new JsonArray();
    for(int flags=0;flags<256;flags++) {
      var b=new FriendlyByteBuf(Unpooled.buffer());
      try {
        b.writeByte(flags);var p=ServerboundPlayerInputPacket.STREAM_CODEC.decode(b);
        if(b.isReadable())throw new AssertionError("Trailing input");
        var c=new JsonObject();c.addProperty("byte",flags);
        var input=p.input();var booleans=new JsonArray();
        for(boolean v:new boolean[]{input.forward(),input.backward(),input.left(),input.right(),input.jump(),input.shift(),input.sprint()})booleans.add(v);
        c.add("booleans",booleans);b.clear();ServerboundPlayerInputPacket.STREAM_CODEC.encode(b,p);
        c.addProperty("canonical",hex(b));inputs.add(c);
      } finally {b.release();}
    }
    for(int id:new int[]{Integer.MIN_VALUE,-1,0,300,Integer.MAX_VALUE})
      for(int data:new int[]{Integer.MIN_VALUE,-1,0,1,Integer.MAX_VALUE})
        for(var action:ServerboundPlayerCommandPacket.Action.values()) {
          var b=new FriendlyByteBuf(Unpooled.buffer());
          try {
            b.writeVarInt(id);b.writeEnum(action);b.writeVarInt(data);String bytes=hex(b);
            var p=ServerboundPlayerCommandPacket.STREAM_CODEC.decode(b);
            if(b.isReadable()||p.getId()!=id||p.getAction()!=action||p.getData()!=data)throw new AssertionError("Command decode");
            var c=new JsonObject();c.addProperty("id",id);c.addProperty("data",data);
            c.addProperty("action",action.name().toLowerCase(Locale.ROOT));c.addProperty("payload",bytes);commands.add(c);
          } finally {b.release();}
        }
    for(String payload:List.of("","01","0101","010700","01ffffffff0f00","808080808080")) {
      var b=new FriendlyByteBuf(Unpooled.wrappedBuffer(HEX.parseHex(payload)));
      try {
        boolean rejected=false;try{ServerboundPlayerCommandPacket.STREAM_CODEC.decode(b);}catch(Exception e){rejected=true;}
        if(!rejected)throw new AssertionError("Native accepted invalid command "+payload);
      } finally {b.release();}
    }
    var restart=method(ServerGamePacketListenerImpl.class,"restartClientLoadTimerAfterRespawn");
    var mark=method(ServerGamePacketListenerImpl.class,"markClientLoaded");
    for(int ticks=0;ticks<=64;ticks++) {
      var listener=(ServerGamePacketListenerImpl)unsafe.allocateInstance(ServerGamePacketListenerImpl.class);
      restart.invoke(listener);for(int n=0;n<ticks;n++)listener.tickClientLoadTimeout();
      var c=new JsonObject();c.addProperty("ticks",ticks);c.addProperty("loaded",listener.hasClientLoaded());
      mark.invoke(listener);c.addProperty("marked_loaded",listener.hasClientLoaded());loads.add(c);
    }
    @SuppressWarnings("unchecked") var itemType=(EntityType<? extends ItemEntity>)(EntityType<?>)
      BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:item"));
    var entity=new ItemEntity(itemType,(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class));
    var flagsField=Entity.class.getDeclaredField("DATA_SHARED_FLAGS_ID");flagsField.setAccessible(true);
    @SuppressWarnings("unchecked") var accessor=(EntityDataAccessor<Byte>)flagsField.get(null);
    for(boolean shift:new boolean[]{false,true})for(boolean sprint:new boolean[]{false,true}) {
      entity.setShiftKeyDown(shift);entity.setSprinting(sprint);
      byte flags=entity.getEntityData().get(accessor);
      var p=new ClientboundSetEntityDataPacket(300,List.of(new SynchedEntityData.DataValue<>(accessor.id(),accessor.serializer(),flags)));
      var b=new RegistryFriendlyByteBuf(Unpooled.buffer(),RegistryAccess.EMPTY);
      try {
        ClientboundSetEntityDataPacket.STREAM_CODEC.encode(b,p);
        var c=new JsonObject();c.addProperty("shift",shift);c.addProperty("sprint",sprint);
        c.addProperty("flags",flags);c.addProperty("payload",hex(b));metadata.add(c);
        var decoded=ClientboundSetEntityDataPacket.STREAM_CODEC.decode(b);
        if(b.isReadable()||!decoded.equals(p))throw new AssertionError("Metadata round trip");
      } finally {b.release();}
    }
    output.add("inputs",inputs);output.add("commands",commands);output.add("loads",loads);output.add("metadata",metadata);
    Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: 256 native input codecs, "+commands.size()+" commands, 65 load counters and four native shared-flag metadata values.");
  }
}
