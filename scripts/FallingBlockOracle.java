import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.server.level.ChunkMap;
import net.minecraft.server.level.ServerChunkCache;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.FallingBlockEntity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.gamerules.GameRule;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;

/**
 * Actual FallingBlockEntity falls (VMC-050a2) over supplied layouts: each
 * tick's motion, then the landing (the block it places) or the item it drops,
 * and `FallingBlock.isFree` for every state. The world is a stone floor at
 * y = 63 for |x|, |z| <= 6; layouts: 0 the floor, 1 a torch at (0, 64, 0),
 * 2 a bottom oak slab there, 3 water sources at y 64 and 65 for |x|, |z| <= 1.
 * No peers, fluids pushing, block effects or game events.
 * Usage: FallingBlockOracle OUT.json
 */
public class FallingBlockOracle {
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
 static class Tracking extends ChunkMap {
  private Tracking(){super(null,null,null,null,null,null,null,null,null,null,0,false);}
  public void sendToTrackingPlayers(Entity e,net.minecraft.network.protocol.Packet<? super net.minecraft.network.protocol.game.ClientGamePacketListener> p){}
 }
 static class Rules extends GameRules {
  private Rules(){super((net.minecraft.world.flag.FeatureFlagSet)null);}
  public <T> T get(GameRule<T> rule){return rule.defaultValue();}
 }
 static class World extends ServerLevel {
  Map<BlockPos,BlockState> blocks; Chunk chunk; WorldBorder border; ServerChunkCache cache; Rules rules;
  net.minecraft.world.damagesource.DamageSources sources;
  List<Entity> added=new ArrayList<>(); JsonArray placed=new JsonArray();
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
  public int getMinY(){return -64;}
  public int getHeight(){return 384;}
  public BlockState getBlockState(BlockPos p){return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
  public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos p){return null;}
  public ChunkAccess getChunk(int x,int z,ChunkStatus s,boolean load){return chunk;}
  public BlockGetter getChunkForCollisions(int x,int z){return this;}
  public WorldBorder getWorldBorder(){return border;}
  public List<VoxelShape> getEntityCollisions(Entity e,AABB box){return List.of();}
  public List<Entity> getEntities(Entity e,AABB box,Predicate<? super Entity> p){return List.of();}
  public boolean noCollision(Entity e,AABB box){return !getBlockCollisions(e,box).iterator().hasNext();}
  public boolean setBlock(BlockPos p,BlockState s,int flags,int budget){
   blocks.put(p.immutable(),s);var row=new JsonObject();row.add("position",vec(p.getX(),p.getY(),p.getZ()));row.addProperty("state",Block.getId(s));placed.add(row);return true;
  }
  public boolean addFreshEntity(Entity e){added.add(e);return true;}
  public void levelEvent(Entity e,int type,BlockPos p,int data){}
  public ServerChunkCache getChunkSource(){return cache;}
  public GameRules getGameRules(){return rules;}
  public net.minecraft.world.damagesource.DamageSources damageSources(){return sources;}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event,Vec3 at,net.minecraft.world.level.gameevent.GameEvent.Context context){}
 }
 static class Falling extends FallingBlockEntity {
  Falling(World w){super(EntityTypes.FALLING_BLOCK,w);}
  public void recordMovement(MoverType kind,Vec3 movement){}
  public void applyEffectsFromBlocks(){}
  public void applyEffectsFromBlocksForLastMovements(){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event){}
  public boolean updateFluidInteraction(){return false;}
 }
 // `FallingBlockEntity.fall`: the cell keeps its fluid, the body starts at its bottom centre.
 static Falling fall(World world,BlockPos pos,BlockState state)throws Exception{
  var e=new Falling(world);
  var falling=state.hasProperty(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED)
    ?state.setValue(net.minecraft.world.level.block.state.properties.BlockStateProperties.WATERLOGGED,false):state;
  field(FallingBlockEntity.class,"blockState").set(e,falling);e.blocksBuilding=true;
  e.setPos(pos.getX()+.5,pos.getY(),pos.getZ()+.5);e.setDeltaMovement(Vec3.ZERO);
  e.xo=e.getX();e.yo=e.getY();e.zo=e.getZ();e.setStartPos(e.blockPosition());
  world.setBlockAndUpdate(pos,state.getFluidState().createLegacyBlock());
  return e;
 }
 static Field field(Class<?> c,String n)throws Exception{var f=c.getDeclaredField(n);f.setAccessible(true);return f;}
 static JsonArray vec(double... nums){var a=new JsonArray();for(double n:nums)a.add(n);return a;}
 static JsonArray vec(Vec3 v){return vec(v.x,v.y,v.z);}
 static JsonObject snapshot(FallingBlockEntity e){
  var o=new JsonObject();o.add("position",vec(e.position()));o.add("velocity",vec(e.getDeltaMovement()));
  o.addProperty("on_ground",e.onGround());o.addProperty("time",e.time);o.addProperty("removed",e.isRemoved());
  o.addProperty("fall_distance",e.fallDistance);return o;
 }
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();BlockFactsOracle.bindOnly(net.minecraft.tags.BlockTags.FIRE);
  var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
  for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(net.minecraft.tags.FluidTags.WATER));
  for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(net.minecraft.tags.FluidTags.LAVA));
  var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
  var world=(World)u.allocateInstance(World.class);world.border=new WorldBorder();world.added=new ArrayList<>();
  world.chunk=(Chunk)u.allocateInstance(Chunk.class);world.chunk.sections=new LevelChunkSection[]{(Section)u.allocateInstance(Section.class)};
  world.cache=(ServerChunkCache)u.allocateInstance(ServerChunkCache.class);
  u.putObject(world.cache,u.objectFieldOffset(ServerChunkCache.class.getDeclaredField("chunkMap")),u.allocateInstance(Tracking.class));
  world.rules=(Rules)u.allocateInstance(Rules.class);
  world.sources=(net.minecraft.world.damagesource.DamageSources)u.allocateInstance(net.minecraft.world.damagesource.DamageSources.class);
  field(Level.class,"random").set(world,net.minecraft.util.RandomSource.create(0));
  var free=new JsonArray();
  for(var state:Block.BLOCK_STATE_REGISTRY)if(FallingBlock.isFree(state))free.add(Block.getId(state));
  var falls=new JsonArray();
  for(var block:List.of(Blocks.SAND,Blocks.GRAVEL,(Block)net.minecraft.core.registries.BuiltInRegistries.BLOCK.getValue(net.minecraft.resources.Identifier.withDefaultNamespace("red_concrete_powder")),Blocks.ANVIL))for(int layout=0;layout<4;layout++)
   for(int height:new int[]{65,67,72}){
    world.blocks=new LinkedHashMap<>();world.added=new ArrayList<>();world.placed=new JsonArray();
    for(int x=-6;x<=6;x++)for(int z=-6;z<=6;z++)world.blocks.put(new BlockPos(x,63,z),Blocks.STONE.defaultBlockState());
    if(layout==1)world.blocks.put(new BlockPos(0,64,0),Blocks.TORCH.defaultBlockState());
    if(layout==2)world.blocks.put(new BlockPos(0,64,0),Blocks.OAK_SLAB.defaultBlockState());
    if(layout==3)for(int x=-1;x<=1;x++)for(int z=-1;z<=1;z++)for(int y=64;y<=65;y++)world.blocks.put(new BlockPos(x,y,z),Blocks.WATER.defaultBlockState());
    var start=new BlockPos(0,height,0);var state=block.defaultBlockState();
    world.blocks.put(start,state);
    var entity=fall(world,start,state);
    if(block==Blocks.ANVIL)field(FallingBlockEntity.class,"hurtEntities").setBoolean(entity,false);
    field(Entity.class,"random").set(entity,net.minecraft.util.RandomSource.create(1));
    world.added.clear();
    var row=new JsonObject();row.addProperty("block",Block.getId(state));row.addProperty("layout",layout);row.add("start",vec(0,height,0));
    row.add("placed_on_fall",world.placed.deepCopy());world.placed=new JsonArray();
    var ticks=new JsonArray();
    for(int tick=0;tick<700&&!entity.isRemoved();tick++){var t=new JsonObject();t.add("before",snapshot(entity));entity.tick();t.add("after",snapshot(entity));ticks.add(t);}
    row.add("ticks",ticks);row.add("placed",world.placed);
    var drops=new JsonArray();
    for(var e:world.added)if(e instanceof ItemEntity item){var d=new JsonObject();d.add("position",vec(item.position()));d.addProperty("item",net.minecraft.core.registries.BuiltInRegistries.ITEM.getId(item.getItem().getItem()));d.addProperty("count",item.getItem().getCount());drops.add(d);}
    row.add("drops",drops);falls.add(row);
   }
  var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
  out.add("free",free);out.add("falls",falls);
  Files.writeString(Path.of(args[0]),new Gson().toJson(out));
  System.out.println("PASS: "+falls.size()+" actual FallingBlockEntity falls and "+free.size()+" free states; supplied world, no peers.");
 }
}
