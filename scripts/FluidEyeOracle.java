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

/** Actual EntityFluidInteraction eye tests; loaded sections and body/eye positions are supplied. */
public class FluidEyeOracle {
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
    double eye;
    ProbeEntity(Level world){super(EntityTypes.ITEM,world);}
    protected void defineSynchedData(SynchedEntityData.Builder b){}
    protected void readAdditionalSaveData(ValueInput in){}
    protected void addAdditionalSaveData(ValueOutput out){}
    public boolean hurtServer(ServerLevel w,DamageSource d,float amount){return false;}
    public double getEyeY(){return eye;}
  }
  private static Field field(String name)throws Exception{var f=Entity.class.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(double... v){var a=new JsonArray();for(double n:v)a.add(n);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
    for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.LAVA));
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);world.chunk=(ProbeChunk)u.allocateInstance(ProbeChunk.class);
    world.chunk.sections=new LevelChunkSection[]{(ProbeSection)u.allocateInstance(ProbeSection.class)};
    var position=field("position");var blockPosition=field("blockPosition");var bb=field("bb");var cases=new JsonArray();
    var states=new ArrayList<BlockState>();states.add(Blocks.AIR.defaultBlockState());
    for(int level=0;level<16;level++){states.add(Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,level));states.add(Blocks.LAVA.defaultBlockState().setValue(LiquidBlock.LEVEL,level));}
    states.add(Blocks.OAK_SLAB.defaultBlockState().setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED,true));
    for(var state:states)for(var above:List.of(Blocks.AIR.defaultBlockState(),Blocks.STONE.defaultBlockState(),Blocks.OAK_SLAB.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState()))
      for(double x:new double[]{-.001,.5,.999,1.001})for(double y:new double[]{-.001,.111111112,.4,.8888888955116272,.999})
        for(double eye:new double[]{0,.1111111119389534,.4,.8888888955116272,.8888888955116273,.999,1,1.000000001,1.62,1.8888888955116272}){
          var e=new ProbeEntity(world);position.set(e,new Vec3(x,y,.5));blockPosition.set(e,BlockPos.containing(x,y,.5));e.eye=eye;
          var box=new AABB(x-(double).6f/2,y,.5-(double).6f/2,x+(double).6f/2,y+1.8,.5+(double).6f/2);bb.set(e,box);
          world.blocks=Map.of(BlockPos.ZERO,state,new BlockPos(0,1,0),above,new BlockPos(1,0,0),Blocks.LAVA.defaultBlockState());
          var interaction=new EntityFluidInteraction(Set.of());interaction.update(e,true);
          var c=new JsonObject();c.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));c.add("eye",vector(x,eye,.5));
          var supplied=new JsonArray();for(var entry:world.blocks.entrySet()){var b=new JsonObject();var p=entry.getKey();b.add("position",vector(p.getX(),p.getY(),p.getZ()));b.addProperty("state",Block.getId(entry.getValue()));supplied.add(b);}
          c.add("states",supplied);c.addProperty("water",interaction.isEyeInFluid(FluidTags.WATER));c.addProperty("lava",interaction.isEyeInFluid(FluidTags.LAVA));cases.add(c);
          world.blocks=Map.of();interaction.update(e,true);if(interaction.isEyeInFluid(FluidTags.WATER)||interaction.isEyeInFluid(FluidTags.LAVA))throw new AssertionError("Stale native eye contact");
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native eye-contact and dry-reset cases.");
  }
}
