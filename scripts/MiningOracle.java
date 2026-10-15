import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.io.ByteArrayOutputStream;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;

/** Actual block hardness/progress with supplied player speed/tool permission; excludes loot/effects. */
public class MiningOracle {
  private static class ProbeLevel extends ServerLevel {
    int crack,calls;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0,null,false);}
    public void destroyBlockProgress(int id,BlockPos pos,int stage){crack=stage;calls++;}
  }
  private static class Probe extends ServerPlayer {
    float speed; boolean correct,master; ProbeLevel world;
    private Probe(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public float getDestroySpeed(BlockState state){return speed;}
    public boolean hasCorrectToolForDrops(BlockState state){return correct;}
    public boolean canUseGameMasterBlocks(){return master;}
  }
  private static float formula(float hardness,float speed,boolean correct){return hardness==-1?0:speed/hardness/(correct?30:100);}
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  private static String bits(float value){return String.format(Locale.ROOT,"%08x",Float.floatToIntBits(value));}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);var player=(Probe)unsafe.allocateInstance(Probe.class);player.setId(1);player.world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    var properties=new JsonArray();var indices=new LinkedHashMap<String,Integer>();var states=new ByteArrayOutputStream();
    var speeds=new float[]{0,-0.0f,Float.MIN_VALUE,.0000001f,1,2,8,32,Float.MAX_VALUE};
    var cases=new JsonArray();int count=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=states.size())throw new AssertionError("Non-contiguous mining states");
      float hardness=state.getDestroySpeed(EmptyBlockGetter.INSTANCE,BlockPos.ZERO);
      player.speed=1;player.correct=true;player.master=false;float ordinary=state.getDestroyProgress(player,EmptyBlockGetter.INSTANCE,BlockPos.ZERO);
      player.master=true;float privileged=state.getDestroyProgress(player,EmptyBlockGetter.INSTANCE,BlockPos.ZERO);
      if(Float.floatToIntBits(ordinary)!=Float.floatToIntBits(formula(hardness,1,true))||Float.floatToIntBits(privileged)!=Float.floatToIntBits(ordinary))throw new AssertionError("Contextual mining progress needs explicit fixture: "+state);
      var facts=new JsonObject();facts.addProperty("hardness",(double)hardness);facts.addProperty("requires_correct_tool",state.requiresCorrectToolForDrops());
      var key=facts.toString();Integer index=indices.get(key);if(index==null){index=properties.size();indices.put(key,index);properties.add(facts);}if(index>255)throw new AssertionError("Too many mining properties");states.write(index);
    }
    for(float speed:speeds)for(boolean correct:new boolean[]{false,true})for(boolean master:new boolean[]{false,true}){
      player.speed=speed;player.correct=correct;player.master=master;var values=new ByteArrayOutputStream();
      for(var state:Block.BLOCK_STATE_REGISTRY){var progress=state.getDestroyProgress(player,EmptyBlockGetter.INSTANCE,BlockPos.ZERO);int value=Float.floatToIntBits(progress);values.write(value>>>24);values.write(value>>>16);values.write(value>>>8);values.write(value);count++;}
      var row=new JsonObject();row.addProperty("speed",(double)speed);row.addProperty("correct",correct);row.addProperty("master",master);row.addProperty("progress_bits",HexFormat.of().formatHex(values.toByteArray()));cases.add(row);
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.addProperty("state_count",states.size());facts.add("properties",properties);facts.addProperty("states",HexFormat.of().formatHex(states.toByteArray()));
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(cases));
    var mode=(ServerPlayerGameMode)unsafe.allocateInstance(ServerPlayerGameMode.class);field(ServerPlayerGameMode.class,"player").set(mode,player);field(ServerPlayerGameMode.class,"level").set(mode,player.world);
    var increment=ServerPlayerGameMode.class.getDeclaredMethod("incrementDestroyProgress",BlockState.class,BlockPos.class,int.class);increment.setAccessible(true);var ticks=new JsonArray();
    for(var state:List.of(Blocks.AIR.defaultBlockState(),Blocks.STONE.defaultBlockState(),Blocks.DIRT.defaultBlockState(),Blocks.OBSIDIAN.defaultBlockState(),Blocks.BEDROCK.defaultBlockState(),Blocks.GLASS.defaultBlockState(),Block.BLOCK_STATE_REGISTRY.byId(2257)))for(float speed:speeds)for(boolean correct:new boolean[]{false,true})for(int elapsed:new int[]{0,1,2,9,29,30,99,100,1024,Integer.MAX_VALUE-1,Integer.MAX_VALUE}){
      player.speed=speed;player.correct=correct;player.world.calls=0;player.world.crack=Integer.MIN_VALUE;field(ServerPlayerGameMode.class,"lastSentState").set(mode,Integer.MIN_VALUE);
      float progress=(Float)increment.invoke(mode,state,BlockPos.ZERO,elapsed);increment.invoke(mode,state,BlockPos.ZERO,elapsed);
      var row=new JsonObject();row.addProperty("state",Block.getId(state));row.addProperty("speed",(double)speed);row.addProperty("correct",correct);row.addProperty("elapsed",elapsed);row.addProperty("progress_bits",bits(progress));row.addProperty("crack",player.world.crack);row.addProperty("calls",player.world.calls);ticks.add(row);
    }
    Files.writeString(Path.of(args[2]),new Gson().toJson(ticks));
    System.out.println("PASS: "+states.size()+" native hardness/harvest flags, "+properties.size()+" groups, "+count+" native rates and "+ticks.size()+" actual mining tick/crack prefixes; supplied player speed/tool checks, loot/effects excluded.");
  }
}
