import com.google.gson.*;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.ReloadableServerRegistries;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.piston.PistonBaseBlock;
import net.minecraft.world.level.block.piston.PistonMovingBlockEntity;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.*;
import net.minecraft.world.level.entity.EntityTypeTest;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.redstone.CollectingNeighborUpdater;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.ticks.LevelChunkTicks;
import net.minecraft.world.ticks.LevelTicks;
import net.minecraft.world.ticks.ScheduledTick;
import net.minecraft.world.ticks.TickPriority;

/**
 * Pistons and moving blocks (VMC-048b), from pinned 26.3: `scenes OUT [SCENES [SEED]]` runs
 * contraptions over a probe level whose block ticks are vanilla's own `LevelTicks`, whose block
 * events queue and run as `ServerLevel.runBlockEvents` runs them and whose block entities (moving
 * pistons, chests, furnaces) live and tick as `LevelChunk` and `Level.tickBlockEntities` keep them,
 * over a stone floor straddling the x 128 section line and the z 0 chunk line. Each game tick runs
 * a player's actions first (block sets as `/setblock` makes them, a piston's `setPlacedBy`, uses of
 * levers and buttons), then the due block ticks and the block events (`isHandlingTick`), then the
 * block entities. Scenes set pistons and sticky pistons in every direction among stone, glass,
 * slime and honey, immovable, push-only and popped blocks, block entities, power sources,
 * observers and repeaters; scripted ones push lines at and past the push limit, pull with sticky
 * pistons on short pulses (the dropped block), move slime structures and toggle power twice in a
 * tick. Per tick: the cell writes, sounds, the block events raised and those that ran, and every
 * moving piston's block entity. Loot is empty (the level random draws nothing for drops).
 *
 * `pushes OUT [SCENES [SEED]]`: what moving blocks do to entities. Each scene sets a piston or
 * sticky piston in any direction behind a line of stone, slime or honey and places items and
 * armor stands (a living body with a step height) around and on the line, at rest or moving, on
 * the ground or not; then powers the piston, later unpowers it. Entities do not tick on their own:
 * per block entity phase it records every entity before and after (feet, velocity as double bits,
 * on ground), the moving pistons in the order they tick (before), and the cells and moving
 * pistons after, which is the world ValiMC's kernel pushes in.
 *
 * Before each phase every entity finds the block it stands on again, as its own tick's move would.
 *
 * Usage: PistonOracle (scenes|pushes) OUT [SCENES [SEED]]
 */
public class PistonOracle {
  static final int FLOOR_Y=63,MIN_X=124,MAX_X=133,MIN_Z=-4,MAX_Z=4,TICKS=160,ACTIVE=120;

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
    net.minecraft.util.debug.ServerDebugSubscribers subscribers;
    public net.minecraft.util.debug.ServerDebugSubscribers debugSubscribers(){return subscribers;}
  }

  /** A ticking block entity as `RebindableTickingBlockEntityWrapper` holds it. */
  static final class Ticker{BlockEntity entity;Ticker(BlockEntity entity){this.entity=entity;}}

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Map<BlockPos,BlockEntity> entities;Server server;RandomSource random;GameRules rules;
    LevelTicks<Block> blockTicks;LevelTicks<Fluid> fluidTicks;long time,subTick;boolean handling;
    List<Ticker> tickers=new ArrayList<>();Map<BlockPos,Ticker> tickerAt=new HashMap<>();
    /** `ServerLevel.blockEvents`: each event once, in order. */
    LinkedHashSet<List<Integer>> queue=new LinkedHashSet<>();
    JsonArray writes=new JsonArray(),sounds=new JsonArray(),raised=new JsonArray(),executed=new JsonArray(),events=new JsonArray();
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
    @Override public GameRules getGameRules(){return rules;}
    @Override public long getGameTime(){return time;}
    @Override public boolean isHandlingTick(){return handling;}
    net.minecraft.world.level.border.WorldBorder border;RegistryAccess access;
    @Override public RegistryAccess registryAccess(){return access;}
    @Override public net.minecraft.world.level.border.WorldBorder getWorldBorder(){return border;}
    @Override public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    @Override public LevelTicks<Block> getBlockTicks(){return blockTicks;}
    @Override public LevelTicks<Fluid> getFluidTicks(){return fluidTicks;}
    @Override public boolean isClientSide(){return false;}
    @Override public boolean isLoaded(BlockPos pos){return !isOutsideBuildHeight(pos);}
    @Override public boolean hasChunkAt(BlockPos pos){return true;}
    @Override public void levelEvent(Entity source,int type,BlockPos pos,int data){events.add(RedstoneOracle.row(pos,type,data));}
    @Override public void blockEvent(BlockPos pos,Block block,int b0,int b1){
      var event=List.of(pos.getX(),pos.getY(),pos.getZ(),BuiltInRegistries.BLOCK.getId(block),b0,b1);
      raised.add(RedstoneOracle.row(pos,BuiltInRegistries.BLOCK.getId(block),b0,b1));queue.add(event);
    }
    @Override public void gameEvent(Holder<GameEvent> event,Vec3 at,GameEvent.Context context){}
    @Override public void gameEvent(Entity source,Holder<GameEvent> event,BlockPos pos){}
    @Override public void playSeededSound(Entity except,double x,double y,double z,Holder<SoundEvent> sound,SoundSource source,float volume,float pitch,long seed){
      var row=new JsonArray();row.add(x);row.add(y);row.add(z);row.add(sound.value().location().toString());
      row.add(Float.floatToIntBits(volume));row.add(Float.floatToIntBits(pitch));row.add(except!=null);sounds.add(row);
    }
    @Override public boolean addFreshEntity(Entity entity){throw new AssertionError("an entity in a piston scene: "+entity);}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay,TickPriority priority){
      blockTicks.schedule(new ScheduledTick<>(block,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Block block,int delay){scheduleTick(pos,block,delay,TickPriority.NORMAL);}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay,TickPriority priority){
      fluidTicks.schedule(new ScheduledTick<>(fluid,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay){scheduleTick(pos,fluid,delay,TickPriority.NORMAL);}
    /** The entities of a pushes scene, in the order the level lists them. */
    List<Entity> things=new ArrayList<>();
    @Override public List<Entity> getEntities(Entity except,AABB bb,Predicate<? super Entity> selector){
      var out=new ArrayList<Entity>();
      for(var e:things)if(e!=except&&e.getBoundingBox().intersects(bb)&&(selector==null||selector.test(e)))out.add(e);
      return out;
    }
    @Override public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> type,AABB bb,Predicate<? super T> selector){
      var out=new ArrayList<T>();
      for(var e:things){T t=type.tryCast(e);if(t!=null&&t.getBoundingBox().intersects(bb)&&selector.test(t))out.add(t);}
      return out;
    }
    @Override public BlockGetter getChunkForCollisions(int x,int z){return this;}
    int ids;
    @Override public int getNextEntityId(){return ++ids;}
    net.minecraft.world.level.chunk.ChunkAccess chunk;
    // Every section reports fluid: an entity's fluid lookups then read the scene (as MobTravelOracle's).
    @Override public net.minecraft.world.level.chunk.ChunkAccess getChunk(int x,int z,net.minecraft.world.level.chunk.status.ChunkStatus s,boolean load){
      if(chunk==null){
        try{
          var unsafe=MobTravelOracle.unsafe;
          chunk=(net.minecraft.world.level.chunk.ChunkAccess)unsafe.allocateInstance(net.minecraft.world.level.chunk.ProtoChunk.class);
          var sections=new net.minecraft.world.level.chunk.LevelChunkSection[24];
          for(int i=0;i<24;i++){
            sections[i]=(net.minecraft.world.level.chunk.LevelChunkSection)unsafe.allocateInstance(net.minecraft.world.level.chunk.LevelChunkSection.class);
            MobTravelOracle.field(net.minecraft.world.level.chunk.LevelChunkSection.class,"fluidCount").setShort(sections[i],(short)1);
            MobTravelOracle.field(net.minecraft.world.level.chunk.LevelChunkSection.class,"tickingFluidCount").setShort(sections[i],(short)1);
          }
          MobTravelOracle.setFinal(net.minecraft.world.level.chunk.ChunkAccess.class,"sections",chunk,sections);
          MobTravelOracle.setFinal(net.minecraft.world.level.chunk.ChunkAccess.class,"levelHeightAccessor",chunk,this);
        }catch(Exception e){throw new RuntimeException(e);}
      }
      return chunk;
    }
    @Override public boolean hasChunk(int x,int z){return true;}
    @Override public boolean isRainingAt(BlockPos pos){return false;}
    @Override public boolean isRaining(){return false;}
    net.minecraft.world.damagesource.DamageSources sources;
    @Override public net.minecraft.world.damagesource.DamageSources damageSources(){return sources;}

    /** `LevelChunk.setBlockEntity` with `addAndRegisterBlockEntity`'s ticker. */
    @Override public void setBlockEntity(BlockEntity entity){
      var pos=entity.getBlockPos().immutable();var state=cell(pos);
      if(!state.hasBlockEntity())return;
      if(state!=entity.getBlockState()){if(!entity.getType().isValid(state))return;entity.setBlockState(state);}
      entity.setLevel(this);entity.clearRemoved();
      var previous=entities.put(pos,entity);if(previous!=null&&previous!=entity)previous.setRemoved();
      ticker(entity);
    }
    /** `updateBlockEntityTicker`: a ticker at the position is rebound, else a new one is appended. */
    void ticker(BlockEntity entity){
      var pos=entity.getBlockPos().immutable();
      if(entity.getBlockState().getTicker(this,(net.minecraft.world.level.block.entity.BlockEntityType<BlockEntity>)entity.getType())==null){
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

    /** `ServerLevel.runBlockEvents` with `doBlockEvent`. */
    void runBlockEvents(){
      while(!queue.isEmpty()){
        var it=queue.iterator();var e=it.next();it.remove();
        var pos=new BlockPos(e.get(0),e.get(1),e.get(2));var block=BuiltInRegistries.BLOCK.byId(e.get(3));
        var state=cell(pos);
        if(state.is(block)&&state.triggerEvent(this,pos,e.get(4),e.get(5)))executed.add(RedstoneOracle.row(pos,e.get(3),e.get(4),e.get(5)));
      }
    }

    /** `Level.tickBlockEntities` with `BoundTickingBlockEntity.tick`. */
    @SuppressWarnings("unchecked")
    public void tickBlockEntities(){
      var it=tickers.iterator();
      while(it.hasNext()){
        var t=it.next();
        if(t.entity==null){it.remove();continue;}
        var entity=t.entity;if(entity.isRemoved())continue;
        var pos=entity.getBlockPos();var state=cell(pos);
        if(!entity.getType().isValid(state))continue;
        var ticker=state.getTicker(this,(net.minecraft.world.level.block.entity.BlockEntityType<BlockEntity>)entity.getType());
        if(ticker!=null)ticker.tick(this,pos,state,entity);
      }
    }
  }

  /** An armor stand that a landing does not hurt (ValiMC's pushes leave fall damage to the body's own tick). */
  static class Stand extends net.minecraft.world.entity.decoration.ArmorStand {
    Stand(Level level,double x,double y,double z){super(level,x,y,z);}
    @Override public boolean causeFallDamage(double distance,float multiplier,net.minecraft.world.damagesource.DamageSource source){return false;}
  }

  /** A player for uses: its facing, and whether it may build. */
  static class User extends Player {
    private User(){super(null,null);}
    @Override public net.minecraft.world.level.GameType gameMode(){return net.minecraft.world.level.GameType.SURVIVAL;}
  }

  static Probe probe()throws Exception{
    var theUnsafe=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");theUnsafe.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)theUnsafe.get(null);
    if(MobTravelOracle.unsafe==null)MobTravelOracle.unsafe=unsafe;
    var sources=(net.minecraft.world.damagesource.DamageSources)unsafe.allocateInstance(net.minecraft.world.damagesource.DamageSources.class);
    var server=(Server)unsafe.allocateInstance(Server.class);
    // No loot tables: popped blocks drop nothing, so the level random draws nothing for them.
    server.subscribers=new net.minecraft.util.debug.ServerDebugSubscribers(server);
    server.registries=new ReloadableServerRegistries.Holder(RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze());
    var probe=(Probe)unsafe.allocateInstance(Probe.class);probe.server=server;
    var updater=Level.class.getDeclaredField("neighborUpdater");updater.setAccessible(true);
    updater.set(probe,new CollectingNeighborUpdater(probe,1_000_000));
    var players=ServerLevel.class.getDeclaredField("players");players.setAccessible(true);players.set(probe,new ArrayList<>());
    var seeds=Level.class.getDeclaredField("soundSeedGenerator");seeds.setAccessible(true);seeds.set(probe,RandomSource.create(0));
    probe.border=new net.minecraft.world.level.border.WorldBorder();
    probe.access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    probe.tickers=new ArrayList<>();probe.tickerAt=new HashMap<>();probe.queue=new LinkedHashSet<>();probe.sources=sources;probe.things=new ArrayList<>();
    return probe;
  }

  static Block named(String name){return BuiltInRegistries.BLOCK.getValue(net.minecraft.resources.Identifier.parse("minecraft:"+name));}

  static final List<Direction> HORIZONTAL=List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST);

  static BlockState piston(Random random){
    return (random.nextInt(3)==0?Blocks.PISTON:Blocks.STICKY_PISTON).defaultBlockState()
      .setValue(PistonBaseBlock.FACING,RedstoneOracle.any(random,List.of(Direction.values())));
  }

  /** A state a scene sets: the blocks pistons move, keep or break, power and its components. */
  static BlockState pick(Random random){
    int roll=random.nextInt(100);
    if(roll<12)return Blocks.AIR.defaultBlockState();
    if(roll<22)return Blocks.STONE.defaultBlockState();
    if(roll<26)return Blocks.GLASS.defaultBlockState();
    if(roll<36)return Blocks.SLIME_BLOCK.defaultBlockState();
    if(roll<42)return Blocks.HONEY_BLOCK.defaultBlockState();
    if(roll<45)return Blocks.OBSIDIAN.defaultBlockState();
    if(roll<47)return named("white_glazed_terracotta").defaultBlockState().setValue(GlazedTerracottaBlock.FACING,RedstoneOracle.any(random,HORIZONTAL));
    if(roll<49)return Blocks.CHEST.defaultBlockState().setValue(ChestBlock.FACING,RedstoneOracle.any(random,HORIZONTAL));
    if(roll<50)return Blocks.FURNACE.defaultBlockState();
    if(roll<55)return Blocks.REDSTONE_BLOCK.defaultBlockState();
    if(roll<58)return Blocks.REDSTONE_TORCH.defaultBlockState();
    if(roll<60)return Blocks.TORCH.defaultBlockState();
    if(roll<62)return Blocks.COBWEB.defaultBlockState();
    if(roll<65)return Blocks.OBSERVER.defaultBlockState().setValue(ObserverBlock.FACING,RedstoneOracle.any(random,List.of(Direction.values())));
    if(roll<67)return Blocks.REPEATER.defaultBlockState().setValue(RepeaterBlock.FACING,RedstoneOracle.any(random,HORIZONTAL))
      .setValue(RepeaterBlock.DELAY,1+random.nextInt(4));
    if(roll<69)return Blocks.REDSTONE_LAMP.defaultBlockState();
    if(roll<71)return Blocks.NOTE_BLOCK.defaultBlockState();
    if(roll<73)return Blocks.TARGET.defaultBlockState();
    if(roll<75)return named("white_wool").defaultBlockState();
    if(roll<77)return Blocks.LEVER.defaultBlockState().setValue(LeverBlock.FACE,AttachFace.FLOOR).setValue(LeverBlock.FACING,RedstoneOracle.any(random,HORIZONTAL));
    if(roll<79)return Blocks.STONE_BUTTON.defaultBlockState().setValue(ButtonBlock.FACE,AttachFace.FLOOR).setValue(ButtonBlock.FACING,RedstoneOracle.any(random,HORIZONTAL));
    if(roll<81)return Blocks.BEDROCK.defaultBlockState();
    if(roll<83)return Blocks.OAK_TRAPDOOR.defaultBlockState().setValue(TrapDoorBlock.FACING,RedstoneOracle.any(random,HORIZONTAL));
    return piston(random);
  }

  static BlockPos anyPos(Random random){
    return new BlockPos(MIN_X+random.nextInt(MAX_X-MIN_X),FLOOR_Y+1+random.nextInt(4),MIN_Z+random.nextInt(MAX_Z-MIN_Z));
  }

  static void at(TreeMap<Integer,List<JsonArray>> scripted,int t,JsonArray action){scripted.computeIfAbsent(t,k->new ArrayList<>()).add(action);}

  /** A piston pushing a line of `length` blocks east, powered by a lever behind it, toggled. */
  static void line(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int t0=random.nextInt(10),length=10+random.nextInt(4),z=MIN_Z+random.nextInt(MAX_Z-MIN_Z);
    var base=new BlockPos(MIN_X-1,FLOOR_Y+1,z);
    boolean sticky=random.nextBoolean();
    at(scripted,t0,RedstoneOracle.action("set",base,Block.getId((sticky?Blocks.STICKY_PISTON:Blocks.PISTON).defaultBlockState().setValue(PistonBaseBlock.FACING,Direction.EAST))));
    for(int i=1;i<=length;i++){
      var block=random.nextInt(4)==0?Blocks.SLIME_BLOCK:random.nextInt(5)==0?Blocks.TORCH:Blocks.STONE;
      at(scripted,t0,RedstoneOracle.action("set",base.east(i),Block.getId(block.defaultBlockState())));
    }
    at(scripted,t0,RedstoneOracle.action("set",base.west(),Block.getId(Blocks.STONE.defaultBlockState())));
    at(scripted,t0,RedstoneOracle.action("set",base.west().above(),Block.getId(Blocks.LEVER.defaultBlockState().setValue(LeverBlock.FACE,AttachFace.FLOOR))));
    for(int t=t0+2;t<ACTIVE;t+=3+random.nextInt(8))at(scripted,t,RedstoneOracle.action("use",base.west().above(),4,1));
  }

  /** A sticky piston pulling a block (sometimes a slime structure) on pulses of 1 to 3 ticks, some in one tick. */
  static void pulses(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int t0=random.nextInt(10),z=MIN_Z+1+random.nextInt(MAX_Z-MIN_Z-2),x=MIN_X+1+random.nextInt(4);
    var base=new BlockPos(x,FLOOR_Y+1,z);var facing=RedstoneOracle.any(random,List.of(Direction.EAST,Direction.UP));
    at(scripted,t0,RedstoneOracle.action("set",base,Block.getId(Blocks.STICKY_PISTON.defaultBlockState().setValue(PistonBaseBlock.FACING,facing))));
    var front=base.relative(facing);
    var moved=random.nextBoolean()?Blocks.SLIME_BLOCK:random.nextBoolean()?Blocks.HONEY_BLOCK:Blocks.STONE;
    at(scripted,t0,RedstoneOracle.action("set",front,Block.getId(moved.defaultBlockState())));
    if(moved!=Blocks.STONE)for(var d:HORIZONTAL)if(d!=facing.getOpposite()&&random.nextBoolean())
      at(scripted,t0,RedstoneOracle.action("set",front.relative(d),Block.getId((random.nextBoolean()?Blocks.STONE:Blocks.OBSIDIAN).defaultBlockState())));
    var power=base.relative(facing==Direction.UP?Direction.WEST:Direction.NORTH);
    for(int t=t0+2;t<ACTIVE;t+=4+random.nextInt(8)){
      at(scripted,t,RedstoneOracle.action("set",power,Block.getId(Blocks.REDSTONE_BLOCK.defaultBlockState())));
      int length=random.nextInt(4);
      at(scripted,t+length,RedstoneOracle.action("set",power,Block.getId(Blocks.AIR.defaultBlockState())));
    }
  }

  /** A piston door: two sticky pistons, each facing the other's way below, opened by a button. */
  static void door(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int t0=random.nextInt(10),z=MIN_Z+2+random.nextInt(3);var west=new BlockPos(MIN_X+2,FLOOR_Y+1,z);
    for(int dy=0;dy<2;dy++){
      at(scripted,t0,RedstoneOracle.action("set",west.above(dy),Block.getId(Blocks.STICKY_PISTON.defaultBlockState().setValue(PistonBaseBlock.FACING,Direction.EAST))));
      at(scripted,t0,RedstoneOracle.action("set",west.above(dy).east(),Block.getId(Blocks.STONE.defaultBlockState())));
    }
    var lever=west.west();
    at(scripted,t0,RedstoneOracle.action("set",lever,Block.getId(Blocks.REDSTONE_WIRE.defaultBlockState())));
    for(int t=t0+3;t<ACTIVE;t+=6+random.nextInt(10)){
      at(scripted,t,RedstoneOracle.action("set",lever.west(),Block.getId(Blocks.REDSTONE_BLOCK.defaultBlockState())));
      at(scripted,t+3+random.nextInt(4),RedstoneOracle.action("set",lever.west(),Block.getId(Blocks.AIR.defaultBlockState())));
    }
  }

  static List<BlockPos> cellsWhere(Probe probe,Predicate<BlockState> filter){
    var out=new ArrayList<BlockPos>();
    for(var e:probe.cells.entrySet())if(filter.test(e.getValue()))out.add(e.getKey());
    out.sort(Comparator.naturalOrder());return out;
  }

  static JsonArray movingRows(Probe probe){
    var out=new JsonArray();var positions=new ArrayList<>(probe.entities.keySet());positions.sort(Comparator.naturalOrder());
    for(var pos:positions)if(probe.entities.get(pos) instanceof PistonMovingBlockEntity m){
      var row=RedstoneOracle.row(pos,Block.getId(m.getMovedState()),m.getDirection().get3DDataValue(),m.isExtending()?1:0,m.isSourcePiston()?1:0);
      row.add(Float.floatToIntBits(m.getProgress(1.0F)));row.add(Float.floatToIntBits(m.getProgress(0.0F)));row.add(m.getLastTicked());
      out.add(row);
    }
    return out;
  }

  public static void main(String[] args)throws Exception{
    int count=args.length>2?Integer.parseInt(args[2]):120;long seed=args.length>3?Long.parseLong(args[3]):48_201L;
    switch(args[0]){
      case "scenes"->scenes(args[1],count,seed);
      case "pushes"->pushes(args[1],count,seed);
      default->throw new IllegalArgumentException(args[0]);
    }
  }

  static String bits(double d){return HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d));}

  /** An entity as the check reads it: kind (0 item, 1 armor stand), feet and velocity bits, on ground. */
  static JsonArray thing(Entity e){
    var row=new JsonArray();row.add(e instanceof net.minecraft.world.entity.item.ItemEntity?0:1);
    for(double v:new double[]{e.getX(),e.getY(),e.getZ()})row.add(bits(v));
    var d=e.getDeltaMovement();for(double v:new double[]{d.x,d.y,d.z})row.add(bits(v));
    row.add(e.onGround());return row;
  }

  /** The moving pistons in the order they tick. */
  static JsonArray ticking(Probe probe){
    var out=new JsonArray();
    for(var t:probe.tickers)if(t.entity instanceof PistonMovingBlockEntity m&&!m.isRemoved()){
      var pos=m.getBlockPos();
      var row=RedstoneOracle.row(pos,Block.getId(m.getMovedState()),m.getDirection().get3DDataValue(),m.isExtending()?1:0,m.isSourcePiston()?1:0);
      row.add(Float.floatToIntBits(m.getProgress(1.0F)));out.add(row);
    }
    return out;
  }

  static void pushes(String out,int sceneCount,long seed)throws Exception{
    MiningToolOracle.initialize();var probe=probe();var random=new Random(seed);
    var stone=Blocks.STONE.defaultBlockState();var scenes=new JsonArray();int records=0,pushed=0;
    for(int s=0;s<sceneCount;s++){
      long levelSeed=random.nextLong();
      probe.random=RandomSource.create(levelSeed);var rf=Level.class.getDeclaredField("random");rf.setAccessible(true);rf.set(probe,probe.random);
      probe.time=0;probe.subTick=0;probe.handling=false;probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=-2;cx<=2;cx++)for(int cz=-2;cz<=2;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      probe.cells=new HashMap<>();probe.entities=new HashMap<>();probe.tickers=new ArrayList<>();probe.tickerAt=new HashMap<>();
      probe.queue=new LinkedHashSet<>();probe.things=new ArrayList<>();
      for(int x=-6;x<=6;x++)for(int z=-6;z<=6;z++)probe.cells.put(new BlockPos(x,FLOOR_Y,z),stone);
      var facing=RedstoneOracle.any(random,List.of(Direction.values()));boolean sticky=random.nextBoolean();
      var base=new BlockPos(0,FLOOR_Y+3,0);
      probe.cells.put(base,(sticky?Blocks.STICKY_PISTON:Blocks.PISTON).defaultBlockState().setValue(PistonBaseBlock.FACING,facing));
      int length=1+random.nextInt(3);var line=new ArrayList<BlockPos>();
      for(int i=1;i<=length;i++){
        var block=switch(random.nextInt(4)){case 0->Blocks.SLIME_BLOCK;case 1->Blocks.HONEY_BLOCK;default->Blocks.STONE;};
        var pos=base.relative(facing,i);probe.cells.put(pos,block.defaultBlockState());line.add(pos);
      }
      // Entities on the line, in front of it and beside it.
      for(int n=1+random.nextInt(4);n>0;n--){
        var at=RedstoneOracle.any(random,line);
        var cell=switch(random.nextInt(3)){case 0->at.above();case 1->at.relative(facing);default->at.relative(RedstoneOracle.any(random,List.of(Direction.values())));};
        if(!probe.cell(cell).isAir())continue;
        double x=cell.getX()+0.2+random.nextDouble()*0.6,z=cell.getZ()+0.2+random.nextDouble()*0.6;
        double y=cell.getY()+(random.nextBoolean()?0.0:random.nextDouble()*0.5);
        Entity e=random.nextBoolean()?new net.minecraft.world.entity.item.ItemEntity(probe,x,y,z,new net.minecraft.world.item.ItemStack(net.minecraft.world.item.Items.STONE))
          :new Stand(probe,x,y,z);
        e.setPos(x,y,z);
        e.setDeltaMovement(random.nextInt(3)==0?new Vec3(random.nextDouble()*0.2-0.1,random.nextDouble()*0.2-0.1,random.nextDouble()*0.2-0.1):Vec3.ZERO);
        e.setOnGroundWithMovement(y==cell.getY()&&!probe.cell(cell.below()).isAir(),Vec3.ZERO);
        probe.things.add(e);
      }
      var power=base.relative(facing==Direction.UP?Direction.DOWN:Direction.UP);
      if(power.equals(base.relative(facing)))power=base.relative(Direction.NORTH);
      var steps=new JsonArray();
      var cells=new JsonArray();for(var e:probe.cells.entrySet())cells.add(RedstoneOracle.row(e.getKey(),Block.getId(e.getValue())));
      int on=1+random.nextInt(3),off=on+3+random.nextInt(5);
      for(int t=0;t<off+6;t++){
        probe.time=t;probe.writes=new JsonArray();probe.sounds=new JsonArray();probe.raised=new JsonArray();probe.executed=new JsonArray();probe.events=new JsonArray();
        probe.handling=false;
        if(t==on)probe.setBlock(power,Blocks.REDSTONE_BLOCK.defaultBlockState(),Block.UPDATE_ALL);
        if(t==off)probe.setBlock(power,Blocks.AIR.defaultBlockState(),Block.UPDATE_ALL);
        probe.handling=true;
        probe.blockTicks.tick(t,65536,(pos,block)->{throw new AssertionError("a block tick in a pushes scene");});
        probe.runBlockEvents();probe.handling=false;
        // The block an entity stands on, as its own tick's move would find it now (`checkSupportingBlock`).
        for(var e:probe.things)e.setOnGroundWithMovement(e.onGround(),Vec3.ZERO);
        var before=new JsonArray();for(var e:probe.things)before.add(thing(e));
        var ticking=ticking(probe);
        probe.writes=new JsonArray();
        probe.tickBlockEntities();
        if(ticking.isEmpty())continue;
        var after=new JsonArray();for(var e:probe.things)after.add(thing(e));
        for(int i=0;i<after.size();i++)if(!after.get(i).equals(before.get(i)))pushed++;
        var world=new JsonArray();for(var e:probe.cells.entrySet())if(!e.getValue().isAir())world.add(RedstoneOracle.row(e.getKey(),Block.getId(e.getValue())));
        var step=new JsonObject();step.addProperty("t",t);step.add("ticking",ticking);step.add("before",before);step.add("after",after);
        step.add("cells",world);step.add("moving",movingRows(probe));steps.add(step);records++;
      }
      var scene=new JsonObject();scene.add("steps",steps);scenes.add(scene);
    }
    var result=new JsonObject();result.add("scenes",scenes);
    Files.writeString(Path.of(out),new GsonBuilder().disableHtmlEscaping().create().toJson(result)+"\n");
    System.out.println("PASS: "+sceneCount+" piston push scenes (seed "+seed+"): "+records+" block entity phases, "+pushed+" entities moved");
  }

  static void scenes(String out,int sceneCount,long seed)throws Exception{
    MiningToolOracle.initialize();var probe=probe();var random=new Random(seed);
    Method tickBlock=ServerLevel.class.getDeclaredMethod("tickBlock",BlockPos.class,Block.class);tickBlock.setAccessible(true);
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");unsafeField.setAccessible(true);
    var user=(User)((sun.misc.Unsafe)unsafeField.get(null)).allocateInstance(User.class);
    var abilitiesField=Player.class.getDeclaredField("abilities");abilitiesField.setAccessible(true);
    var abilities=new Abilities();abilities.mayBuild=true;abilitiesField.set(user,abilities);
    var stone=Blocks.STONE.defaultBlockState();var scenes=new JsonArray();var tally=new TreeMap<String,Integer>();
    for(int s=0;s<sceneCount;s++){
      long levelSeed=random.nextLong();
      probe.random=RandomSource.create(levelSeed);var rf=Level.class.getDeclaredField("random");rf.setAccessible(true);rf.set(probe,probe.random);
      probe.time=0;probe.subTick=0;probe.handling=false;
      probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-24)>>4;cx<=(MAX_X+24)>>4;cx++)for(int cz=(MIN_Z-24)>>4;cz<=(MAX_Z+24)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      probe.cells=new HashMap<>();probe.entities=new HashMap<>();probe.tickers=new ArrayList<>();probe.tickerAt=new HashMap<>();
      probe.queue=new LinkedHashSet<>();var cells=new JsonArray();
      for(int x=MIN_X-16;x<MAX_X+16;x++)for(int z=MIN_Z-4;z<MAX_Z+4;z++){
        var floor=new BlockPos(x,FLOOR_Y,z);probe.cells.put(floor,stone);cells.add(RedstoneOracle.row(floor,Block.getId(stone)));
      }
      var scripted=new TreeMap<Integer,List<JsonArray>>();
      switch(s%4){case 0->line(random,scripted);case 1->pulses(random,scripted);case 2->door(random,scripted);default->{}}
      if(s%3==0)pulses(random,scripted);
      // Random actions leave the cells scripted ones set alone.
      var reserved=new HashSet<BlockPos>();
      for(var list:scripted.values())for(var a:list)reserved.add(new BlockPos(a.get(1).getAsInt(),a.get(2).getAsInt(),a.get(3).getAsInt()));
      var steps=new JsonArray();
      for(int t=0;t<TICKS;t++){
        probe.time=t;probe.writes=new JsonArray();probe.sounds=new JsonArray();probe.raised=new JsonArray();
        probe.executed=new JsonArray();probe.events=new JsonArray();
        var now=new ArrayList<JsonArray>(scripted.getOrDefault(t,List.of()));
        if(t<ACTIVE)for(int n=random.nextInt(4);n>0;n--){
          int roll=random.nextInt(100);var pos=anyPos(random);
          // A container's removal spills its slots, drawing from the level random even when empty
          // (`Containers.dropItemStack`), which ValiMC's owner does with its own: scenes keep them.
          if(roll<70&&(reserved.contains(pos)||probe.getBlockEntity(pos) instanceof net.minecraft.world.Container||now.stream().anyMatch(a->pos.equals(new BlockPos(a.get(1).getAsInt(),a.get(2).getAsInt(),a.get(3).getAsInt())))))continue;
          if(roll<55){
            var state=pick(random);now.add(RedstoneOracle.action("set",pos,Block.getId(state)));
            if(state.getBlock() instanceof PistonBaseBlock&&random.nextBoolean())now.add(RedstoneOracle.action("placed",pos));
          }else if(roll<70){
            now.add(RedstoneOracle.action("set",pos,Block.getId(piston(random))));now.add(RedstoneOracle.action("placed",pos));
          }else{
            var candidates=cellsWhere(probe,st->st.getBlock() instanceof LeverBlock||st.getBlock() instanceof ButtonBlock);
            candidates.removeIf(c->reserved.contains(c)||now.stream().anyMatch(a->a.get(0).getAsString().equals("set")
              &&c.equals(new BlockPos(a.get(1).getAsInt(),a.get(2).getAsInt(),a.get(3).getAsInt()))));
            if(!candidates.isEmpty()){
              var at=RedstoneOracle.any(random,candidates);now.add(RedstoneOracle.action("use",at,2+random.nextInt(4),1));
              // Power toggled twice in one tick.
              if(random.nextInt(4)==0&&probe.cell(at).getBlock() instanceof LeverBlock)now.add(RedstoneOracle.action("use",at,2,1));
            }
          }
        }
        // A player's actions, before the level ticks.
        probe.handling=false;
        for(var a:now){
          var pos=new BlockPos(a.get(1).getAsInt(),a.get(2).getAsInt(),a.get(3).getAsInt());
          switch(a.get(0).getAsString()){
            case "set"->probe.setBlock(pos,Block.stateById(a.get(4).getAsInt()),Block.UPDATE_ALL);
            case "placed"->{var st=probe.cell(pos);if(st.getBlock() instanceof PistonBaseBlock)st.getBlock().setPlacedBy(probe,pos,st,null,net.minecraft.world.item.ItemStack.EMPTY);}
            case "use"->{
              var st=probe.cell(pos);user.setYRot(Direction.from3DDataValue(a.get(4).getAsInt()).toYRot());
              if(st.getBlock() instanceof LeverBlock||st.getBlock() instanceof ButtonBlock)
                st.useWithoutItem(probe,user,new BlockHitResult(Vec3.atCenterOf(pos),Direction.UP,pos,false));
            }
            default->throw new AssertionError(a);
          }
        }
        // `ServerLevel.tick`: the due block ticks, then the block events.
        probe.handling=true;
        probe.blockTicks.tick(t,65536,(pos,block)->{
          try{tickBlock.invoke(probe,pos,block);}catch(Exception e){throw new RuntimeException(e);}
        });
        if(probe.fluidTicks.count()>0)throw new AssertionError("fluid ticks in a piston scene");
        probe.runBlockEvents();
        probe.handling=false;
        // The entities (none), then the block entities.
        probe.tickBlockEntities();
        var moving=movingRows(probe);
        tally.merge("writes",probe.writes.size(),Integer::sum);tally.merge("block events raised",probe.raised.size(),Integer::sum);
        tally.merge("block events run",probe.executed.size(),Integer::sum);
        for(var e:probe.executed){var r=e.getAsJsonArray();if(BuiltInRegistries.BLOCK.byId(r.get(3).getAsInt()) instanceof PistonBaseBlock)
          tally.merge(r.get(4).getAsInt()==0?"extensions":r.get(4).getAsInt()==1?"retractions":"drops",1,Integer::sum);}
        tally.merge("moving block ticks",moving.size(),Integer::sum);
        if(!now.isEmpty()||!probe.writes.isEmpty()||!probe.sounds.isEmpty()||!probe.raised.isEmpty()||!probe.executed.isEmpty()||!moving.isEmpty()||!probe.events.isEmpty()){
          var step=new JsonObject();step.addProperty("t",t);
          var acts=new JsonArray();now.forEach(acts::add);step.add("actions",acts);
          step.add("writes",probe.writes);step.add("events",probe.events);step.add("sounds",probe.sounds);step.add("raised",probe.raised);
          step.add("executed",probe.executed);step.add("moving",moving);steps.add(step);
        }
      }
      var scene=new JsonObject();scene.addProperty("seed",levelSeed);scene.add("cells",cells);scene.add("steps",steps);scenes.add(scene);
    }
    var result=new JsonObject();result.add("scenes",scenes);
    Files.writeString(Path.of(out),new GsonBuilder().disableHtmlEscaping().create().toJson(result)+"\n");
    System.out.println("PASS: "+sceneCount+" piston scenes (seed "+seed+"): "+tally);
  }
}
