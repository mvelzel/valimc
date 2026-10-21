import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;

/** Actual Player/LivingEntity climbable selection, including native tag and trapdoor branches. */
public class ClimbContactOracle {
  private static class ProbeLevel extends ServerLevel {
    BlockState below;Set<BlockPos> queries=new HashSet<>();
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos p){queries.add(p.immutable());return below;}
  }
  private static class Probe extends Player {
    ProbeLevel world;BlockState state;boolean spectator,gliding;
    private Probe(){super(null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return spectator?GameType.SPECTATOR:GameType.CREATIVE;}
    public boolean isFallFlying(){return gliding;}
    public BlockState getInBlockState(){return state;}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonObject run(Probe p,Abilities abilities){
    p.world.queries.clear();boolean climbing=p.onClimbable();var c=new JsonObject();c.addProperty("state",Block.getId(p.state));c.addProperty("below",Block.getId(p.world.below));
    c.addProperty("flying",abilities.flying);c.addProperty("spectator",p.spectator);c.addProperty("gliding",p.gliding);c.addProperty("climbing",climbing);
    var queries=new JsonArray();for(var pos:p.world.queries){var v=new JsonArray();v.add(pos.getX());v.add(pos.getY());v.add(pos.getZ());queries.add(v);}c.add("queries",queries);return c;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();BlockFactsOracle.bindOnly(net.minecraft.tags.BlockTags.CLIMBABLE,net.minecraft.tags.BlockTags.CAN_GLIDE_THROUGH);var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var p=(Probe)u.allocateInstance(Probe.class);p.world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);p.world.queries=new HashSet<>();var abilities=new Abilities();field(Player.class,"abilities").set(p,abilities);
    field(Entity.class,"blockPosition").set(p,new BlockPos(0,64,0));var cases=new JsonArray();var representatives=new LinkedHashMap<String,BlockState>();var gson=new Gson();p.world.below=Blocks.AIR.defaultBlockState();
    for(var state:Block.BLOCK_STATE_REGISTRY){p.state=state;cases.add(run(p,abilities));representatives.putIfAbsent(gson.toJson(BlockFactsOracle.climb(state)),state);}
    var below=new ArrayList<BlockState>();below.add(Blocks.AIR.defaultBlockState());below.add(Blocks.STONE.defaultBlockState());
    for(var d:Direction.Plane.HORIZONTAL)below.add(Blocks.LADDER.defaultBlockState().setValue(LadderBlock.FACING,d));
    for(var state:representatives.values())for(var b:below)for(boolean flying:new boolean[]{false,true})for(boolean spectator:new boolean[]{false,true})for(boolean gliding:new boolean[]{false,true}){
      p.state=state;p.world.below=b;abilities.flying=flying;p.spectator=spectator;p.gliding=gliding;cases.add(run(p,abilities));
    }
    Files.writeString(Path.of(args[0]),gson.toJson(cases));System.out.println("PASS: "+cases.size()+" actual native climb contacts, player exclusions and trapdoor/ladder directions.");
  }
}
