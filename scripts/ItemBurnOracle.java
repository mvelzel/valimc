import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.level.chunk.*;
import net.minecraft.world.level.chunk.status.ChunkStatus;
import net.minecraft.world.level.entity.EntityTypeTest;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;

/**
 * Actual ItemEntity.tick and ExperienceOrb.tick with Entity.baseTick's burning and
 * applyEffectsFromBlocks (fire, soul fire, lava, water, cactus, rain) in a loaded world, through
 * hurtServer: health, burning, the on-fire shared flag and removal per tick, for stone, netherite
 * and an orb; then hurtServer's explosion damage on its own. No peers or sounds.
 */
public class ItemBurnOracle {
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
 static class Server extends net.minecraft.server.dedicated.DedicatedServer {
  net.minecraft.util.debug.ServerDebugSubscribers subscribers;
  private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
  public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers(){return subscribers;}
 }
 static class World extends ServerLevel {
  Server server;
  public net.minecraft.server.MinecraftServer getServer(){return server;}
  Map<BlockPos,BlockState> blocks; Set<BlockPos> queries; Chunk chunk; WorldBorder border; DamageSources sources; GameRules rules; Predicate<BlockPos> rain=p->false;
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
  public int getMinY(){return -64;}
  public BlockState getBlockState(BlockPos p){queries.add(p.immutable());return blocks.getOrDefault(p,Blocks.AIR.defaultBlockState());}
  public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos p){queries.add(p.immutable());return null;}
  public ChunkAccess getChunk(int x,int z,ChunkStatus s,boolean load){return chunk;}
  public BlockGetter getChunkForCollisions(int x,int z){return this;}
  public WorldBorder getWorldBorder(){return border;}
  public List<VoxelShape> getEntityCollisions(Entity e,AABB box){return List.of();}
  public List<Entity> getEntities(Entity e,AABB box,Predicate<? super Entity> p){return List.of();}
  public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> test,AABB box,Predicate<? super T> p){return List.of();}
  public boolean noCollision(Entity e,AABB box){return !getBlockCollisions(e,box).iterator().hasNext();}
  public Player getNearestPlayer(Entity e,double range){return null;}
  public DamageSources damageSources(){return sources;}
  public GameRules getGameRules(){return rules;}
  public boolean isRainingAt(BlockPos p){return rain.test(p);}
 }
 static class Item extends ItemEntity {
  EntityFluidInteraction contact=new EntityFluidInteraction(Set.of(FluidTags.WATER,FluidTags.LAVA));
  Item(World w,Vec3 position,Vec3 velocity,ItemStack stack){super(w,position.x,position.y,position.z,stack,velocity.x,velocity.y,velocity.z);}
  // Entity.baseTick's fluid update with the overworld's lava current; the rest of baseTick runs.
  public boolean updateFluidInteraction(){
   boolean changed=contact.update(this,false);
   contact.applyCurrentTo(FluidTags.WATER,this,.014);
   contact.applyCurrentTo(FluidTags.LAVA,this,.0023333333333333335);
   return changed;
  }
  public boolean isInWater(){return contact.isInFluid(FluidTags.WATER);}
  public boolean isInLava(){return contact.isInFluid(FluidTags.LAVA);}
  public double getFluidHeight(TagKey<Fluid> tag){return contact.getFluidHeight(tag);}
  protected boolean shouldPlayLavaHurtSound(){return false;}
  protected void playEntityOnFireExtinguishedSound(){}
  protected void checkFallDamage(double y,boolean ground,BlockState state,BlockPos p){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event,Entity cause){}
 }
 static class Orb extends ExperienceOrb {
  Orb(World w,Vec3 position,Vec3 velocity){super(EntityTypes.EXPERIENCE_ORB,w);setPos(position);setDeltaMovement(velocity);}
  protected boolean updateFluidInteraction(){
   try{
    var c=(EntityFluidInteraction)field(Entity.class,"fluidInteraction").get(this);
    boolean changed=c.update(this,false);
    c.applyCurrentTo(FluidTags.WATER,this,.014);
    c.applyCurrentTo(FluidTags.LAVA,this,.0023333333333333335);
    return changed;
   }catch(Exception e){throw new AssertionError(e);}
  }
  protected boolean shouldPlayLavaHurtSound(){return false;}
  protected void playEntityOnFireExtinguishedSound(){}
  protected void checkFallDamage(double y,boolean ground,BlockState state,BlockPos p){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event){}
  public void gameEvent(Holder<net.minecraft.world.level.gameevent.GameEvent> event,Entity cause){}
 }
 static int floatCalls;
 static RandomSource tape(int[] floats){
  int[] calls={0};
  return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,args)->{
   if(method.getName().equals("nextFloat")){floatCalls++;return floats[calls[0]++]/16777216f;}
   throw new AssertionError("Unexpected RNG call: "+method.getName());
  });
 }
 static Field field(Class<?> c,String n)throws Exception{var f=c.getDeclaredField(n);f.setAccessible(true);return f;}
 static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
 static JsonObject snapshot(Entity e)throws Exception{
  var o=new JsonObject();o.add("position",vec(e.position()));o.add("velocity",vec(e.getDeltaMovement()));o.addProperty("on_ground",e.onGround());
  o.addProperty("health",field(e instanceof ExperienceOrb?ExperienceOrb.class:ItemEntity.class,"health").getInt(e));
  o.addProperty("fire",e.getRemainingFireTicks());o.addProperty("removed",e.isRemoved());
  var flag=Entity.class.getDeclaredMethod("getSharedFlag",int.class);flag.setAccessible(true);o.addProperty("on_fire",(boolean)flag.invoke(e,0));
  if(e instanceof ItemEntity item){o.addProperty("age",field(ItemEntity.class,"age").getInt(item));o.addProperty("pickup_delay",field(ItemEntity.class,"pickupDelay").getInt(item));o.addProperty("water",item.isInWater());}
  return o;
 }
 static void put(World world,int x0,int x1,int z0,int z1,int y,BlockState state){for(int x=x0;x<=x1;x++)for(int z=z0;z<=z1;z++)world.blocks.put(new BlockPos(x,y,z),state);}

 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();BlockFactsOracle.bindOnly(BlockTags.BLOCKS_FLUID_FLOW);
  var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
  for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
  for(var fluid:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.LAVA));
  // Damage types with vanilla's tags, so is_fire and netherite's damage_resistant hold.
  var original=net.minecraft.data.registries.VanillaRegistries.createWorldLookup().lookupOrThrow(Registries.DAMAGE_TYPE);
  var damage=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
  for(var key:original.listElementIds().toList())damage.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);damage.freeze();
  try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
   var tags=TagLoader.loadTagsForRegistry(resources,Registries.DAMAGE_TYPE,(id,required)->damage.get(ResourceKey.create(Registries.DAMAGE_TYPE,id)));
   var memberships=new HashMap<Holder<DamageType>,List<TagKey<DamageType>>>();
   tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
   for(var holder:damage.listElements().toList())bind.invoke(holder,memberships.getOrDefault(holder,List.of()));
  }
  var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
  var world=(World)u.allocateInstance(World.class);world.border=new WorldBorder();
  world.sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(damage)).freeze());
  world.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
  world.server=(Server)u.allocateInstance(Server.class);world.server.subscribers=new net.minecraft.util.debug.ServerDebugSubscribers(world.server);
  world.chunk=(Chunk)u.allocateInstance(Chunk.class);world.chunk.sections=new LevelChunkSection[]{(Section)u.allocateInstance(Section.class)};
  var netherite=new ItemStack(Items.NETHERITE_INGOT);
  if(netherite.canBeHurtBy(world.sources.lava())||!new ItemStack(Items.STONE).canBeHurtBy(world.sources.lava()))throw new AssertionError("Fire resistance not bound");
  var random=new Random(34);var rows=new JsonArray();int removed=0;
  String[] kinds={"stone","netherite","orb"};
  for(int kind=0;kind<3;kind++)for(int layout=0;layout<7;layout++)
   for(var position:List.of(new Vec3(.5,64,.5),new Vec3(.5,66,.5),new Vec3(-1.5,64.3,.5)))
    for(var velocity:List.of(Vec3.ZERO,new Vec3(.3,.2,0),new Vec3(.6,.1,.05))){
     world.blocks=new LinkedHashMap<>();world.queries=new HashSet<>();
     // Layout 6 rains from x 1 on: what burns in the fire at x 0 goes out past it.
     world.rain=layout==6?p->p.getX()>=1:p->false;
     put(world,-6,6,-6,6,63,(layout==2?Blocks.SOUL_SOIL:Blocks.STONE).defaultBlockState());
     switch(layout){
      case 0->put(world,-4,4,-4,4,64,Blocks.LAVA.defaultBlockState());
      case 1->put(world,-4,4,-4,4,64,Blocks.FIRE.defaultBlockState());
      case 2->put(world,-4,4,-4,4,64,Blocks.SOUL_FIRE.defaultBlockState());
      case 3->put(world,2,2,-4,4,64,Blocks.CACTUS.defaultBlockState());
      case 4->{put(world,0,0,-4,4,64,Blocks.FIRE.defaultBlockState());put(world,2,4,-4,4,64,Blocks.WATER.defaultBlockState());}
      default->put(world,0,0,-4,4,64,Blocks.FIRE.defaultBlockState());
     }
     Entity e=kind==2?new Orb(world,position,velocity):new Item(world,position,velocity,new ItemStack(kind==0?Items.STONE:Items.NETHERITE_INGOT));
     if(e instanceof Item item)item.setPickUpDelay(40);
     int resting=0;
     for(int tick=0;tick<200&&!e.isRemoved()&&resting<3&&e.getY()>=63;tick++){
      // ServerLevel.tickNonPassenger: the old position is where the tick starts.
      e.setOldPosAndRot();e.tickCount=3;world.queries.clear();var row=new JsonObject();row.addProperty("kind",kinds[kind]);row.addProperty("layout",layout);row.addProperty("tick",tick);row.add("before",snapshot(e));
      int[] draws={random.nextInt(1<<24),random.nextInt(1<<24),random.nextInt(1<<24),random.nextInt(1<<24)};
      floatCalls=0;
      if(e instanceof Orb){field(Entity.class,"random").set(e,tape(draws));row.add("draws",new Gson().toJsonTree(draws));}
      e.tick();
      if(e instanceof Orb&&floatCalls!=0&&floatCalls!=4)throw new AssertionError("Lava draws "+floatCalls+" "+row);
      row.add("after",snapshot(e));
      var states=new JsonArray();for(var p:world.queries){var s=new JsonObject();s.add("position",vec(new Vec3(p.getX(),p.getY(),p.getZ())));s.addProperty("state",Block.getId(world.blocks.getOrDefault(p,Blocks.AIR.defaultBlockState())));states.add(s);}
      row.add("states",states);rows.add(row);
      if(e.isRemoved())removed++;
      resting=e.onGround()&&e.getRemainingFireTicks()<=0&&e.getDeltaMovement().lengthSqr()<1e-4?resting+1:0;
     }
    }
  if(removed<60)throw new AssertionError("Too few burned up: "+removed);
  // hurtServer alone with an explosion's damage: health as a float less the damage, truncated.
  world.blocks=new LinkedHashMap<>();world.queries=new HashSet<>();world.rain=p->false;
  var hurts=new JsonArray();
  float[] damages={.5f,1f,1.5f,2.9999998f,3f,4f,4.0000005f,4.9999995f,5f,7.25f,12.5f};
  for(var kind:List.of("stone","nether_star","orb"))for(int health:new int[]{5,3,1,0})for(float amount:damages){
   Entity e=kind.equals("orb")?new Orb(world,new Vec3(.5,64,.5),Vec3.ZERO):new Item(world,new Vec3(.5,64,.5),Vec3.ZERO,new ItemStack(kind.equals("stone")?Items.STONE:Items.NETHER_STAR));
   field(e instanceof ExperienceOrb?ExperienceOrb.class:ItemEntity.class,"health").setInt(e,health);
   e.hurtServer(world,world.sources.explosion(null,null),amount);
   var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("health",health);row.addProperty("damage",amount);
   row.addProperty("after",field(e instanceof ExperienceOrb?ExperienceOrb.class:ItemEntity.class,"health").getInt(e));row.addProperty("removed",e.isRemoved());hurts.add(row);
  }
  var out=new JsonObject();out.add("ticks",rows);out.add("hurts",hurts);
  Files.writeString(Path.of(args[0]),new Gson().toJson(out));
  System.out.println("PASS: "+rows.size()+" actual ItemEntity/ExperienceOrb ticks with burning, block effects and rain, "+removed+" burned up; "+hurts.size()+" explosion hurts; no peers or sounds.");
 }
}
