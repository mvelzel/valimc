import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.*;
import net.minecraft.world.level.dimension.*;

/** Original codec fixtures for the fall/death/respawn path, without gameplay side effects. */
public class PlayerLifeOracle {
  private static RegistryAccess.Frozen access;
  private static Holder<DimensionType> overworld;
  private static Holder<DamageType> fall,stalagmite,freeze,drown,voidSource,starve;
  private static Map<String,Holder<DamageType>> hazards;
  private static class Probe extends Player {
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
  }
  private static <T> MappedRegistry<T> registry(net.minecraft.resources.ResourceKey<net.minecraft.core.Registry<T>> key,HolderLookup.Provider lookup){
    var source=lookup.lookupOrThrow(key);var result=new MappedRegistry<T>(key,Lifecycle.stable());
    for(var id:source.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())
      result.register(id,source.getOrThrow(id).value(),RegistrationInfo.BUILT_IN);
    result.freeze();return result;
  }
  @SuppressWarnings({"rawtypes","unchecked"})
  private static String wire(Object packet){
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().encode(buf,(Packet)packet);
      var bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return HexFormat.of().formatHex(bytes);
    }finally{buf.release();}
  }
  private static Map<String,Object> packets()throws Exception{
    var result=new LinkedHashMap<String,Object>();
    result.put("level_load_start",new ClientboundGameEventPacket(ClientboundGameEventPacket.LEVEL_CHUNKS_LOAD_START,0));
    for(float health:new float[]{0,1,19.5f,20})for(int food:new int[]{0,6,17,18,20})for(float saturation:new float[]{0,.1f,5,20.5f})
      result.put("health_"+(double)health+"_"+food+"_"+(double)saturation,new ClientboundSetHealthPacket(health,food,saturation));
    var positions=Arrays.asList(null,new BlockPos(0,64,0),new BlockPos(-17,-64,42),new BlockPos(29999984,319,-29999984),new BlockPos(1,1000000,-1),new BlockPos(-1,-1000000,1));
    for(var mode:GameType.values())for(int previous=-1;previous<4;previous++)for(int i=0;i<positions.size();i++){
      var prior=previous<0?Optional.<GameType>empty():Optional.of(GameType.byId(previous));
      var death=Optional.ofNullable(positions.get(i)).map(p->GlobalPos.of(Level.OVERWORLD,p));
      var spawn=new CommonPlayerSpawnInfo(overworld,Level.OVERWORLD,0L,mode,prior,false,true,death,0,63);
      result.put("respawn_"+mode.getId()+"_"+previous+"_"+i,new ClientboundRespawnPacket(spawn,(byte)0));
    }
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);
    var player=(Probe)unsafe.allocateInstance(Probe.class);
    for(int id:new int[]{1,127,128,Integer.MAX_VALUE}){
      player.setId(id);
      result.put("fall_"+id,new ClientboundDamageEventPacket(id,fall,-1,-1,Optional.empty()));
      result.put("stalagmite_"+id,new ClientboundDamageEventPacket(id,stalagmite,-1,-1,Optional.empty()));
      result.put("freeze_"+id,new ClientboundDamageEventPacket(id,freeze,-1,-1,Optional.empty()));
      result.put("drown_"+id,new ClientboundDamageEventPacket(id,drown,-1,-1,Optional.empty()));
      result.put("void_"+id,new ClientboundDamageEventPacket(id,voidSource,-1,-1,Optional.empty()));
      result.put("starve_"+id,new ClientboundDamageEventPacket(id,starve,-1,-1,Optional.empty()));
      for(var hazard:hazards.entrySet())result.put("hazard_"+hazard.getKey()+"_"+id,new ClientboundDamageEventPacket(id,hazard.getValue(),-1,-1,Optional.empty()));
      result.put("drowning_bubbles_"+id,new ClientboundEntityEventPacket(player,(byte)67));
      result.put("death_animation_"+id,new ClientboundEntityEventPacket(player,(byte)3));
      for(var message:List.of("fell","ValiMCTest hit the ground too hard","fall \u0000😀é"))
        result.put("death_"+id+"_"+message,new ClientboundPlayerCombatKillPacket(id,Component.literal(message)));
    }
    return result;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var dimensions=registry(Registries.DIMENSION_TYPE,lookup);var damage=registry(Registries.DAMAGE_TYPE,lookup);
    access=new RegistryAccess.ImmutableRegistryAccess(List.of(dimensions,damage)).freeze();
    overworld=dimensions.getOrThrow(BuiltinDimensionTypes.OVERWORLD);fall=damage.getOrThrow(DamageTypes.FALL);stalagmite=damage.getOrThrow(DamageTypes.STALAGMITE);freeze=damage.getOrThrow(DamageTypes.FREEZE);
    drown=damage.getOrThrow(DamageTypes.DROWN);
    voidSource=damage.getOrThrow(DamageTypes.FELL_OUT_OF_WORLD);
    starve=damage.getOrThrow(DamageTypes.STARVE);
    hazards=new LinkedHashMap<>();for(var key:List.of(DamageTypes.CAMPFIRE,DamageTypes.CACTUS,DamageTypes.SWEET_BERRY_BUSH))hazards.put(key.identifier().getPath(),damage.getOrThrow(key));
    var packets=packets();
    if(args[0].equals("verify")){
      var rows=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      if(rows.size()!=packets.size())throw new AssertionError("Missing packets");
      for(var row:rows){var c=row.getAsJsonObject();var expected=packets.get(c.get("name").getAsString());
        if(expected==null)throw new AssertionError("Unexpected packet");
        var buf=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(c.get("wire").getAsString())),access);
        try{var decoded=GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().decode(buf);
          if(buf.isReadable()||!wire(decoded).equals(wire(expected)))throw new AssertionError("Wrong packet "+c);
        }finally{buf.release();}
      }
      System.out.println("PASS: native decoding of "+rows.size()+" Elixir fall/death/respawn packets.");return;
    }
    var result=new JsonObject();var messages=new JsonArray();
    packets.forEach((name,packet)->{var c=new JsonObject();c.addProperty("name",name);c.addProperty("wire",wire(packet));messages.add(c);});
    var commands=new JsonArray();
    for(int action:new int[]{-1,0,1,2,3,127,Integer.MIN_VALUE,Integer.MAX_VALUE}){
      var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);var c=new JsonObject();c.addProperty("id",action);buf.writeVarInt(action);
      try{c.addProperty("action",ServerboundClientCommandPacket.STREAM_CODEC.decode(buf).getAction().name());}
      catch(IndexOutOfBoundsException e){c.add("action",JsonNull.INSTANCE);}finally{buf.release();}commands.add(c);
    }
    result.add("packets",messages);result.add("commands",commands);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));System.out.println("PASS: "+messages.size()+" native fall/death/respawn packets and "+commands.size()+" command enum boundaries.");
  }
}
