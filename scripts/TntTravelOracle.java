import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.PrimedTnt;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;

/**
 * Actual PrimedTnt.tick + Entity.move (VMC-050a) over supplied floors and
 * layouts: gravity, collision, restitution, block speed, air drag and the
 * ground slow-down, without fluids, block effects, peers or the explosion
 * (the fuse never runs out). Layouts: 0 the floor alone, 1 a wall at x = 2,
 * 2 a ceiling at y = 66; the floor fills y = 63 for |x|, |z| <= 12.
 * Usage: TntTravelOracle OUT.json
 */
public class TntTravelOracle {
 static class Section extends LevelChunkSection {
  private Section(){super((PalettedContainerFactory)null);}
  public boolean hasFluid(){return false;}
 }
 static class Chunk extends LevelChunk {
  LevelChunkSection[] sections;
  private Chunk(){super((Level)null,(ChunkPos)null);}
  public LevelChunkSection[] getSections(){return sections;}
  public int getSectionIndexFromSectionY(int y){return 0;}
 }
 static class World extends ServerLevel {
  Map<BlockPos,BlockState> blocks; Chunk chunk; WorldBorder border;
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
  public BlockState getBlockState(BlockPos p){return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
  public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos p){return null;}
  public ChunkAccess getChunk(int x,int z,ChunkStatus s,boolean load){return chunk;}
  public BlockGetter getChunkForCollisions(int x,int z){return this;}
  public WorldBorder getWorldBorder(){return border;}
  public List<VoxelShape> getEntityCollisions(Entity e,AABB box){return List.of();}
  public List<Entity> getEntities(Entity e,AABB box,Predicate<? super Entity> p){return List.of();}
  public boolean noCollision(Entity e,AABB box){return !getBlockCollisions(e,box).iterator().hasNext();}
 }
 static class Tnt extends PrimedTnt {
  Tnt(World w,Vec3 position){super(w,position.x,position.y,position.z,null);}
  public boolean updateFluidInteraction(){return false;}
  public void recordMovement(MoverType kind,Vec3 movement){}
  public void applyEffectsFromBlocks(){}
  public void applyEffectsFromBlocksForLastMovements(){}
  protected void checkFallDamage(double y,boolean ground,BlockState state,BlockPos p){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event){}
 }
 static Field field(Class<?> c,String n)throws Exception{var f=c.getDeclaredField(n);f.setAccessible(true);return f;}
 static JsonArray vec(double... nums){var a=new JsonArray();for(double n:nums)a.add(n);return a;}
 static JsonArray vec(Vec3 v){return vec(v.x,v.y,v.z);}
 static JsonObject snapshot(Tnt tnt){
  var o=new JsonObject();o.add("position",vec(tnt.position()));o.add("velocity",vec(tnt.getDeltaMovement()));
  o.addProperty("on_ground",tnt.onGround());o.addProperty("no_gravity",tnt.isNoGravity());return o;
 }
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();
  var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
  var world=(World)u.allocateInstance(World.class);world.border=new WorldBorder();
  world.chunk=(Chunk)u.allocateInstance(Chunk.class);world.chunk.sections=new LevelChunkSection[]{(Section)u.allocateInstance(Section.class)};
  field(Level.class,"random").set(world,net.minecraft.util.RandomSource.create(0));
  var rows=new JsonArray();
  for(var floor:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK,Blocks.HONEY_BLOCK,Blocks.OAK_SLAB,Blocks.SOUL_SAND))for(int layout=0;layout<3;layout++)
   for(var position:List.of(new Vec3(.5,64,.5),new Vec3(.5,65.5,.5),new Vec3(.25,64.5,-.75)))
    for(var velocity:List.of(Vec3.ZERO,new Vec3(.3,.2,-.1),new Vec3(.6,-.8,.4),new Vec3(-.02,.2,.01)))for(boolean noGravity:new boolean[]{false,true}){
     world.blocks=new LinkedHashMap<>();
     for(int x=-12;x<=12;x++)for(int z=-12;z<=12;z++)world.blocks.put(new BlockPos(x,63,z),floor.defaultBlockState());
     if(layout==1)for(int z=-12;z<=12;z++)for(int y=64;y<=67;y++)world.blocks.put(new BlockPos(2,y,z),Blocks.STONE.defaultBlockState());
     if(layout==2)for(int x=-12;x<=12;x++)for(int z=-12;z<=12;z++)world.blocks.put(new BlockPos(x,66,z),Blocks.STONE.defaultBlockState());
     var tnt=new Tnt(world,position);tnt.setDeltaMovement(velocity);tnt.setNoGravity(noGravity);tnt.setFuse(10_000);
     if(tnt.getBbWidth()!=.98f||tnt.getBbHeight()!=.98f)throw new AssertionError("Unexpected TNT dimensions");
     for(int tick=0;tick<20;tick++){
      var row=new JsonObject();row.add("before",snapshot(tnt));tnt.tick();row.add("after",snapshot(tnt));
      row.addProperty("floor",Block.getId(floor.defaultBlockState()));row.addProperty("layout",layout);row.addProperty("tick",tick);rows.add(row);
     }
    }
  var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("rows",rows);
  Files.writeString(Path.of(args[0]),new Gson().toJson(out));
  System.out.println("PASS: "+rows.size()+" actual PrimedTnt.tick/Entity.move observations; supplied world, no fluids, peers or block effects.");
 }
}
