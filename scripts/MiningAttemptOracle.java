import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import io.netty.buffer.Unpooled;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundBlockDestructionPacket;
import net.minecraft.core.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.*;
import net.minecraft.network.protocol.game.ServerboundPlayerActionPacket.Action;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.item.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
public class MiningAttemptOracle {
 static class S extends DedicatedServer { private S(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);} public boolean isUnderSpawnProtection(ServerLevel l,BlockPos p,Player player){return false;} }
 static class L extends ServerLevel {S server;BlockState state;List<String> events;private L(){super(null,null,null,null,null,null,false,0,null,false);}public MinecraftServer getServer(){return server;}public BlockState getBlockState(BlockPos p){return state;}public boolean mayInteract(Entity e,BlockPos p){return true;}public void destroyBlockProgress(int id,BlockPos p,int stage){events.add("crack:"+stage);}public void levelEvent(Entity e,int type,BlockPos p,int data){} }
 static class P extends ServerPlayer {L world;float speed;boolean correct;Abilities abilities;private P(){super(null,null,null,null);}public ServerLevel level(){return world;}public GameType gameMode(){return GameType.SURVIVAL;}public Abilities getAbilities(){return abilities;}public boolean isWithinBlockInteractionRange(BlockPos p,double buffer){return true;}public boolean blockActionRestricted(Level level,BlockPos p,GameType mode){return false;}public ItemStack getMainHandItem(){return ItemStack.EMPTY;}public float getDestroySpeed(BlockState s){return speed;}public boolean hasCorrectToolForDrops(BlockState s){return correct;} }
 static class G extends ServerPlayerGameMode {L world;private G(){super(null);}public boolean destroyBlock(BlockPos p){world.events.add("destroy");world.state=Blocks.AIR.defaultBlockState();return true;}public void destroyAndAck(BlockPos p,int seq,String msg){destroyBlock(p);} }
 static Field f(String name)throws Exception{var f=ServerPlayerGameMode.class.getDeclaredField(name);f.setAccessible(true);return f;}
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();var uf=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");uf.setAccessible(true);var u=(sun.misc.Unsafe)uf.get(null);
  var rows=new JsonArray();int count=0;
  for(var block:List.of(Blocks.STONE,Blocks.DIRT,Blocks.OBSIDIAN,Blocks.BEDROCK,Blocks.GLASS))
  for(float speed:new float[]{0,1,2,8,32,1024,Float.MAX_VALUE})for(boolean correct:new boolean[]{false,true})for(int stop:new int[]{0,1,5,20,31,44,100}){
   var l=(L)u.allocateInstance(L.class);l.server=(S)u.allocateInstance(S.class);l.state=block.defaultBlockState();l.events=new ArrayList<>();
   var p=(P)u.allocateInstance(P.class);p.world=l;p.speed=speed;p.correct=correct;p.abilities=new Abilities();p.setId(1);
   var g=(G)u.allocateInstance(G.class);g.world=l;f("player").set(g,p);f("level").set(g,l);f("destroyPos").set(g,BlockPos.ZERO);f("delayedDestroyPos").set(g,BlockPos.ZERO);f("lastSentState").set(g,-1);f("gameModeForPlayer").set(g,GameType.SURVIVAL);
   var row=new JsonObject();row.addProperty("state",Block.getId(l.state));row.addProperty("speed",(double)speed);row.addProperty("correct",correct);row.addProperty("stop",stop);
   g.handleBlockBreakAction(BlockPos.ZERO,Action.START_DESTROY_BLOCK,Direction.UP,320,1);
   row.add("start_events",new Gson().toJsonTree(l.events));l.events.clear();
   if(!l.state.isAir()){
    for(int tick=1;tick<=stop;tick++)g.tick();row.add("tick_events",new Gson().toJsonTree(l.events));l.events.clear();
    g.handleBlockBreakAction(BlockPos.ZERO,Action.STOP_DESTROY_BLOCK,Direction.UP,320,2);
    row.add("stop_events",new Gson().toJsonTree(l.events));row.addProperty("delayed",(Boolean)f("hasDelayedDestroy").get(g));
   }
   rows.add(row);count++;
  }
  // Actual pinned delayed-tick behavior is captured separately, never silently copied.
  var limits=new JsonArray();
  for(int start:new int[]{0,123}){
   var l=(L)u.allocateInstance(L.class);l.server=(S)u.allocateInstance(S.class);l.state=Blocks.STONE.defaultBlockState();l.events=new ArrayList<>();
   var p=(P)u.allocateInstance(P.class);p.world=l;p.speed=1;p.correct=true;p.abilities=new Abilities();p.setId(1);
   var g=(G)u.allocateInstance(G.class);g.world=l;f("player").set(g,p);f("level").set(g,l);f("destroyPos").set(g,BlockPos.ZERO);f("delayedDestroyPos").set(g,BlockPos.ZERO);f("lastSentState").set(g,-1);f("gameModeForPlayer").set(g,GameType.SURVIVAL);f("gameTicks").set(g,start);
   g.handleBlockBreakAction(BlockPos.ZERO,Action.START_DESTROY_BLOCK,Direction.UP,320,1);for(int i=0;i<5;i++)g.tick();g.handleBlockBreakAction(BlockPos.ZERO,Action.STOP_DESTROY_BLOCK,Direction.UP,320,2);for(int i=0;i<60;i++)g.tick();
   var row=new JsonObject();row.addProperty("started",start);row.addProperty("destroyed",l.state.isAir());row.addProperty("delayed",(Boolean)f("hasDelayedDestroy").get(g));limits.add(row);
  }
  var packets=new JsonArray();
  for(int entity:new int[]{0,1,127,128,Integer.MAX_VALUE})for(var pos:List.of(BlockPos.ZERO,new BlockPos(-29999984,-64,29999984),new BlockPos(29999984,319,-29999984)))for(int stage=-1;stage<=9;stage++){
   var packet=new ClientboundBlockDestructionPacket(entity,pos,stage);var buffer=new FriendlyByteBuf(Unpooled.buffer());
   try{ClientboundBlockDestructionPacket.STREAM_CODEC.encode(buffer,packet);var raw=new byte[buffer.readableBytes()];buffer.getBytes(buffer.readerIndex(),raw);var decoded=ClientboundBlockDestructionPacket.STREAM_CODEC.decode(buffer);
    if(buffer.isReadable()||decoded.getId()!=entity||!decoded.getPos().equals(pos)||decoded.getProgress()!=(stage&255))throw new AssertionError("Destruction packet round trip");
    var row=new JsonObject();row.addProperty("entity",entity);row.add("position",new Gson().toJsonTree(List.of(pos.getX(),pos.getY(),pos.getZ())));row.addProperty("stage",stage);row.addProperty("wire",HexFormat.of().formatHex(raw));packets.add(row);
   }finally{buffer.release();}
  }
  var result=new JsonObject();result.add("traces",rows);result.add("delayed_limit",limits);result.add("packets",packets);Files.writeString(Path.of(args[0]),new Gson().toJson(result));
  System.out.println("PASS: "+count+" actual native start/tick/stop traces, plus two delayed-tick observations; destruction callbacks captured only.");
 }
}
