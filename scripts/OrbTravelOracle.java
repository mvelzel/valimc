import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.FluidTags;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.entity.EntityTypeTest;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;

/**
 * Actual ExperienceOrb behaviour: tick + Entity.move in a loaded world (no peers, block effects or
 * burning), scanForMerges among supplied orbs, and awardWithDirection's merge-or-spawn choice.
 */
public class OrbTravelOracle {
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
 static class Target extends Player {
  private Target(){super(null,null);}
  public GameType gameMode(){return GameType.SURVIVAL;}
  public boolean isDeadOrDying(){return false;}
 }
 static class World extends ServerLevel {
  Map<BlockPos,BlockState> blocks=new HashMap<>(); Set<BlockPos> queries=new HashSet<>(); Chunk chunk; WorldBorder border;
  Player target; List<ExperienceOrb> orbs=new ArrayList<>(); int nextId; int[] picks; int pickCalls;
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return nextId++;}
  public BlockState getBlockState(BlockPos p){queries.add(p.immutable());return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
  public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos p){queries.add(p.immutable());return null;}
  public ChunkAccess getChunk(int x,int z,ChunkStatus s,boolean load){return chunk;}
  public BlockGetter getChunkForCollisions(int x,int z){return this;}
  public WorldBorder getWorldBorder(){return border;}
  public List<VoxelShape> getEntityCollisions(Entity e,AABB box){return List.of();}
  public List<Entity> getEntities(Entity e,AABB box,Predicate<? super Entity> p){return List.of();}
  public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> test,AABB box,Predicate<? super T> p){
   var found=new ArrayList<T>();
   for(var orb:orbs){T t=test.tryCast(orb);if(t!=null&&!orb.isRemoved()&&orb.getBoundingBox().intersects(box)&&p.test(t))found.add(t);}
   return found;
  }
  public boolean noCollision(Entity e,AABB box){return !getBlockCollisions(e,box).iterator().hasNext();}
  public Player getNearestPlayer(Entity e,double range){return target!=null&&target.distanceToSqr(e)<range*range?target:null;}
  public RandomSource getRandom(){return tape(null,(n)->{if(n!=40)throw new AssertionError("bound");return picks[pickCalls++];});}
  public boolean addFreshEntity(Entity e){orbs.add((ExperienceOrb)e);return true;}
 }
 interface Ints{int next(int bound);}
 static RandomSource tape(int[] floats,Ints ints){
  int[] calls={0};
  return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,args)->{
   if(method.getName().equals("nextFloat")&&floats!=null){floatCalls++;return floats[calls[0]++]/16777216f;}
   if(method.getName().equals("nextInt")&&ints!=null&&args!=null&&args.length==1)return ints.next((Integer)args[0]);
   throw new AssertionError("Unexpected RNG call: "+method.getName());
  });
 }
 static int floatCalls;
 static class Orb extends ExperienceOrb {
  Vec3 requested;
  Orb(World w,Vec3 position,Vec3 velocity){super(EntityTypes.EXPERIENCE_ORB,w);setPos(position);setDeltaMovement(velocity);}
  // Entity.baseTick's fluid update and currents (overworld lava speed); burning and portals excluded.
  public void baseTick(){
   try{
    var c=(EntityFluidInteraction)field(Entity.class,"fluidInteraction").get(this);
    c.update(this,false);
    c.applyCurrentTo(FluidTags.WATER,this,.014);
    c.applyCurrentTo(FluidTags.LAVA,this,.0023333333333333335);
   }catch(Exception e){throw new AssertionError(e);}
  }
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
 static JsonObject snapshot(Entity orb){
  var o=new JsonObject();o.add("position",vec(orb.position()));o.add("velocity",vec(orb.getDeltaMovement()));o.addProperty("on_ground",orb.onGround());return o;
 }
 static void setValue(ExperienceOrb orb,int value)throws Exception{
  var m=ExperienceOrb.class.getDeclaredMethod("setValue",int.class);m.setAccessible(true);m.invoke(orb,value);
 }

 static JsonArray travel(World world)throws Exception{
  var rows=new JsonArray();var random=new Random(34);
  var player=(Target)unsafe.allocateInstance(Target.class);
  field(Entity.class,"position").set(player,new Vec3(4.5,64,.5));field(Entity.class,"eyeHeight").setFloat(player,1.62f);
  for(var floor:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK,Blocks.HONEY_BLOCK,Blocks.OAK_SLAB))for(int layout=0;layout<6;layout++)
   for(var position:List.of(new Vec3(.5,64,.5),new Vec3(.5,65.5,.5),new Vec3(.5,64.125,.5)))
    for(var velocity:List.of(Vec3.ZERO,new Vec3(.3,.2,-.1),new Vec3(.7,-.8,.7)))for(boolean follows:new boolean[]{false,true}){
     world.blocks=new LinkedHashMap<>();world.target=follows?player:null;
     for(int x=-6;x<=6;x++)for(int z=-6;z<=6;z++)world.blocks.put(new BlockPos(x,63,z),floor.defaultBlockState());
     if(layout==1)for(int z=-5;z<=5;z++)for(int y=64;y<=67;y++)world.blocks.put(new BlockPos(2,y,z),Blocks.STONE.defaultBlockState());
     if(layout==5)for(int x=-6;x<=6;x++)for(int z=-6;z<=6;z++)world.blocks.put(new BlockPos(x,66,z),Blocks.STONE.defaultBlockState());
     if(layout>=2&&layout<=4){var fluid=layout==4?Blocks.LAVA:Blocks.WATER;for(int x=-4;x<=4;x++)for(int z=-4;z<=4;z++)world.blocks.put(new BlockPos(x,64,z),fluid.defaultBlockState().setValue(LiquidBlock.LEVEL,layout==3?Math.min(7,x+4):0));}
     var orb=new Orb(world,position,velocity);
     if(orb.getBbWidth()!=.5f||orb.getBbHeight()!=.5f)throw new AssertionError("Unexpected orb dimensions");
     for(int tick=0;tick<24;tick++){
      // tickCount 3 never scans for merges; the age never reaches its end.
      orb.tickCount=3;world.queries.clear();var row=new JsonObject();row.add("before",snapshot(orb));
      int[] draws={random.nextInt(1<<24),random.nextInt(1<<24),random.nextInt(1<<24),random.nextInt(1<<24)};
      floatCalls=0;field(Entity.class,"random").set(orb,tape(draws,null));
      orb.tick();
      if(floatCalls!=0&&floatCalls!=4)throw new AssertionError("Lava draws");
      var followed=(Player)field(ExperienceOrb.class,"followingPlayer").get(orb);
      row.add("target",followed==null?JsonNull.INSTANCE:vec(followed.getX(),followed.getY()+(double)followed.getEyeHeight()/2,followed.getZ()));
      row.add("draws",new Gson().toJsonTree(draws));row.addProperty("jumped",floatCalls==4);
      row.add("after",snapshot(orb));orb.requested=null;
      var states=new JsonArray();for(var p:world.queries){var s=new JsonObject();s.add("position",vec(p.getX(),p.getY(),p.getZ()));s.addProperty("state",Block.getId(world.blocks.getOrDefault(p,Blocks.AIR.defaultBlockState())));states.add(s);}
      row.add("states",states);row.addProperty("layout",layout);row.addProperty("tick",tick);rows.add(row);
     }
    }
  return rows;
 }

 static JsonArray merges(World world)throws Exception{
  var rows=new JsonArray();var random=new Random(40);
  double[] dxs={0,.5,.75,Math.nextDown(1.0),1.0,-Math.nextDown(1.0),-1.0,-.25};
  double[] dys={0,.5,Math.nextDown(1.0),1.0,-Math.nextDown(1.0),-1.0,-.75};
  int[] values={1,3,7};
  for(int scene=0;scene<600;scene++){
   world.blocks=new HashMap<>();world.orbs=new ArrayList<>();world.target=null;
   int n=2+random.nextInt(7);var row=new JsonObject();var before=new JsonArray();var ids=new HashSet<Integer>();
   for(int i=0;i<n;i++){
    var p=new Vec3(-17.5+dxs[random.nextInt(dxs.length)],64+dys[random.nextInt(dys.length)],128.25+dxs[random.nextInt(dxs.length)]);
    var orb=new Orb(world,p,Vec3.ZERO);
    int id;do id=random.nextBoolean()?1000+40*random.nextInt(4):1000+random.nextInt(200)-100;while(!ids.add(id));
    orb.setId(id);setValue(orb,values[random.nextInt(random.nextInt(4)==0?3:1)]);
    int count=1+random.nextInt(3),age=random.nextInt(6000);
    field(ExperienceOrb.class,"count").setInt(orb,count);field(ExperienceOrb.class,"age").setInt(orb,age);
    world.orbs.add(orb);
    var o=new JsonObject();o.addProperty("id",id);o.addProperty("value",orb.getValue());o.addProperty("count",count);o.addProperty("age",age);o.add("position",vec(p));before.add(o);
   }
   // Each orb scans in list order, as in one tick where every one is due; a merged one is gone.
   var scan=ExperienceOrb.class.getDeclaredMethod("scanForMerges");scan.setAccessible(true);
   for(var orb:world.orbs)if(!orb.isRemoved())scan.invoke(orb);
   var after=new JsonArray();
   for(var orb:world.orbs){var o=new JsonObject();o.addProperty("removed",orb.isRemoved());o.addProperty("count",field(ExperienceOrb.class,"count").getInt(orb));o.addProperty("age",field(ExperienceOrb.class,"age").getInt(orb));after.add(o);}
   row.add("before",before);row.add("after",after);rows.add(row);
  }
  return rows;
 }

 static JsonArray awards(World world)throws Exception{
  var rows=new JsonArray();var random=new Random(26);
  int[][] amounts={{1},{10},{3,3},{7,7,7},{6,4,13},{2477*3+5},{1,1,1,1,1,1,1,1,1,1},{45},{120},{11,11,11,11,11,11,11,11,11,11,11,11},new int[100],{2477*60}};
  Arrays.fill(amounts[10],1);
  for(var amount:amounts)for(int base:new int[]{1,39,1000})for(int run=0;run<4;run++){
   world.blocks=new HashMap<>();world.orbs=new ArrayList<>();world.nextId=base;
   world.picks=new int[4096];for(int i=0;i<world.picks.length;i++)world.picks[i]=run==0?0:random.nextInt(40);
   world.pickCalls=0;
   for(int points:amount)ExperienceOrb.awardWithDirection(world,new Vec3(.5,64.5,.5),Vec3.ZERO,points);
   var row=new JsonObject();row.add("amounts",new Gson().toJsonTree(amount));row.addProperty("base",base);
   row.add("picks",new Gson().toJsonTree(Arrays.copyOf(world.picks,world.pickCalls)));
   var orbs=new JsonArray();
   for(var orb:world.orbs){var o=new JsonArray();o.add(orb.getId());o.add(orb.getValue());o.add(field(ExperienceOrb.class,"count").getInt(orb));orbs.add(o);}
   row.add("orbs",orbs);rows.add(row);
  }
  return rows;
 }

 static sun.misc.Unsafe unsafe;
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();BlockFactsOracle.bindOnly(net.minecraft.tags.BlockTags.BLOCKS_FLUID_FLOW);
  var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
  for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
  for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.LAVA));
  unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
  var world=(World)unsafe.allocateInstance(World.class);world.border=new WorldBorder();
  world.blocks=new HashMap<>();world.queries=new HashSet<>();world.orbs=new ArrayList<>();world.nextId=1;
  world.chunk=(Chunk)unsafe.allocateInstance(Chunk.class);world.chunk.sections=new LevelChunkSection[]{(Section)unsafe.allocateInstance(Section.class)};
  var output=new JsonObject();
  var travel=travel(world);var merges=merges(world);var awards=awards(world);
  output.add("travel",travel);output.add("merges",merges);output.add("awards",awards);
  Files.writeString(Path.of(args[0]),new Gson().toJson(output));
  System.out.println("PASS: "+travel.size()+" actual ExperienceOrb.tick/Entity.move steps, "+merges.size()+" scanForMerges scenes and "+awards.size()+" awardWithDirection runs; no block effects, burning or peers.");
 }
}
