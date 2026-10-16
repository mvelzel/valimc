import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.MobEffectInstance;

/** Original stock effect-holder and complete update/remove packet fixtures, without gameplay. */
public class StatusEffectPacketOracle {
  static RegistryAccess.Frozen access;
  @SuppressWarnings({"rawtypes","unchecked"})
  static String wire(Object packet){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().encode(buffer,(Packet)packet);byte[] bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}
  }
  static Object packet(JsonObject row){
    int entity=row.get("entity").getAsInt();var effect=BuiltInRegistries.MOB_EFFECT.get(row.get("effect").getAsInt()).orElseThrow();
    if(row.get("kind").getAsString().equals("remove"))return new ClientboundRemoveMobEffectPacket(entity,effect);
    int flags=row.get("flags").getAsInt();return new ClientboundUpdateMobEffectPacket(entity,new MobEffectInstance(effect,row.get("ticks").getAsInt(),row.get("level").getAsInt(),(flags&1)!=0,(flags&2)!=0,(flags&4)!=0),(flags&8)!=0);
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();access=new RegistryAccess.ImmutableRegistryAccess(List.of(BuiltInRegistries.MOB_EFFECT)).freeze();
    if(args[0].equals("verify")){
      var rows=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for(var entry:rows){var row=entry.getAsJsonObject();var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(row.get("wire").getAsString())),access);
        try{var decoded=GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().decode(buffer);if(buffer.isReadable()||!wire(decoded).equals(wire(packet(row))))throw new AssertionError("Wrong native effect packet "+row);}finally{buffer.release();}}
      System.out.println("PASS: native decoding of "+rows.size()+" independently encoded complete status packets.");return;
    }
    var names=new JsonArray();for(var effect:BuiltInRegistries.MOB_EFFECT){int id=BuiltInRegistries.MOB_EFFECT.getId(effect);if(names.size()!=id)throw new AssertionError("Non-contiguous native effects");names.add(BuiltInRegistries.MOB_EFFECT.getKey(effect).toString());}
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.add("effects",names);
    var rows=new JsonArray();for(int effect=0;effect<names.size();effect++)for(int entity:new int[]{1,127,128,Integer.MAX_VALUE}){
      var remove=new JsonObject();remove.addProperty("kind","remove");remove.addProperty("effect",effect);remove.addProperty("entity",entity);remove.addProperty("wire",wire(packet(remove)));rows.add(remove);
      for(int level:new int[]{0,1,127,255})for(int ticks:new int[]{-1,0,1,127,128,Integer.MAX_VALUE})for(int flags=0;flags<16;flags++){
        var row=new JsonObject();row.addProperty("kind","update");row.addProperty("effect",effect);row.addProperty("entity",entity);row.addProperty("level",level);row.addProperty("ticks",ticks);row.addProperty("flags",flags);row.addProperty("wire",wire(packet(row)));rows.add(row);
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+names.size()+" native effect IDs and "+rows.size()+" complete update/remove packets, all flags, amplifier/duration/entity boundaries. Gameplay/ownership excluded.");
  }
}
