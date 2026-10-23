import com.google.gson.*;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.ReloadableServerRegistries;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.core.registries.Registries;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.tags.TagLoader;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntitySelector;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.RecipeManager;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.entity.EntityTypeTest;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.redstone.CollectingNeighborUpdater;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.ticks.TickPriority;

/**
 * Hoppers moving items (VMC-049a), from pinned 26.3: `scenes OUT [SCENES [SEED]]` runs hopper
 * chains, hopper-fed furnaces and hoppers picking up item entities over a probe level whose block
 * entities live and tick as `LevelChunk` and `Level.tickBlockEntities` keep them (in the order they
 * were created: the containers, then the furnaces) and whose entity lookups list entities as the
 * level's entity sections do (by section, then in the order they were added). Each game tick runs
 * the scripted block sets first (redstone blocks that lock and free hoppers, as `/setblock` makes
 * them), then each item entity's `HopperBlock.entityInside` for the hopper cells its box is in
 * (item entities do not move: what their own tick would do besides is left out), then the block
 * entities. Per tick: the cell writes, every container that changed (its slots, a hopper's
 * cooldown, a furnace's timers) and every item entity's count that changed. Scenes:
 *
 * - chains: a chest over a path of hoppers in any direction but up, some holding stacks, ending
 *   in a chest, a hopper, a dropper, a furnace or nothing, with a second chest over one of them;
 * - furnaces: a furnace fed from above (inputs, some that do not smelt) and from a side (fuels,
 *   buckets, things that do not burn), with a hopper below taking its results and buckets;
 * - pickups: hoppers under item entities at and above them, some covered by a full block, a slab
 *   or a chest, some nearly full, the items of several sizes and stack limits.
 *
 * Usage: HopperOracle scenes OUT [SCENES [SEED]]
 */
public class HopperOracle {
  static final int TICKS = 240;

  static class Server extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }

  static final class Ticker{BlockEntity entity;Ticker(BlockEntity entity){this.entity=entity;}}

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Map<BlockPos,BlockEntity> entities;Server server;RandomSource random;RecipeManager recipes;
    RegistryAccess access;long time;
    List<Ticker> tickers=new ArrayList<>();Map<BlockPos,Ticker> tickerAt=new HashMap<>();
    List<Entity> things=new ArrayList<>();JsonArray writes=new JsonArray();
    private Probe(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    BlockState cell(BlockPos pos){return cells.getOrDefault(pos,Blocks.AIR.defaultBlockState());}
    @Override public BlockState getBlockState(BlockPos pos){return cell(pos);}
    @Override public FluidState getFluidState(BlockPos pos){return cell(pos).getFluidState();}
    @Override public BlockEntity getBlockEntity(BlockPos pos){return entities.get(pos);}
    @Override public void blockEntityChanged(BlockPos pos){}
    @Override public int getMinY(){return -64;}
    @Override public int getHeight(){return 384;}
    @Override public MinecraftServer getServer(){return server;}
    @Override public RandomSource getRandom(){return random;}
    @Override public long getGameTime(){return time;}
    @Override public RegistryAccess registryAccess(){return access;}
    @Override public RecipeManager recipeAccess(){return recipes;}
    @Override public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    @Override public boolean isClientSide(){return false;}
    @Override public boolean isLoaded(BlockPos pos){return !isOutsideBuildHeight(pos);}
    @Override public boolean hasChunkAt(BlockPos pos){return true;}
    @Override public boolean hasChunk(int x,int z){return true;}
    @Override public void levelEvent(Entity source,int type,BlockPos pos,int data){}
    @Override public void blockEvent(BlockPos pos,Block block,int b0,int b1){}
    @Override public void gameEvent(Holder<GameEvent> event,Vec3 at,GameEvent.Context context){}
    @Override public void gameEvent(Entity source,Holder<GameEvent> event,BlockPos pos){}
    @Override public void playSeededSound(Entity except,double x,double y,double z,Holder<SoundEvent> sound,SoundSource source,float volume,float pitch,long seed){}
    @Override public boolean addFreshEntity(Entity entity){throw new AssertionError("an entity in a hopper scene: "+entity);}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay,TickPriority priority){}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay){}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay,TickPriority priority){}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay){}
    int ids;
    @Override public int getNextEntityId(){return ++ids;}

    /** `EntitySectionStorage.forEachAccessibleNonEmptySection`: sections by x, then `SectionPos.asLong`; each in insertion order. */
    List<Entity> listed(AABB bb){
      var out=new ArrayList<Entity>();
      for(var e:things)if(!e.isRemoved()&&e.getBoundingBox().intersects(bb))out.add(e);
      out.sort(Comparator.comparingInt((Entity e)->SectionPos.blockToSectionCoord(e.getBlockX()))
        .thenComparingLong(e->SectionPos.asLong(0,SectionPos.blockToSectionCoord(e.getBlockY()),SectionPos.blockToSectionCoord(e.getBlockZ())))
        .thenComparingInt(things::indexOf));
      return out;
    }
    @Override public List<Entity> getEntities(Entity except,AABB bb,Predicate<? super Entity> selector){
      var out=new ArrayList<Entity>();
      for(var e:listed(bb))if(e!=except&&(selector==null||selector.test(e)))out.add(e);
      return out;
    }
    @Override public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> type,AABB bb,Predicate<? super T> selector){
      var out=new ArrayList<T>();
      for(var e:listed(bb)){T t=type.tryCast(e);if(t!=null&&selector.test(t))out.add(t);}
      return out;
    }

    /** `LevelChunk.setBlockEntity` with `addAndRegisterBlockEntity`'s ticker. */
    @Override public void setBlockEntity(BlockEntity entity){
      var pos=entity.getBlockPos().immutable();var state=cell(pos);
      if(!state.hasBlockEntity())return;
      if(state!=entity.getBlockState()){if(!entity.getType().isValid(state))return;entity.setBlockState(state);}
      entity.setLevel(this);entity.clearRemoved();
      var previous=entities.put(pos,entity);if(previous!=null&&previous!=entity)previous.setRemoved();
      ticker(entity);
    }
    @SuppressWarnings("unchecked")
    void ticker(BlockEntity entity){
      var pos=entity.getBlockPos().immutable();
      if(entity.getBlockState().getTicker(this,(BlockEntityType<BlockEntity>)entity.getType())==null){
        var t=tickerAt.remove(pos);if(t!=null)t.entity=null;return;
      }
      var existing=tickerAt.get(pos);
      if(existing!=null)existing.entity=entity;
      else{var t=new Ticker(entity);tickers.add(t);tickerAt.put(pos,t);}
    }
    @Override public void removeBlockEntity(BlockPos pos){
      var removed=entities.remove(pos);if(removed!=null)removed.setRemoved();
      var t=tickerAt.remove(pos);if(t!=null)t.entity=null;
    }

    /** `Level.setBlock` over `LevelChunk.setBlockState`. */
    @Override public boolean setBlock(BlockPos pos,BlockState state,int flags,int limit){
      if(isOutsideBuildHeight(pos))return false;
      pos=pos.immutable();var old=cell(pos);
      if(old==state)return false;
      cells.put(pos,state);writes.add(RedstoneOracle.row(pos,Block.getId(state)));
      var block=state.getBlock();boolean changed=!old.is(block),moved=(flags&64)!=0,sideEffects=(flags&256)==0;
      if(changed&&old.hasBlockEntity()&&!state.shouldChangedStateKeepBlockEntity(old)){
        if(sideEffects){var entity=getBlockEntity(pos);if(entity!=null)entity.preRemoveSideEffects(pos,old);}
        removeBlockEntity(pos);
      }
      if((changed||block instanceof BaseRailBlock)&&((flags&1)!=0||moved))old.affectNeighborsAfterRemoval(this,pos,moved);
      if(!cell(pos).is(block))return false;
      if((flags&512)==0)state.onPlace(this,pos,old,moved);
      if(state.hasBlockEntity()&&cell(pos).is(block)){
        var entity=entities.get(pos);
        if(entity!=null&&!entity.isValidBlockState(state)){removeBlockEntity(pos);entity=null;}
        if(entity==null){
          entity=((EntityBlock)block).newBlockEntity(pos,state);
          if(entity!=null)setBlockEntity(entity);
        }else{entity.setBlockState(state);ticker(entity);}
      }
      if(cell(pos)!=state)return true;
      if((flags&1)!=0){
        updateNeighborsAt(pos,old.getBlock());
        if(state.hasAnalogOutputSignal())updateNeighbourForOutputSignal(pos,block);
      }
      if((flags&16)==0&&limit>0){
        int neighbour=flags&-34;
        old.updateIndirectNeighbourShapes(this,pos,neighbour,limit-1);
        state.updateNeighbourShapes(this,pos,neighbour,limit-1);
        state.updateIndirectNeighbourShapes(this,pos,neighbour,limit-1);
      }
      return true;
    }

    /** `Level.tickBlockEntities` with `BoundTickingBlockEntity.tick`. */
    @SuppressWarnings("unchecked")
    @Override public void tickBlockEntities(){
      var it=tickers.iterator();
      while(it.hasNext()){
        var t=it.next();
        if(t.entity==null){it.remove();continue;}
        var entity=t.entity;if(entity.isRemoved())continue;
        var pos=entity.getBlockPos();var state=cell(pos);
        if(!entity.getType().isValid(state))continue;
        var ticker=state.getTicker(this,(BlockEntityType<BlockEntity>)entity.getType());
        if(ticker!=null)ticker.tick(this,pos,state,entity);
      }
    }

    /** Each item entity's `HopperBlock.entityInside` for the hopper cells its box (deflated by 1e-5) is in, x fastest. */
    void entitiesInside(){
      for(var e:new ArrayList<>(things)){
        if(e.isRemoved())continue;
        var box=e.getBoundingBox().deflate(1.0E-5);
        for(var pos:BlockPos.betweenClosed(BlockPos.containing(box.minX,box.minY,box.minZ),BlockPos.containing(box.maxX,box.maxY,box.maxZ))){
          var state=cell(pos);
          if(state.getBlock() instanceof HopperBlock&&getBlockEntity(pos) instanceof HopperBlockEntity hopper&&!e.isRemoved())
            HopperBlockEntity.entityInside(this,pos.immutable(),state,e,hopper);
        }
      }
    }
  }

  static Field field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}

  static Probe probe(RegistryAccess access,RecipeManager recipes,ReloadableServerRegistries.Holder registries)throws Exception{
    var theUnsafe=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");theUnsafe.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)theUnsafe.get(null);
    var server=(Server)unsafe.allocateInstance(Server.class);server.registries=registries;
    var probe=(Probe)unsafe.allocateInstance(Probe.class);probe.server=server;probe.access=access;probe.recipes=recipes;
    var updater=Level.class.getDeclaredField("neighborUpdater");updater.setAccessible(true);
    updater.set(probe,new CollectingNeighborUpdater(probe,1_000_000));
    var players=ServerLevel.class.getDeclaredField("players");players.setAccessible(true);players.set(probe,new ArrayList<>());
    var seeds=Level.class.getDeclaredField("soundSeedGenerator");seeds.setAccessible(true);seeds.set(probe,RandomSource.create(0));
    return probe;
  }

  static Item item(String name){return BuiltInRegistries.ITEM.getValue(Identifier.parse("minecraft:"+name));}

  static final List<Direction> SIDES=List.of(Direction.NORTH,Direction.SOUTH,Direction.WEST,Direction.EAST);
  static final List<Direction> HOPPER_FACINGS=List.of(Direction.DOWN,Direction.NORTH,Direction.SOUTH,Direction.WEST,Direction.EAST);
  static final List<String> MISC=List.of("cobblestone","stone","raw_iron","ender_pearl","egg","oak_log","stick","bucket","lava_bucket","coal","iron_ingot","snowball","dirt");
  static final List<String> INPUTS=List.of("raw_iron","raw_iron","cobblestone","oak_log","sand","egg","stone","porkchop");
  static final List<String> FUELS=List.of("coal","coal","lava_bucket","oak_log","stick","stone","bucket","water_bucket","oak_planks");

  /** A stack of `name`, of any size it can have. */
  static ItemStack stack(Random random,String name){
    var item=item(name);int max=new ItemStack(item).getMaxStackSize();
    int count=random.nextInt(4)==0?max:1+random.nextInt(max);
    return new ItemStack(item,count);
  }

  /** A scene's blocks, in the order their block entities are created, and its items. */
  static final class Scene{
    LinkedHashMap<BlockPos,BlockState> blocks=new LinkedHashMap<>();
    Map<BlockPos,List<ItemStack>> contents=new HashMap<>();
    List<BlockPos> furnaces=new ArrayList<>();
    List<Object[]> items=new ArrayList<>();
    TreeMap<Integer,List<Object[]>> actions=new TreeMap<>();
    List<BlockPos> hoppers=new ArrayList<>();
    void put(BlockPos pos,BlockState state){blocks.put(pos,state);}
    boolean free(BlockPos pos){return !blocks.containsKey(pos);}
    void fill(BlockPos pos,Random random,List<String> names,int slots,int odds){
      var list=new ArrayList<ItemStack>();
      for(int i=0;i<slots;i++)list.add(random.nextInt(odds)==0?stack(random,RedstoneOracle.any(random,names)):ItemStack.EMPTY);
      contents.put(pos,list);
    }
  }

  static BlockState hopper(Direction facing){return Blocks.HOPPER.defaultBlockState().setValue(HopperBlock.FACING,facing);}

  /** A chest over a path of hoppers ending in a container (or nothing), a second chest over one of them. */
  static void chain(Random random,Scene scene){
    var top=new BlockPos(0,20,0);scene.put(top,Blocks.CHEST.defaultBlockState());scene.fill(top,random,MISC,27,3);
    var pos=top.below();int length=2+random.nextInt(5);Direction facing=Direction.DOWN;
    for(int i=0;i<length;i++){
      var options=new ArrayList<Direction>();
      for(var d:HOPPER_FACINGS)if(scene.free(pos.relative(d))&&scene.free(pos.relative(d).above())&&pos.relative(d).getY()>8)options.add(d);
      facing=options.isEmpty()?Direction.DOWN:RedstoneOracle.any(random,options);
      scene.put(pos,hopper(facing));scene.hoppers.add(pos);
      if(random.nextInt(3)==0)scene.fill(pos,random,MISC,5,2);
      if(i==length-1)break;
      pos=pos.relative(facing);
    }
    var end=pos.relative(facing);
    switch(random.nextInt(5)){
      case 0->{scene.put(end,Blocks.CHEST.defaultBlockState());if(random.nextBoolean())scene.fill(end,random,MISC,27,2);}
      case 1->{scene.put(end,hopper(Direction.DOWN));scene.hoppers.add(end);}
      case 2->{scene.put(end,Blocks.DROPPER.defaultBlockState().setValue(DispenserBlock.FACING,Direction.UP));if(random.nextBoolean())scene.fill(end,random,MISC,9,2);}
      case 3->{scene.put(end,Blocks.FURNACE.defaultBlockState());scene.furnaces.add(end);}
      default->{}
    }
    // Half the paths' hoppers are created last first: a hopper then gives to one that ticks before it.
    if(random.nextBoolean()){
      var reordered=new LinkedHashMap<BlockPos,BlockState>();
      for(var e:scene.blocks.entrySet())if(!scene.hoppers.contains(e.getKey()))reordered.put(e.getKey(),e.getValue());
      for(int i=scene.hoppers.size()-1;i>=0;i--)reordered.put(scene.hoppers.get(i),scene.blocks.get(scene.hoppers.get(i)));
      scene.blocks=reordered;
    }
    // A second chest over a hopper of the path.
    var over=RedstoneOracle.any(random,scene.hoppers).above();
    if(scene.free(over)){scene.put(over,Blocks.CHEST.defaultBlockState());scene.fill(over,random,MISC,27,4);}
  }

  /** A furnace fed from above and a side, emptied from below. */
  static void furnace(Random random,Scene scene){
    var furnace=new BlockPos(0,15,0);
    if(random.nextInt(5)>0){
      scene.put(furnace.above(),hopper(Direction.DOWN));scene.hoppers.add(furnace.above());
      scene.put(furnace.above(2),Blocks.CHEST.defaultBlockState());scene.fill(furnace.above(2),random,INPUTS,27,3);
    }
    if(random.nextInt(5)>0){
      var side=RedstoneOracle.any(random,SIDES);var at=furnace.relative(side);
      scene.put(at,hopper(side.getOpposite()));scene.hoppers.add(at);
      scene.put(at.above(),Blocks.CHEST.defaultBlockState());scene.fill(at.above(),random,FUELS,27,3);
    }
    if(random.nextInt(4)>0){
      var below=furnace.below();var side=RedstoneOracle.any(random,SIDES);
      scene.put(below,hopper(random.nextInt(4)==0?Direction.DOWN:side));scene.hoppers.add(below);
      var chest=below.relative(scene.blocks.get(below).getValue(HopperBlock.FACING));
      scene.put(chest,Blocks.CHEST.defaultBlockState());
    }
    scene.put(furnace,Blocks.FURNACE.defaultBlockState());scene.furnaces.add(furnace);
    if(random.nextInt(3)==0){
      var list=new ArrayList<ItemStack>();
      list.add(random.nextBoolean()?stack(random,RedstoneOracle.any(random,INPUTS)):ItemStack.EMPTY);
      list.add(random.nextBoolean()?stack(random,RedstoneOracle.any(random,FUELS)):ItemStack.EMPTY);
      list.add(random.nextBoolean()?new ItemStack(item("iron_ingot"),1+random.nextInt(64)):ItemStack.EMPTY);
      scene.contents.put(furnace,list);
    }
  }

  /** Hoppers under item entities, some covered. */
  static void pickup(Random random,Scene scene){
    int count=1+random.nextInt(4);
    for(int i=0;i<count;i++){
      var pos=new BlockPos(i,15,0);
      var facing=i<count-1&&random.nextInt(3)==0?Direction.EAST:Direction.DOWN;
      scene.put(pos,hopper(facing));scene.hoppers.add(pos);
      if(facing==Direction.DOWN){scene.put(pos.below(),Blocks.CHEST.defaultBlockState());}
      if(random.nextInt(3)==0){
        // Nearly full: an item fits only partly.
        var list=new ArrayList<ItemStack>();var name=RedstoneOracle.any(random,MISC);var s=new ItemStack(item(name));
        for(int k=0;k<5;k++)list.add(random.nextInt(4)==0?ItemStack.EMPTY:new ItemStack(item(name),Math.max(1,s.getMaxStackSize()-random.nextInt(3))));
        scene.contents.put(pos,list);
      }
      switch(random.nextInt(8)){
        case 0->scene.put(pos.above(),Blocks.STONE.defaultBlockState());
        case 1->scene.put(pos.above(),Blocks.GLASS.defaultBlockState());
        case 2->scene.put(pos.above(),Blocks.STONE_SLAB.defaultBlockState());
        case 3->{scene.put(pos.above(),Blocks.CHEST.defaultBlockState());scene.fill(pos.above(),random,MISC,27,6);}
        default->{}
      }
    }
    int items=2+random.nextInt(9);
    for(int i=0;i<items;i++){
      int at=random.nextInt(count);
      double x=at-0.25+random.nextInt(24)/16.0,y=15.375+random.nextInt(30)/16.0,z=-0.25+random.nextInt(24)/16.0;
      scene.items.add(new Object[]{x,y,z,stack(random,RedstoneOracle.any(random,MISC))});
    }
  }

  /** Redstone blocks beside hoppers, placed and removed. */
  static void power(Random random,Scene scene){
    if(scene.hoppers.isEmpty()||random.nextInt(3)==0)return;
    for(int n=0;n<1+random.nextInt(3);n++){
      var hopper=RedstoneOracle.any(random,scene.hoppers);var at=hopper.relative(RedstoneOracle.any(random,List.of(Direction.values())));
      if(!scene.free(at)||scene.items.stream().anyMatch(i->BlockPos.containing((double)i[0],(double)i[1],(double)i[2]).equals(at)))continue;
      for(int t=random.nextInt(40);t<TICKS-20;t+=10+random.nextInt(40)){
        int off=t+1+random.nextInt(30);
        scene.actions.computeIfAbsent(t,k->new ArrayList<>()).add(new Object[]{at,Blocks.REDSTONE_BLOCK.defaultBlockState()});
        scene.actions.computeIfAbsent(off,k->new ArrayList<>()).add(new Object[]{at,Blocks.AIR.defaultBlockState()});
        t=off;
      }
    }
  }

  static JsonElement encode(ItemStack stack){
    if(stack.isEmpty())return JsonNull.INSTANCE;
    var row=new JsonArray();row.add(BuiltInRegistries.ITEM.getKey(stack.getItem()).getPath());row.add(stack.getCount());return row;
  }

  /** A container as the check reads it: position, slots, a hopper's cooldown, a furnace's timers. */
  static JsonArray container(BlockPos pos,BlockEntity entity)throws Exception{
    var row=RedstoneOracle.row(pos);var slots=new JsonArray();
    var container=(net.minecraft.world.Container)entity;
    for(int i=0;i<container.getContainerSize();i++)slots.add(encode(container.getItem(i)));
    row.add(slots);
    if(entity instanceof HopperBlockEntity)row.add(field(HopperBlockEntity.class,"cooldownTime").getInt(entity));
    else if(entity instanceof AbstractFurnaceBlockEntity)
      for(var name:List.of("litTimeRemaining","litTotalTime","cookingTimer","cookingTotalTime"))row.add(field(AbstractFurnaceBlockEntity.class,name).getInt(entity));
    return row;
  }

  /** A probe level with every tag bound, the recipes and the reloadable registries. */
  static Probe level()throws Exception{
    var initial=MiningToolOracle.initialize();var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var pending=TagLoader.loadTagsForExistingRegistries(resources,access);var statics=TagLoader.buildUpdatedLookups(access,pending);
      var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=net.minecraft.resources.RegistryDataLoader.load(resources,base.listRegistries().toList(),net.minecraft.resources.RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
      for(var tags:pending)tags.apply();
      var probe=probe(access.freeze(),new RecipeManager(lookup),new ReloadableServerRegistries.Holder(lookup));
      probe.cells=new HashMap<>();probe.entities=new HashMap<>();probe.random=RandomSource.create(0);
      return probe;
    }
  }

  public static void main(String[] args)throws Exception{
    if(!args[0].equals("scenes"))throw new IllegalArgumentException(args[0]);
    int count=args.length>2?Integer.parseInt(args[2]):120;long seed=args.length>3?Long.parseLong(args[3]):49_001L;
    scenes(level(),args[1],count,seed);
  }

  static void scenes(Probe probe,String out,int count,long seed)throws Exception{
    var random=new Random(seed);var scenes=new JsonArray();int moves=0,pickups=0,cooked=0;
    for(int s=0;s<count;s++){
      var scene=new Scene();
      switch(s%3){case 0->chain(random,scene);case 1->furnace(random,scene);default->pickup(random,scene);}
      power(random,scene);
      probe.random=RandomSource.create(random.nextLong());probe.time=0;
      probe.cells=new HashMap<>();probe.entities=new HashMap<>();probe.tickers=new ArrayList<>();probe.tickerAt=new HashMap<>();
      probe.things=new ArrayList<>();probe.writes=new JsonArray();
      var json=new JsonObject();var blocks=new JsonArray();var containers=new JsonArray();var items=new JsonArray();
      for(var e:scene.blocks.entrySet()){probe.cells.put(e.getKey(),e.getValue());blocks.add(RedstoneOracle.row(e.getKey(),Block.getId(e.getValue())));}
      // Block entities in creation order: the containers, then the furnaces.
      var order=new ArrayList<BlockPos>();
      for(var pos:scene.blocks.keySet())if(scene.blocks.get(pos).hasBlockEntity()&&!scene.furnaces.contains(pos))order.add(pos);
      order.addAll(scene.furnaces);
      for(var pos:order){
        var state=scene.blocks.get(pos);var entity=((EntityBlock)state.getBlock()).newBlockEntity(pos,state);probe.setBlockEntity(entity);
        var list=scene.contents.get(pos);
        if(list!=null)for(int i=0;i<list.size();i++)((net.minecraft.world.Container)entity).setItem(i,list.get(i).copy());
        containers.add(container(pos,entity));
      }
      for(var i:scene.items){
        var e=new ItemEntity(probe,(double)i[0],(double)i[1],(double)i[2],((ItemStack)i[3]).copy());probe.things.add(e);
        var row=new JsonArray();row.add((double)i[0]);row.add((double)i[1]);row.add((double)i[2]);row.add(encode(e.getItem()));items.add(row);
      }
      var last=new HashMap<BlockPos,JsonArray>();for(int i=0;i<order.size();i++)last.put(order.get(i),containers.get(i).getAsJsonArray());
      var counts=new int[probe.things.size()];for(int i=0;i<counts.length;i++)counts[i]=((ItemEntity)probe.things.get(i)).getItem().getCount();
      var steps=new JsonArray();
      for(int t=0;t<TICKS;t++){
        probe.time=t;probe.writes=new JsonArray();
        var actions=new JsonArray();
        for(var a:scene.actions.getOrDefault(t,List.of())){
          var pos=(BlockPos)a[0];var state=(BlockState)a[1];actions.add(RedstoneOracle.row(pos,Block.getId(state)));
          probe.setBlock(pos,state,3);
        }
        probe.entitiesInside();
        probe.tickBlockEntities();
        var changed=new JsonArray();
        for(var pos:order){
          var entity=probe.getBlockEntity(pos);if(entity==null)continue;
          var row=container(pos,entity);
          if(!row.equals(last.get(pos))){changed.add(row);last.put(pos,row);moves++;}
        }
        var itemCounts=new JsonArray();
        for(int i=0;i<counts.length;i++){
          var e=(ItemEntity)probe.things.get(i);int n=e.isRemoved()?0:e.getItem().getCount();
          if(n!=counts[i]){var row=new JsonArray();row.add(i);row.add(n);itemCounts.add(row);counts[i]=n;pickups++;}
        }
        if(actions.size()+probe.writes.size()+changed.size()+itemCounts.size()>0){
          var step=new JsonObject();step.addProperty("t",t);step.add("actions",actions);step.add("writes",probe.writes);
          step.add("containers",changed);step.add("items",itemCounts);steps.add(step);
        }
      }
      for(var pos:scene.furnaces)if(probe.getBlockEntity(pos) instanceof AbstractFurnaceBlockEntity f&&!f.getItem(2).isEmpty())cooked++;
      var order_=new JsonArray();for(var pos:order)order_.add(RedstoneOracle.row(pos));
      json.add("blocks",blocks);json.add("order",order_);json.add("containers",containers);json.add("items",items);json.add("steps",steps);
      scenes.add(json);
    }
    Files.writeString(Path.of(out),new GsonBuilder().disableHtmlEscaping().create().toJson(scenes)+"\n");
    System.out.println("PASS: "+count+" hopper scenes, "+moves+" container changes, "+pickups+" item entity changes, "+cooked+" furnaces with output");
  }
}
