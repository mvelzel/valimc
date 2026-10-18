import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import java.lang.reflect.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundSoundPacket;
import net.minecraft.sounds.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.ChestBlockEntity;

/** Original actual chest sound call/pitch and registered sound packet observations. */
public class ChestSoundOracle {
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); f.setAccessible(true); var unsafe=(sun.misc.Unsafe)f.get(null);
    var random=Level.class.getDeclaredField("random"); random.setAccessible(true);
    var actor=(ChestViewOracle.Actor)unsafe.allocateInstance(ChestViewOracle.Actor.class);
    var traces=new JsonArray();
    for(int seed=0;seed<256;seed++) {
      var world=(ChestViewOracle.World)unsafe.allocateInstance(ChestViewOracle.World.class);
      world.position=new BlockPos(-1,64,15); world.state=Blocks.CHEST.defaultBlockState();
      world.events=new JsonArray(); world.sounds=new JsonArray(); world.games=new JsonArray();
      var draws=new JsonArray(); var delegate=RandomSource.create(seed);
      RandomSource source=(RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,values)->{
        if(!method.getName().equals("nextFloat"))throw new AssertionError("Unexpected chest sound RNG "+method);
        float value=delegate.nextFloat(); draws.add(value); return value;
      });
      random.set(world,source);
      world.chest=new ChestBlockEntity(world.position,world.state); world.chest.setLevel(world);
      world.chest.startOpen(actor); world.chest.stopOpen(actor);
      if(draws.size()!=2||world.sounds.size()!=2)throw new AssertionError("Changed chest sound lifecycle");
      var row=new JsonObject(); row.addProperty("seed",seed); row.add("draws",draws); row.add("sounds",world.sounds); traces.add(row);
    }
    var events=List.of(SoundEvents.CHEST_OPEN,SoundEvents.CHEST_CLOSE);
    var registry=new JsonArray();
    for(var event:events) {
      var row=new JsonObject(); row.addProperty("name",BuiltInRegistries.SOUND_EVENT.getKey(event).toString());
      row.addProperty("id",BuiltInRegistries.SOUND_EVENT.getId(event)); row.addProperty("range",event.getRange(0.5F)); registry.add(row);
    }
    var packets=new JsonArray(); var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    for(var event:events) for(var pos:List.of(new double[]{0.5,64.5,0.5},new double[]{-1.01,-63.99,15.875},new double[]{29999984.5,319.5,-29999983.5}))
      for(float volume:new float[]{0,0.5F,1}) for(float pitch:new float[]{0.9F,1,2}) for(long seed:new long[]{Long.MIN_VALUE,-1,0,1,Long.MAX_VALUE}) {
        var packet=new ClientboundSoundPacket(BuiltInRegistries.SOUND_EVENT.wrapAsHolder(event),SoundSource.BLOCKS,pos[0],pos[1],pos[2],volume,pitch,seed);
        var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
        try {
          ClientboundSoundPacket.STREAM_CODEC.encode(buffer,packet); var bytes=new byte[buffer.readableBytes()]; buffer.getBytes(0,bytes);
          var decoded=ClientboundSoundPacket.STREAM_CODEC.decode(buffer);
          if(buffer.isReadable()||decoded.getSound().value()!=event||decoded.getSource()!=SoundSource.BLOCKS||decoded.getSeed()!=seed||decoded.getVolume()!=volume||decoded.getPitch()!=pitch)throw new AssertionError("Sound round trip differs");
          var row=new JsonObject(); row.addProperty("sound",BuiltInRegistries.SOUND_EVENT.getKey(event).toString());
          row.add("position",new Gson().toJsonTree(pos)); row.add("received",new Gson().toJsonTree(List.of(decoded.getX(),decoded.getY(),decoded.getZ())));
          row.addProperty("volume",volume); row.addProperty("pitch",pitch); row.addProperty("seed",seed); row.addProperty("hex",HexFormat.of().formatHex(bytes)); packets.add(row);
        } finally {buffer.release();}
      }
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("blocks_source",SoundSource.BLOCKS.ordinal()); out.add("registry",registry); out.add("traces",traces); out.add("packets",packets);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+traces.size()+" actual native chest sound RNG traces and "+packets.size()+" registered sound codec bodies.");
  }
}
