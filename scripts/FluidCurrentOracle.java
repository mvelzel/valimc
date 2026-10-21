import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.FluidTags;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;

/** Native EntityFluidInteraction.update/applyCurrentTo on a Player, with supplied loaded chunks. */
public class FluidCurrentOracle {
  private static class ProbeSection extends LevelChunkSection {
    private ProbeSection(){super((PalettedContainerFactory)null);}
    public boolean hasFluid(){return true;}
  }
  private static class ProbeChunk extends LevelChunk {
    LevelChunkSection[] sections;
    private ProbeChunk(){super((Level)null,(ChunkPos)null);}
    public LevelChunkSection[] getSections(){return sections;}
    public int getSectionIndexFromSectionY(int y){return 0;}
  }
  private static class ProbeLevel extends ServerLevel {
    Map<BlockPos,BlockState> blocks; ProbeChunk chunk;Set<BlockPos> queries;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos p){queries.add(p.immutable());return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
    public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
    public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos p){queries.add(p.immutable());return null;}
    public ChunkAccess getChunk(int x,int z,ChunkStatus s,boolean load){return chunk;}
  }
  private static class ProbePlayer extends Player {
    ProbeLevel world;
    private ProbePlayer(){super(null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return GameType.CREATIVE;}
  }
  private static Field field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(double... values){var a=new JsonArray();for(double n:values)a.add(n);return a;}
  private static JsonArray position(BlockPos p){var a=new JsonArray();a.add(p.getX());a.add(p.getY());a.add(p.getZ());return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();BlockFactsOracle.bindOnly(net.minecraft.tags.BlockTags.BLOCKS_FLUID_FLOW);
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
    for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.LAVA));
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);world.chunk=(ProbeChunk)u.allocateInstance(ProbeChunk.class);
    world.chunk.sections=new LevelChunkSection[]{(ProbeSection)u.allocateInstance(ProbeSection.class)};
    var p=(ProbePlayer)u.allocateInstance(ProbePlayer.class);p.world=world;field(Player.class,"abilities").set(p,new Abilities());
    var cases=new JsonArray();
    for(var block:List.of(Blocks.WATER,Blocks.LAVA))for(int level=0;level<=15;level++)for(int layout=0;layout<4;layout++)
      for(double feet:new double[]{63.999,64,64.5,64.7,64.88788889551163,64.889})
        for(var initial:List.of(Vec3.ZERO,new Vec3(.00299,.1,-.00299),new Vec3(.003,0,.003),new Vec3(.2,-.3,-.1)))
          for(boolean pushed:new boolean[]{false,true})for(boolean fast:new boolean[]{false,true}){
            var blocks=new LinkedHashMap<BlockPos,BlockState>();var state=block.defaultBlockState().setValue(LiquidBlock.LEVEL,level);
            blocks.put(new BlockPos(0,64,0),state);blocks.put(new BlockPos(-1,64,0),Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,7));
            blocks.put(new BlockPos(1,64,0),layout==0?state:Blocks.LAVA.defaultBlockState());
            blocks.put(new BlockPos(0,65,0),layout>=2?state:Blocks.AIR.defaultBlockState());
            blocks.put(new BlockPos(1,65,0),layout==3?Blocks.WATER.defaultBlockState():Blocks.AIR.defaultBlockState());
            blocks.put(new BlockPos(0,64,1),Blocks.STONE.defaultBlockState());
            blocks.put(new BlockPos(1,63,-1),state);world.blocks=blocks;world.queries=new HashSet<>();
            var body=new AABB(.7,feet,.2,1.3,feet+(double)1.8f,.8);field(Entity.class,"bb").set(p,body);field(Entity.class,"position").set(p,new Vec3(1,feet,.5));
            field(Entity.class,"blockPosition").set(p,BlockPos.containing(1,feet,.5));p.setDeltaMovement(initial);
            var interaction=new EntityFluidInteraction(Set.of(FluidTags.WATER,FluidTags.LAVA));interaction.update(p,!pushed);
            if(pushed){interaction.applyCurrentTo(FluidTags.WATER,p,.014);interaction.applyCurrentTo(FluidTags.LAVA,p,fast?.007:.0023333333333333335);}
            var c=new JsonObject();c.add("box",vector(body.minX,body.minY,body.minZ,body.maxX,body.maxY,body.maxZ));c.add("initial",vector(initial.x,initial.y,initial.z));c.addProperty("pushed",pushed);c.addProperty("fast_lava",fast);
            var velocity=p.getDeltaMovement();c.add("velocity",vector(velocity.x,velocity.y,velocity.z));c.addProperty("water",interaction.getFluidHeight(FluidTags.WATER));c.addProperty("lava",interaction.getFluidHeight(FluidTags.LAVA));
            var entries=new JsonArray();for(var entry:blocks.entrySet()){var b=new JsonObject();b.add("position",position(entry.getKey()));b.addProperty("state",Block.getId(entry.getValue()));entries.add(b);}c.add("states",entries);
            var needed=new JsonArray();for(var q:world.queries)needed.add(position(q));c.add("queries",needed);cases.add(c);
          }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" actual native player current/depth observations; loaded chunks supplied, eyes not asserted.");
  }
}
