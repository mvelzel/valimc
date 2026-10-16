import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.FluidTags;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;

/** Actual ItemEntity.tick + Entity.move, with loaded block geometry and no peers/base-tick effects. */
public class ItemTravelOracle {
 static class Section extends LevelChunkSection {
  private Section(){super((PalettedContainerFactory)null);}
  public boolean hasFluid(){return true;}
 }
 static class Chunk extends LevelChunk {
  LevelChunkSection[] sections;
  private Chunk(){super((Level)null,(ChunkPos)null);}
  public LevelChunkSection[] getSections(){return sections;}
  public int getSectionIndexFromSectionY(int y){return 0;}
 }
 static class World extends ServerLevel {
  Map<BlockPos,BlockState> blocks; Set<BlockPos> queries; Chunk chunk; WorldBorder border;
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
  public BlockState getBlockState(BlockPos p){queries.add(p.immutable());return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
  public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos p){queries.add(p.immutable());return null;}
  public ChunkAccess getChunk(int x,int z,ChunkStatus s,boolean load){return chunk;}
  public BlockGetter getChunkForCollisions(int x,int z){return this;}
  public WorldBorder getWorldBorder(){return border;}
  public List<VoxelShape> getEntityCollisions(Entity e,AABB box){return List.of();}
  public List<Entity> getEntities(Entity e,AABB box,Predicate<? super Entity> p){return List.of();}
  public boolean noCollision(Entity e,AABB box){return !getBlockCollisions(e,box).iterator().hasNext();}
 }
 static class Item extends ItemEntity {
  EntityFluidInteraction contact=new EntityFluidInteraction(Set.of(FluidTags.WATER,FluidTags.LAVA));
  Vec3 requested;
  Item(World w,Vec3 position,Vec3 velocity){super(w,position.x,position.y,position.z,new ItemStack(Items.STONE,3),velocity.x,velocity.y,velocity.z);}
  public void baseTick(){updateFluidInteraction();}
  public boolean updateFluidInteraction(){
   boolean changed=contact.update(this,false);
   contact.applyCurrentTo(FluidTags.WATER,this,.014);
   contact.applyCurrentTo(FluidTags.LAVA,this,.0023333333333333335);
   return changed;
  }
  public boolean isInWater(){return contact.isInFluid(FluidTags.WATER);}
  public boolean isInLava(){return contact.isInFluid(FluidTags.LAVA);}
  public double getFluidHeight(net.minecraft.tags.TagKey<Fluid> tag){return contact.getFluidHeight(tag);}
  public void move(MoverType kind,Vec3 movement){requested=movement;super.move(kind,movement);}
  public void recordMovement(MoverType kind,Vec3 movement){}
  public void applyEffectsFromBlocks(){}
  public void applyEffectsFromBlocksForLastMovements(){}
  protected void checkFallDamage(double y,boolean ground,BlockState state,BlockPos p){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event){}
 }
 static Field field(Class<?> c,String n)throws Exception{var f=c.getDeclaredField(n);f.setAccessible(true);return f;}
 static JsonArray vec(double... nums){var a=new JsonArray();for(double n:nums)a.add(n);return a;}
 static JsonArray vec(Vec3 v){return vec(v.x,v.y,v.z);}
 static JsonObject snapshot(Item item)throws Exception{
  var o=new JsonObject();o.add("position",vec(item.position()));o.add("velocity",vec(item.getDeltaMovement()));o.addProperty("on_ground",item.onGround());o.addProperty("no_gravity",item.isNoGravity());o.addProperty("age",field(ItemEntity.class,"age").getInt(item));o.addProperty("pickup_delay",field(ItemEntity.class,"pickupDelay").getInt(item));return o;
 }
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();FluidBoundaryMetadata.bindFlowTag();
  var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
  for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
  for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.LAVA));
  var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
  var world=(World)u.allocateInstance(World.class);world.border=new WorldBorder();
  world.chunk=(Chunk)u.allocateInstance(Chunk.class);world.chunk.sections=new LevelChunkSection[]{(Section)u.allocateInstance(Section.class)};
  var rows=new JsonArray();
  for(var floor:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK,Blocks.HONEY_BLOCK,Blocks.OAK_SLAB))for(int layout=0;layout<6;layout++)
   for(var position:List.of(new Vec3(.5,64,.5),new Vec3(.5,65.5,.5),new Vec3(.5,64.125,.5)))
    for(var velocity:List.of(Vec3.ZERO,new Vec3(.3,.2,-.1),new Vec3(.7,-.8,.7)))for(boolean noGravity:new boolean[]{false,true}){
     world.blocks=new LinkedHashMap<>();world.queries=new HashSet<>();
     for(int x=-6;x<=6;x++)for(int z=-6;z<=6;z++)world.blocks.put(new BlockPos(x,63,z),floor.defaultBlockState());
     if(layout==1)for(int z=-5;z<=5;z++)for(int y=64;y<=67;y++)world.blocks.put(new BlockPos(2,y,z),Blocks.STONE.defaultBlockState());
     if(layout==5)for(int x=-6;x<=6;x++)for(int z=-6;z<=6;z++)world.blocks.put(new BlockPos(x,66,z),Blocks.STONE.defaultBlockState());
     if(layout>=2&&layout<=4){var fluid=layout==4?Blocks.LAVA:Blocks.WATER;for(int x=-4;x<=4;x++)for(int z=-4;z<=4;z++)world.blocks.put(new BlockPos(x,64,z),fluid.defaultBlockState().setValue(LiquidBlock.LEVEL,layout==3?Math.min(7,x+4):0));}
     var item=new Item(world,position,velocity);item.setNoGravity(noGravity);item.setPickUpDelay(40);
     if(item.getBbWidth()!=.25f||item.getBbHeight()!=.25f)throw new AssertionError("Unexpected item dimensions");
     for(int tick=0;tick<24;tick++){
      item.tickCount=3;world.queries.clear();var row=new JsonObject();row.add("before",snapshot(item));
      item.tick();row.add("after",snapshot(item));row.add("requested",item.requested==null?JsonNull.INSTANCE:vec(item.requested));item.requested=null;
      var states=new JsonArray();for(var p:world.queries){var s=new JsonObject();s.add("position",vec(p.getX(),p.getY(),p.getZ()));s.addProperty("state",Block.getId(world.blocks.getOrDefault(p,Blocks.AIR.defaultBlockState())));states.add(s);}row.add("states",states);row.addProperty("layout",layout);row.addProperty("tick",tick);rows.add(row);
     }
    }
  Files.writeString(Path.of(args[0]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" actual ItemEntity.tick/Entity.move observations; supplied loaded world, no peers/block effects.");
 }
}
