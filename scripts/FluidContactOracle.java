import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.tags.FluidTags;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.material.*;
import net.minecraft.world.level.storage.*;
import net.minecraft.world.phys.*;

/** Runs native 26.3 body contact; chunk availability supplied, current accumulation disabled. */
public class FluidContactOracle {
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
    Map<BlockPos,BlockState> blocks; ProbeChunk chunk;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getNextEntityId(){return 1;}
    public BlockState getBlockState(BlockPos p){return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
    public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
    public ChunkAccess getChunk(int x,int z,ChunkStatus status,boolean load){return chunk;}
  }
  private static class ProbeEntity extends Entity {
    ProbeEntity(Level world){super(EntityTypes.ITEM,world);}
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput in){}
    protected void addAdditionalSaveData(ValueOutput out){}
    public boolean hurtServer(ServerLevel world,DamageSource source,float amount){return false;}
  }
  private static Field field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static JsonArray position(BlockPos p){var a=new JsonArray();a.add(p.getX());a.add(p.getY());a.add(p.getZ());return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);world.chunk=(ProbeChunk)u.allocateInstance(ProbeChunk.class);
    world.chunk.sections=new LevelChunkSection[]{(ProbeSection)u.allocateInstance(ProbeSection.class)};
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
    for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.LAVA));
    var states=new ArrayList<BlockState>();states.add(Blocks.AIR.defaultBlockState());
    for(int level=0;level<=15;level++){states.add(Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,level));states.add(Blocks.LAVA.defaultBlockState().setValue(LiquidBlock.LEVEL,level));}
    states.add(Blocks.OAK_SLAB.defaultBlockState().setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED,true));
    var cases=new JsonArray();
    for(var state:states)for(var above:List.of(Blocks.AIR.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState()))
      for(double x:new double[]{-.301,-.299,.3,.5,1.299,1.301})
        for(double y:new double[]{-.001,0,.111111112,.4,.8888888955116272,.8878888955116272,.8898888955116272,.999,1,1.001}){
          world.blocks=Map.of(new BlockPos(0,0,0),state,new BlockPos(0,1,0),above,new BlockPos(1,0,0),Blocks.LAVA.defaultBlockState());
          var e=new ProbeEntity(world);field(Entity.class,"position").set(e,new Vec3(x,y,.5));
          var box=new AABB(x-(double).6f/2,y,.5-(double).6f/2,x+(double).6f/2,y+(double)1.8f,.5+(double).6f/2);
          field(Entity.class,"bb").set(e,box);var interaction=new EntityFluidInteraction(Set.of());
          interaction.update(e,true);
          var c=new JsonObject();c.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));var blocks=new JsonArray();
          for(var entry:world.blocks.entrySet()){var b=new JsonObject();b.add("position",position(entry.getKey()));b.addProperty("state",Block.getId(entry.getValue()));blocks.add(b);}
          c.add("states",blocks);c.addProperty("water",interaction.getFluidHeight(FluidTags.WATER));c.addProperty("lava",interaction.getFluidHeight(FluidTags.LAVA));cases.add(c);
          // Ensure native reset does not retain a previous water/lava depth.
          world.blocks=Map.of();interaction.update(e,true);
          if(interaction.getFluidHeight(FluidTags.WATER)!=0||interaction.getFluidHeight(FluidTags.LAVA)!=0)throw new AssertionError("Native fluid reset failed");
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native fluid contact/depth cases and dry-reset transitions; chunk availability supplied, current/eye outputs not asserted.");
  }
}
