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
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.entity.ChestBlockEntity;
import net.minecraft.world.level.block.entity.BarrelBlockEntity;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.phys.Vec3;
import net.minecraft.server.level.ServerLevel;

/** Original actual chest and barrel sound call/pitch, barrel open-state and registered sound packet observations. */
public class ChestSoundOracle {
  /** One barrel's level: its state writes, sounds and rechecks, nothing else. */
  static class BarrelWorld extends ServerLevel {
    BlockPos position;BlockState state;BarrelBlockEntity barrel;JsonArray sounds,states;int scheduled;
    private BarrelWorld(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){return pos.equals(position)?state:Blocks.AIR.defaultBlockState();}
    public BlockEntity getBlockEntity(BlockPos pos){return pos.equals(position)?barrel:null;}
    public void scheduleTick(BlockPos pos,net.minecraft.world.level.block.Block block,int delay){
      if(!pos.equals(position)||block!=Blocks.BARREL||delay!=5)throw new AssertionError("Unexpected recheck");scheduled++;
    }
    public boolean setBlock(BlockPos pos,BlockState next,int flags,int limit){
      if(!pos.equals(position)||flags!=3)throw new AssertionError("Unexpected barrel write");
      states.add(net.minecraft.world.level.block.Block.getId(next));state=next;barrel.setBlockState(next);return true;
    }
    public void playSound(Entity source,double x,double y,double z,SoundEvent sound,SoundSource channel,float volume,float pitch){
      var row=new JsonObject();row.addProperty("sound",BuiltInRegistries.SOUND_EVENT.getKey(sound).toString());
      row.add("at",new Gson().toJsonTree(List.of(x,y,z)));row.addProperty("volume",volume);row.addProperty("pitch",pitch);
      if(channel!=SoundSource.BLOCKS||source!=null)throw new AssertionError("Wrong sound audience");sounds.add(row);
    }
    public void gameEvent(Holder<GameEvent> event,Vec3 pos,GameEvent.Context context){}
  }

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
    var halves=new JsonArray();
    for(var state:Blocks.CHEST.getStateDefinition().getPossibleStates()){
      var world=(ChestViewOracle.World)unsafe.allocateInstance(ChestViewOracle.World.class);
      world.position=new BlockPos(-1,64,15);world.state=state;
      world.events=new JsonArray();world.sounds=new JsonArray();world.games=new JsonArray();random.set(world,RandomSource.create(42));
      world.chest=new ChestBlockEntity(world.position,state);world.chest.setLevel(world);
      world.chest.startOpen(actor);world.chest.stopOpen(actor);
      var row=new JsonObject();row.addProperty("state",net.minecraft.world.level.block.Block.getId(state));row.add("sounds",world.sounds);halves.add(row);
    }
    // Barrels: the first opener writes open=true and sounds at the front face, the last closes it;
    // a spectator and the viewers between are silent.
    var spectator=(ChestViewOracle.Actor)unsafe.allocateInstance(ChestViewOracle.Actor.class);spectator.spectator=true;
    var other=(ChestViewOracle.Actor)unsafe.allocateInstance(ChestViewOracle.Actor.class);
    var barrels=new JsonArray();
    for(var state:Blocks.BARREL.getStateDefinition().getPossibleStates()){
      var world=(BarrelWorld)unsafe.allocateInstance(BarrelWorld.class);
      world.position=new BlockPos(-1,64,15);world.state=state;world.sounds=new JsonArray();world.states=new JsonArray();
      var draws=new JsonArray(); var delegate=RandomSource.create(Block.getId(state));
      random.set(world,(RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,values)->{
        if(!method.getName().equals("nextFloat"))throw new AssertionError("Unexpected barrel sound RNG "+method);
        float value=delegate.nextFloat(); draws.add(value); return value;
      }));
      world.barrel=new BarrelBlockEntity(world.position,state);world.barrel.setLevel(world);
      var writes=new JsonArray();
      world.barrel.startOpen(actor);writes.add(world.states.size());
      world.barrel.startOpen(spectator);world.barrel.startOpen(other);writes.add(world.states.size());
      world.barrel.stopOpen(actor);world.barrel.stopOpen(spectator);writes.add(world.states.size());
      world.barrel.stopOpen(other);writes.add(world.states.size());
      if(!writes.toString().equals("[1,1,1,2]")||world.sounds.size()!=2||draws.size()!=2||world.scheduled!=1)throw new AssertionError("Barrel viewer lifecycle changed");
      var row=new JsonObject();row.addProperty("state",Block.getId(state));row.add("states",world.states);row.add("draws",draws);row.add("sounds",world.sounds);barrels.add(row);
    }
    var events=List.of(SoundEvents.CHEST_OPEN,SoundEvents.CHEST_CLOSE);
    var registry=new JsonArray();
    for(var event:List.of(SoundEvents.CHEST_OPEN,SoundEvents.CHEST_CLOSE,SoundEvents.BARREL_OPEN,SoundEvents.BARREL_CLOSE)) {
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
    var barrelPackets=new JsonArray();
    for(var event:List.of(SoundEvents.BARREL_OPEN,SoundEvents.BARREL_CLOSE)) for(var pos:List.of(new double[]{0.5,65.0,0.5},new double[]{-1.0,64.5,15.5},new double[]{-0.5,-64.0,15.5},new double[]{29999985.0,319.5,-29999983.5}))
      for(float pitch:new float[]{0.9F,1}) for(long seed:new long[]{Long.MIN_VALUE,0,Long.MAX_VALUE}) {
        var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
        try {
          ClientboundSoundPacket.STREAM_CODEC.encode(buffer,new ClientboundSoundPacket(BuiltInRegistries.SOUND_EVENT.wrapAsHolder(event),SoundSource.BLOCKS,pos[0],pos[1],pos[2],0.5F,pitch,seed));
          var bytes=new byte[buffer.readableBytes()]; buffer.getBytes(0,bytes);
          var row=new JsonObject(); row.addProperty("sound",BuiltInRegistries.SOUND_EVENT.getKey(event).toString());
          row.add("position",new Gson().toJsonTree(pos)); row.addProperty("pitch",pitch); row.addProperty("seed",seed); row.addProperty("hex",HexFormat.of().formatHex(bytes)); barrelPackets.add(row);
        } finally {buffer.release();}
      }
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("blocks_source",SoundSource.BLOCKS.ordinal()); out.add("registry",registry); out.add("traces",traces);out.add("halves",halves); out.add("packets",packets); out.add("barrels",barrels); out.add("barrel_packets",barrelPackets);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+traces.size()+" actual native chest sound RNG traces, "+barrels.size()+" barrel open-state/sound traces and "+(packets.size()+barrelPackets.size())+" registered sound codec bodies.");
  }
}
