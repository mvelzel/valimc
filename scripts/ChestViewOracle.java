import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import io.netty.buffer.Unpooled;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundBlockEventPacket;
import net.minecraft.server.level.*;
import net.minecraft.sounds.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.ChestType;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.phys.Vec3;

/** Original viewer/lid/packet observations; sound calls captured, no world simulation or item mutation. */
public class ChestViewOracle {
  static class Actor extends ServerPlayer {
    boolean spectator;
    private Actor(){super(null,null,null,null);}
    public boolean isSpectator(){return spectator;}
    public double getContainerInteractionRange(){return 4.5;}
  }
  static class World extends ServerLevel {
    BlockPos position;BlockState state;ChestBlockEntity chest;
    JsonArray events,sounds,games;int scheduled;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){return pos.equals(position)?state:Blocks.AIR.defaultBlockState();}
    public BlockEntity getBlockEntity(BlockPos pos){return pos.equals(position)?chest:null;}
    public void scheduleTick(BlockPos pos,Block block,int delay){
      if(!pos.equals(position)||block!=Blocks.CHEST||delay!=5)throw new AssertionError("Unexpected recheck");scheduled++;
    }
    public void blockEvent(BlockPos pos,Block block,int id,int count){
      if(!pos.equals(position)||block!=Blocks.CHEST||id!=1)throw new AssertionError("Unexpected lid event");
      var row=new JsonArray();row.add(id);row.add(count);events.add(row);
      if(!chest.triggerEvent(id,count))throw new AssertionError("Rejected native lid event");
    }
    public void playSound(Entity source,double x,double y,double z,SoundEvent sound,SoundSource channel,float volume,float pitch){
      var row=new JsonObject();row.addProperty("sound",BuiltInRegistries.SOUND_EVENT.getKey(sound).toString());
      row.add("at",new Gson().toJsonTree(List.of(x,y,z)));row.addProperty("volume",volume);row.addProperty("pitch",pitch);
      if(channel!=SoundSource.BLOCKS||source!=null)throw new AssertionError("Wrong sound audience");sounds.add(row);
    }
    public void gameEvent(Holder<GameEvent> event,Vec3 pos,GameEvent.Context context){games.add(event.unwrapKey().orElseThrow().identifier().toString());}
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var random=Level.class.getDeclaredField("random");random.setAccessible(true);
    var a=(Actor)u.allocateInstance(Actor.class);var b=(Actor)u.allocateInstance(Actor.class);var spectator=(Actor)u.allocateInstance(Actor.class);spectator.spectator=true;
    var cases=new JsonArray();
    for(var state:Blocks.CHEST.getStateDefinition().getPossibleStates())if(state.getValue(ChestBlock.TYPE)==ChestType.SINGLE){
      var world=(World)u.allocateInstance(World.class);world.position=new BlockPos(-1,64,15);world.state=state;
      world.events=new JsonArray();world.sounds=new JsonArray();world.games=new JsonArray();random.set(world,RandomSource.create(42));
      world.chest=new ChestBlockEntity(world.position,state);world.chest.setLevel(world);
      var counts=new JsonArray();
      world.chest.startOpen(a);counts.add(ChestBlockEntity.getOpenCount(world,world.position));
      world.chest.startOpen(spectator);counts.add(ChestBlockEntity.getOpenCount(world,world.position));
      world.chest.startOpen(b);counts.add(ChestBlockEntity.getOpenCount(world,world.position));
      var openness=new JsonArray();
      for(int i=0;i<5;i++)ChestBlockEntity.lidAnimateTick(world,world.position,state,world.chest);
      openness.add(world.chest.getOpenNess(1));
      world.chest.stopOpen(spectator);counts.add(ChestBlockEntity.getOpenCount(world,world.position));
      world.chest.stopOpen(a);counts.add(ChestBlockEntity.getOpenCount(world,world.position));
      for(int i=0;i<5;i++)ChestBlockEntity.lidAnimateTick(world,world.position,state,world.chest);
      openness.add(world.chest.getOpenNess(1));
      world.chest.stopOpen(b);counts.add(ChestBlockEntity.getOpenCount(world,world.position));
      for(int i=0;i<10;i++)ChestBlockEntity.lidAnimateTick(world,world.position,state,world.chest);
      openness.add(world.chest.getOpenNess(1));
      world.chest.setRemoved();world.chest.startOpen(a);world.chest.stopOpen(a);
      if(!counts.toString().equals("[1,1,2,2,1,0]")||world.events.size()!=4||world.sounds.size()!=2||world.games.size()!=2||world.scheduled!=1)throw new AssertionError("Viewer lifecycle changed");
      var row=new JsonObject();row.addProperty("state",Block.getId(state));row.add("counts",counts);row.add("events",world.events);row.add("sounds",world.sounds);row.add("games",world.games);row.add("openness",openness);row.addProperty("scheduled",world.scheduled);cases.add(row);
    }
    var packets=new JsonArray();var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    for(var pos:List.of(BlockPos.ZERO,new BlockPos(-1,-64,15),new BlockPos(29999984,319,-29999984)))for(int count:new int[]{0,1,2,255,256,512}){
      var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{
        ClientboundBlockEventPacket.STREAM_CODEC.encode(buffer,new ClientboundBlockEventPacket(pos,Blocks.CHEST,1,count));
        var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);
        var decoded=ClientboundBlockEventPacket.STREAM_CODEC.decode(buffer);
        if(buffer.isReadable()||decoded.getB0()!=1||decoded.getB1()!=(count&255)||decoded.getBlock()!=Blocks.CHEST||!decoded.getPos().equals(pos))throw new AssertionError("Native block event differs");
        var row=new JsonObject();row.add("position",new Gson().toJsonTree(List.of(pos.getX(),pos.getY(),pos.getZ())));row.addProperty("requested",count);row.addProperty("received",decoded.getB1());row.addProperty("hex",HexFormat.of().formatHex(bytes));packets.add(row);
      }finally{buffer.release();}
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("chest_block_id",BuiltInRegistries.BLOCK.getId(Blocks.CHEST));out.add("cases",cases);out.add("packets",packets);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+cases.size()+" native single-chest spectator/removal/first-last viewer/lid traces and "+packets.size()+" block event codecs, including byte truncation; sounds captured, no item/world simulation.");
  }
}
