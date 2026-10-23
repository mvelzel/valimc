import com.google.gson.*;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.ReloadableServerRegistries;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.util.KeyframeTrack;
import net.minecraft.util.RandomSource;
import net.minecraft.world.attribute.EnvironmentAttribute;
import net.minecraft.world.attribute.EnvironmentAttributeMap;
import net.minecraft.world.attribute.EnvironmentAttributeSystem;
import net.minecraft.world.attribute.EnvironmentAttributes;
import net.minecraft.world.attribute.LerpFunction;
import net.minecraft.world.attribute.WeatherAttributes;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.monster.zombie.Zombie;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.projectile.arrow.Arrow;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.BlockEntity;
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
 * Redstone power and its components (VMC-047a, VMC-048a), from pinned 26.3. Three modes:
 *
 * - `facts OUT`: what the components are. `components`: per block that reacts to or gives power
 *   (by class: levers, buttons, pressure plates, redstone torches, lamps, doors, trapdoors, fence
 *   gates, note blocks, TNT, target blocks, daylight detectors, tripwire hooks, tripwire,
 *   lecterns, repeaters, comparators, observers) its kind, its parameters (a button's pressed
 *   ticks and whether arrows press it, a plate's sensitivity, a weighted plate's maximum weight,
 *   whether a hand opens a door or trapdoor) and its sounds; `bounds`: the outline bounds of every
 *   button and tripwire state (their entity checks); `instruments`: the note block instruments;
 *   `sound_ids`: every sound's registry id; `analog`: every block with an analog output, its
 *   signal per state or `entity`, and whether its removal tells comparators; `day`: the overworld's
 *   `SKY_LIGHT_LEVEL` (the dimension's value, the day timeline's multiplier keyframes and the
 *   weather's alpha blends) and `SUN_ANGLE` keyframes with their cubic Bezier easing.
 * - `day OUT`: `Level.skyDarken` and `SUN_ANGLE` from vanilla's own samplers, modifiers and
 *   weather lerps: every tick of a day in clear weather, then random times, rain and thunder.
 * - `scenes OUT [SCENES [SEED]]`: circuits over a probe level whose block ticks are vanilla's own
 *   `LevelTicks`, straddling chunk and 8 x 8 chunk section lines. Each game tick runs the due block
 *   ticks, then (every twentieth) the daylight detectors' updates, then its actions (block sets
 *   as `/setblock` makes them, uses as a player's `useWithoutItem`, a tripwire hook's
 *   `setPlacedBy`, a lectern's page, a projectile's hit on a target, a tripwire disarmed), then
 *   each entity's contacts with the plates, buttons and tripwire it touches (`entityInside`, an
 *   entity's cells in x, then y, then z order). Per tick: the cell writes, level events, sounds,
 *   block events, primed TNT, use results and the comparators whose output changed. Some scenes
 *   run a lever-driven torch until it burns out, a tripwire line between two hooks, a repeater
 *   line with a lock, a comparator clock and a comparator reading a chest that is refilled
 *   (`fill`: one change of its contents, its signal recorded), or two observers facing each
 *   other. Comparators, chests and furnaces keep their block entities.
 *
 * Usage: RedstoneOracle (facts|day|scenes) OUT [SCENES [SEED]]
 */
public class RedstoneOracle {
  static final int FLOOR_Y=63,MIN_X=125,MAX_X=131,MIN_Z=-3,MAX_Z=3,TICKS=200,ACTIVE=150;

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }

  /** An entity a scene places: its box and kind (0 not living, 1 living, 2 an arrow), until a tick. */
  record Body(AABB box,int kind,int until){}

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Server server;RandomSource random;GameRules rules;
    LevelTicks<Block> blockTicks;LevelTicks<Fluid> fluidTicks;long time,subTick;int darken;
    EnvironmentAttributeSystem attributes;List<Body> bodies=new ArrayList<>();Entity[] stubs;
    JsonArray writes=new JsonArray(),events=new JsonArray(),sounds=new JsonArray(),blockEvents=new JsonArray(),primed=new JsonArray();
    /** The block entities of comparators, chests and furnaces, as `LevelChunk` keeps them. */
    Map<BlockPos,BlockEntity> entities;
    /** Facts: an analog output read from the state alone, at the origin; any other read throws. */
    BlockState strict;int outputUpdates;
    private Probe(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    BlockState cell(BlockPos pos){return cells.getOrDefault(pos,Blocks.AIR.defaultBlockState());}
    @Override public BlockState getBlockState(BlockPos pos){
      if(strict!=null){if(!pos.equals(BlockPos.ZERO))throw new Contextual();return strict;}
      return cell(pos);
    }
    @Override public FluidState getFluidState(BlockPos pos){return cell(pos).getFluidState();}
    @Override public BlockEntity getBlockEntity(BlockPos pos){if(strict!=null)throw new Contextual();return entities.get(pos);}
    @Override public void blockEntityChanged(BlockPos pos){}
    @Override public void updateNeighbourForOutputSignal(BlockPos pos,Block block){outputUpdates++;super.updateNeighbourForOutputSignal(pos,block);}
    @Override public int getMinY(){return -64;}
    @Override public int getHeight(){return 384;}
    @Override public MinecraftServer getServer(){return server;}
    @Override public RandomSource getRandom(){return random;}
    @Override public GameRules getGameRules(){return rules;}
    @Override public long getGameTime(){return time;}
    int entityIds;
    @Override public int getNextEntityId(){return ++entityIds;}
    @Override public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    @Override public LevelTicks<Block> getBlockTicks(){return blockTicks;}
    @Override public LevelTicks<Fluid> getFluidTicks(){return fluidTicks;}
    @Override public boolean isClientSide(){return false;}
    @Override public boolean isLoaded(BlockPos pos){return !isOutsideBuildHeight(pos);}
    @Override public boolean hasChunkAt(BlockPos pos){return true;}
    @Override public int getEffectiveSkyBrightness(BlockPos pos){return Math.max(15-darken,0);}
    @Override public EnvironmentAttributeSystem environmentAttributes(){return attributes;}
    @Override public void levelEvent(Entity source,int type,BlockPos pos,int data){events.add(row(pos,type,data));}
    @Override public void blockEvent(BlockPos pos,Block block,int b0,int b1){blockEvents.add(row(pos,BuiltInRegistries.BLOCK.getId(block),b0,b1));}
    @Override public void gameEvent(Holder<GameEvent> event,Vec3 at,GameEvent.Context context){}
    @Override public void gameEvent(Entity source,Holder<GameEvent> event,BlockPos pos){}
    @Override public void playSeededSound(Entity except,double x,double y,double z,Holder<SoundEvent> sound,SoundSource source,float volume,float pitch,long seed){
      var row=new JsonArray();row.add(x);row.add(y);row.add(z);row.add(sound.value().location().toString());
      row.add(Float.floatToIntBits(volume));row.add(Float.floatToIntBits(pitch));row.add(except!=null);sounds.add(row);
    }
    @Override public void playSeededSound(Entity except,Entity at,Holder<SoundEvent> sound,SoundSource source,float volume,float pitch,long seed){
      playSeededSound(except,at.getX(),at.getY(),at.getZ(),sound,source,volume,pitch,seed);
    }
    @Override public boolean addFreshEntity(Entity entity){
      primed.add(row(BlockPos.containing(entity.getX(),entity.getY(),entity.getZ())));return true;
    }
    @Override public void scheduleTick(BlockPos pos,Block block,int delay,TickPriority priority){
      blockTicks.schedule(new ScheduledTick<>(block,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Block block,int delay){scheduleTick(pos,block,delay,TickPriority.NORMAL);}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay,TickPriority priority){
      fluidTicks.schedule(new ScheduledTick<>(fluid,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay){scheduleTick(pos,fluid,delay,TickPriority.NORMAL);}
    /** The scene's bodies whose boxes meet `box`, each its kind's stub entity. */
    List<Entity> touching(AABB box){
      var out=new ArrayList<Entity>();
      for(var body:bodies)if(body.box().intersects(box))out.add(stubs[body.kind()]);
      return out;
    }
    @Override public List<Entity> getEntities(Entity except,AABB bb,Predicate<? super Entity> selector){
      if(strict!=null)throw new Contextual();
      var out=new ArrayList<Entity>();for(var e:touching(bb))if(e!=except&&selector.test(e))out.add(e);return out;
    }
    @Override public <T extends Entity> List<T> getEntities(EntityTypeTest<Entity,T> type,AABB bb,Predicate<? super T> selector){
      if(strict!=null)throw new Contextual();
      var out=new ArrayList<T>();
      for(var e:touching(bb)){T t=type.tryCast(e);if(t!=null&&selector.test(t))out.add(t);}
      return out;
    }

    /**
     * `Level.setBlock` with `LevelChunk.setBlockState`'s hooks, over the map (as RedstoneWireOracle's):
     * a changed block loses its block entity before `affectNeighborsAfterRemoval`, a new one gets
     * its own after `onPlace`; an analog output tells the comparators around it.
     */
    @Override public boolean setBlock(BlockPos pos,BlockState state,int flags,int limit){
      if(isOutsideBuildHeight(pos))return false;
      pos=pos.immutable();var old=cell(pos);
      if(old==state)return false;
      cells.put(pos,state);writes.add(row(pos,Block.getId(state)));
      var block=state.getBlock();
      if(!old.is(block))entities.remove(pos);
      if(!old.is(block)&&(flags&1)!=0)old.affectNeighborsAfterRemoval(this,pos,false);
      if(!cell(pos).is(block))return false;
      if((flags&512)==0)state.onPlace(this,pos,old,false);
      if(entityBlock(state)&&cell(pos).is(block)&&!entities.containsKey(pos)){
        var entity=((EntityBlock)block).newBlockEntity(pos,state);entity.setLevel(this);entities.put(pos,entity);
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
  }

  /** A read past the state itself (its block entity, a neighbour, entities). */
  static final class Contextual extends RuntimeException{Contextual(){super(null,null,false,false);}}

  /** The blocks whose block entities scenes keep: comparators', chests' and furnaces'. */
  static boolean entityBlock(BlockState state){
    var b=state.getBlock();return b instanceof ComparatorBlock||b instanceof ChestBlock||b instanceof AbstractFurnaceBlock;
  }

  /** A player for uses: its facing, and whether it may build. */
  static class User extends Player {
    private User(){super(null,null);}
    @Override public net.minecraft.world.level.GameType gameMode(){return net.minecraft.world.level.GameType.SURVIVAL;}
  }

  static JsonArray row(BlockPos pos,int... values){
    var row=new JsonArray();row.add(pos.getX());row.add(pos.getY());row.add(pos.getZ());
    for(int v:values)row.add(v);
    return row;
  }

  static <T> T any(Random random,List<T> values){return values.get(random.nextInt(values.size()));}

  static Object field(Object owner,Class<?> type,String name)throws Exception{
    var f=type.getDeclaredField(name);f.setAccessible(true);return f.get(owner);
  }

  static String sound(SoundEvent sound){return sound.location().toString();}

  public static void main(String[] args)throws Exception{
    switch(args[0]){
      case "facts"->facts(args[1]);
      case "day"->day(args[1]);
      case "scenes"->scenes(args[1],args.length>2?Integer.parseInt(args[2]):120,args.length>3?Long.parseLong(args[3]):47_001L);
      default->throw new IllegalArgumentException(args[0]);
    }
  }

  // ---- facts ----

  static void facts(String out)throws Exception{
    var lookup=MiningToolOracle.initialize();
    var components=new JsonArray();var bounds=new JsonArray();var counts=new TreeMap<String,Integer>();
    for(var block:BuiltInRegistries.BLOCK){
      var entry=new JsonObject();var sounds=new JsonArray();String kind=null;
      if(block instanceof LeverBlock){kind="lever";sounds.add(sound(net.minecraft.sounds.SoundEvents.LEVER_CLICK));}
      else if(block instanceof ButtonBlock){
        kind="button";var type=(BlockSetType)field(block,ButtonBlock.class,"type");
        entry.addProperty("ticks",(int)field(block,ButtonBlock.class,"ticksToStayPressed"));
        entry.addProperty("arrows",type.canButtonBeActivatedByArrows());
        sounds.add(sound(type.buttonClickOn()));sounds.add(sound(type.buttonClickOff()));
        for(var state:block.getStateDefinition().getPossibleStates())bounds.add(bounds(state));
      }else if(block instanceof WeightedPressurePlateBlock){
        kind="weighted";var type=(BlockSetType)field(block,BasePressurePlateBlock.class,"type");
        entry.addProperty("max",(int)field(block,WeightedPressurePlateBlock.class,"maxWeight"));
        sounds.add(sound(type.pressurePlateClickOn()));sounds.add(sound(type.pressurePlateClickOff()));
      }else if(block instanceof PressurePlateBlock){
        kind="plate";var type=(BlockSetType)field(block,BasePressurePlateBlock.class,"type");
        entry.addProperty("mobs",type.pressurePlateSensitivity()==BlockSetType.PressurePlateSensitivity.MOBS);
        sounds.add(sound(type.pressurePlateClickOn()));sounds.add(sound(type.pressurePlateClickOff()));
      }else if(block instanceof RedstoneWallTorchBlock)kind="wall_torch";
      else if(block instanceof RedstoneTorchBlock)kind="torch";
      else if(block instanceof RedstoneLampBlock)kind="lamp";
      else if(block instanceof DoorBlock){
        kind="door";var type=(BlockSetType)field(block,DoorBlock.class,"type");entry.addProperty("hand",type.canOpenByHand());
        sounds.add(sound(type.doorOpen()));sounds.add(sound(type.doorClose()));
      }else if(block instanceof TrapDoorBlock){
        kind="trapdoor";var type=(BlockSetType)field(block,TrapDoorBlock.class,"type");entry.addProperty("hand",type.canOpenByHand());
        sounds.add(sound(type.trapdoorOpen()));sounds.add(sound(type.trapdoorClose()));
      }else if(block instanceof FenceGateBlock){
        kind="gate";var type=(WoodType)field(block,FenceGateBlock.class,"type");
        sounds.add(sound(type.fenceGateOpen()));sounds.add(sound(type.fenceGateClose()));
      }else if(block instanceof NoteBlock)kind="note";
      else if(block instanceof TntBlock){kind="tnt";sounds.add(sound(net.minecraft.sounds.SoundEvents.TNT_PRIMED));}
      else if(block instanceof TargetBlock)kind="target";
      else if(block instanceof DaylightDetectorBlock)kind="daylight";
      else if(block instanceof TripWireHookBlock){
        kind="hook";
        for(var s:List.of(net.minecraft.sounds.SoundEvents.TRIPWIRE_CLICK_ON,net.minecraft.sounds.SoundEvents.TRIPWIRE_CLICK_OFF,
            net.minecraft.sounds.SoundEvents.TRIPWIRE_ATTACH,net.minecraft.sounds.SoundEvents.TRIPWIRE_DETACH))sounds.add(sound(s));
      }else if(block instanceof TripWireBlock){
        kind="tripwire";for(var state:block.getStateDefinition().getPossibleStates())bounds.add(bounds(state));
      }else if(block instanceof LecternBlock)kind="lectern";
      else if(block instanceof RepeaterBlock)kind="repeater";
      else if(block instanceof ComparatorBlock){kind="comparator";sounds.add(sound(net.minecraft.sounds.SoundEvents.COMPARATOR_CLICK));}
      else if(block instanceof ObserverBlock)kind="observer";
      else if(block instanceof net.minecraft.world.level.block.piston.PistonBaseBlock){
        kind="piston";entry.addProperty("sticky",block==Blocks.STICKY_PISTON);
        sounds.add(sound(net.minecraft.sounds.SoundEvents.PISTON_EXTEND));sounds.add(sound(net.minecraft.sounds.SoundEvents.PISTON_CONTRACT));
      }else if(block instanceof HopperBlock)kind="hopper";
      else if(block instanceof DispenserBlock){kind="dispenser";entry.addProperty("dropper",block instanceof DropperBlock);}
      if(kind==null)continue;
      entry.addProperty("block",BuiltInRegistries.BLOCK.getKey(block).getPath());entry.addProperty("kind",kind);
      if(!sounds.isEmpty())entry.add("sounds",sounds);
      // Every kind's own sound events are the ones its class plays (a lever has no set type).
      var ordered=new JsonObject();ordered.add("block",entry.remove("block"));ordered.add("kind",entry.remove("kind"));
      for(var e:entry.entrySet())ordered.add(e.getKey(),e.getValue());
      components.add(ordered);counts.merge(kind,1,Integer::sum);
    }
    for(var kind:List.of("lever","button","plate","weighted","torch","wall_torch","lamp","door","trapdoor","gate","note","tnt","target","daylight","hook","tripwire","lectern","repeater","comparator","observer","piston","hopper","dispenser"))
      if(!counts.containsKey(kind))throw new AssertionError("no "+kind);
    var instruments=new JsonArray();
    for(var instrument:NoteBlockInstrument.values()){
      var entry=new JsonObject();entry.addProperty("name",instrument.getSerializedName());
      entry.addProperty("sound",instrument.getSoundEvent().value().location().toString());
      entry.addProperty("tunable",instrument.isTunable());entry.addProperty("above",instrument.worksAboveNoteBlock());
      entry.addProperty("custom",instrument.hasCustomSound());instruments.add(entry);
    }
    // Every sound's registry id (the sound packet names a registered event by it).
    var soundIds=new JsonObject();var named=new TreeSet<String>();
    for(var c:components)if(c.getAsJsonObject().has("sounds"))for(var n:c.getAsJsonObject().getAsJsonArray("sounds"))named.add(n.getAsString());
    for(var i:instruments)named.add(i.getAsJsonObject().get("sound").getAsString());
    for(var name:named){
      var event=BuiltInRegistries.SOUND_EVENT.getValue(net.minecraft.resources.Identifier.parse(name));
      if(event==null)throw new AssertionError("unregistered sound "+name);
      soundIds.addProperty(name,BuiltInRegistries.SOUND_EVENT.getId(event));
    }
    var analog=analogFacts(lookup);var pistons=pistonFacts();
    var result=new JsonObject();result.add("components",components);result.add("bounds",bounds);
    result.add("instruments",instruments);result.add("sound_ids",soundIds);result.add("analog",analog);result.add("pistons",pistons);result.add("day",dayFacts(lookup));
    Files.writeString(Path.of(out),new GsonBuilder().disableHtmlEscaping().create().toJson(result)+"\n");
    System.out.println("PASS: redstone facts for "+components.size()+" components "+counts+", "+bounds.size()+" bounds, "
      +instruments.size()+" instruments, "+analog.size()+" analog outputs, "+pistons.getAsJsonObject("reactions").size()+" push reactions, the overworld day");
  }

  /**
   * Every block with an analog output (`hasAnalogOutputSignal`, which comparators read and whose
   * sets tell comparators): its signal per state where the state alone gives it (the same toward
   * every side), else `entity` (it reads its block entity, its neighbours or entities); and whether
   * its removal tells comparators (`Containers.updateNeighboursAfterDestroy`).
   */
  static JsonArray analogFacts(HolderLookup.Provider lookup)throws Exception{
    var probe=probe(lookup);probe.entities=new HashMap<>();probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
    setRandom(probe,RandomSource.create(0));
    var out=new JsonArray();
    for(var block:BuiltInRegistries.BLOCK){
      var states=block.getStateDefinition().getPossibleStates();
      if(!states.get(0).hasAnalogOutputSignal())continue;
      for(var state:states)if(!state.hasAnalogOutputSignal())throw new AssertionError("an analog output by state "+state);
      var entry=new JsonArray();entry.add(BuiltInRegistries.BLOCK.getKey(block).getPath());
      var values=new JsonArray();
      try{
        for(var state:block.getStateDefinition().getPossibleStates()){
          probe.strict=state;int value=-1;
          for(var d:Direction.values()){
            int v=state.getAnalogOutputSignal(probe,BlockPos.ZERO,d);
            if(value>=0&&v!=value)throw new AssertionError("an analog output by side "+state);
            value=v;
          }
          values.add(value);
        }
        entry.add(values);
      }catch(Contextual e){entry.add("entity");}
      finally{probe.strict=null;}
      // Its removal, over an empty level.
      probe.cells=new HashMap<>();probe.outputUpdates=0;
      var state=block.defaultBlockState();probe.cells.put(BlockPos.ZERO,Blocks.AIR.defaultBlockState());
      state.affectNeighborsAfterRemoval(probe,BlockPos.ZERO,false);
      entry.add(probe.outputUpdates>0);
      out.add(entry);
    }
    return out;
  }

  /**
   * What a piston reads of a block (VMC-048b, `PistonBaseBlock.isPushable`): its push reaction where
   * not `PUSH_PULL` (`push`, `popped`, `immoveable`, `ignore_entity`), the blocks no tool breaks
   * (destroy speed -1) and those with block entities. Each is the same for every state of a block.
   */
  static JsonObject pistonFacts(){
    var reactions=new JsonObject();var unbreakable=new JsonArray();var entities=new JsonArray();
    for(var block:BuiltInRegistries.BLOCK){
      var name=BuiltInRegistries.BLOCK.getKey(block).getPath();var states=block.getStateDefinition().getPossibleStates();var first=states.get(0);
      for(var state:states)if(state.getPistonPushReaction()!=first.getPistonPushReaction()||state.getDestroySpeed(net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO)!=first.getDestroySpeed(net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO)
          ||state.hasBlockEntity()!=first.hasBlockEntity())throw new AssertionError("piston facts by state "+state);
      var reaction=first.getPistonPushReaction();
      if(reaction!=net.minecraft.world.level.material.PushReaction.PUSH_PULL)reactions.addProperty(name,reaction.name().toLowerCase(Locale.ROOT));
      if(first.getDestroySpeed(net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO)==-1.0F)unbreakable.add(name);
      if(first.hasBlockEntity())entities.add(name);
    }
    var out=new JsonObject();out.add("reactions",reactions);out.add("unbreakable",unbreakable);out.add("entities",entities);
    return out;
  }

  static JsonArray bounds(BlockState state){
    var box=state.getShape(net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO).bounds();
    var row=new JsonArray();row.add(Block.getId(state));
    row.add(box.minX);row.add(box.minY);row.add(box.minZ);row.add(box.maxX);row.add(box.maxY);row.add(box.maxZ);
    return row;
  }

  // ---- the day ----

  /** The day timeline; no other timeline has a sky light or sun angle track. */
  static net.minecraft.world.timeline.Timeline overworldDay(HolderLookup.Provider lookup)throws Exception{
    var timelines=lookup.lookupOrThrow(Registries.TIMELINE);
    for(var entry:timelines.listElements().toList()){
      if(entry.key().equals(net.minecraft.world.timeline.Timelines.OVERWORLD_DAY))continue;
      var tracks=tracks(entry.value());
      if(tracks.containsKey(EnvironmentAttributes.SKY_LIGHT_LEVEL)||tracks.containsKey(EnvironmentAttributes.SUN_ANGLE))
        throw new AssertionError("another timeline moves the sky: "+entry.key());
    }
    return timelines.getOrThrow(net.minecraft.world.timeline.Timelines.OVERWORLD_DAY).value();
  }

  @SuppressWarnings("unchecked")
  static Map<EnvironmentAttribute<?>,net.minecraft.world.timeline.AttributeTrack<?,?>> tracks(net.minecraft.world.timeline.Timeline timeline)throws Exception{
    return (Map<EnvironmentAttribute<?>,net.minecraft.world.timeline.AttributeTrack<?,?>>)field(timeline,net.minecraft.world.timeline.Timeline.class,"tracks");
  }

  static float overworldBase(HolderLookup.Provider lookup){
    var type=lookup.lookupOrThrow(Registries.DIMENSION_TYPE)
      .getOrThrow(ResourceKey.create(Registries.DIMENSION_TYPE,net.minecraft.resources.Identifier.parse("minecraft:overworld"))).value();
    return type.attributes().applyModifier(EnvironmentAttributes.SKY_LIGHT_LEVEL,EnvironmentAttributes.SKY_LIGHT_LEVEL.defaultValue());
  }

  static JsonObject dayFacts(HolderLookup.Provider lookup)throws Exception{
    var timeline=overworldDay(lookup);var tracks=tracks(timeline);
    var sky=tracks.get(EnvironmentAttributes.SKY_LIGHT_LEVEL);var sun=tracks.get(EnvironmentAttributes.SUN_ANGLE);
    if(!sky.modifier().equals(net.minecraft.world.attribute.modifier.FloatModifier.MULTIPLY))throw new AssertionError("sky light modifier "+sky.modifier());
    if(!(sky.argumentTrack().easingType()==net.minecraft.util.EasingType.LINEAR))throw new AssertionError("sky light easing");
    var day=new JsonObject();day.addProperty("period",timeline.periodTicks().orElseThrow());
    day.addProperty("base",overworldBase(lookup));
    var skyJson=new JsonObject();skyJson.add("keyframes",keyframes(sky.argumentTrack()));day.add("sky_light_level",skyJson);
    var sunJson=new JsonObject();sunJson.add("keyframes",keyframes(sun.argumentTrack()));
    var easing=sun.argumentTrack().easingType();
    if(!(easing instanceof net.minecraft.util.EasingType.CubicBezier bezier))throw new AssertionError("sun easing "+easing);
    var controls=field(bezier,net.minecraft.util.EasingType.CubicBezier.class,"controls");var c=new JsonArray();
    for(var name:List.of("x1","y1","x2","y2"))c.add((float)controls.getClass().getMethod(name).invoke(controls));
    sunJson.add("bezier",c);day.add("sun_angle",sunJson);
    day.add("rain",blend(WeatherAttributes.RAIN));day.add("thunder",blend(WeatherAttributes.THUNDER));
    return day;
  }

  static JsonArray keyframes(KeyframeTrack<?> track){
    var out=new JsonArray();
    for(var frame:track.keyframes()){var f=new JsonArray();f.add(frame.ticks());f.add((Float)frame.value());out.add(f);}
    return out;
  }

  static JsonArray blend(EnvironmentAttributeMap weather){
    var entry=weather.get(EnvironmentAttributes.SKY_LIGHT_LEVEL);
    var argument=(net.minecraft.world.attribute.modifier.FloatWithAlpha)entry.argument();
    if(!entry.modifier().equals(net.minecraft.world.attribute.modifier.FloatModifier.ALPHA_BLEND))throw new AssertionError("weather modifier");
    var out=new JsonArray();out.add(argument.value());out.add(argument.alpha());return out;
  }

  /** `skyDarken` and `SUN_ANGLE` from vanilla's samplers, modifiers and weather lerps. */
  @SuppressWarnings({"unchecked","rawtypes"})
  static void day(String out)throws Exception{
    var lookup=MiningToolOracle.initialize();var timeline=overworldDay(lookup);var tracks=tracks(timeline);
    var period=timeline.periodTicks();float base=overworldBase(lookup);
    var skyTrack=(net.minecraft.world.timeline.AttributeTrack)tracks.get(EnvironmentAttributes.SKY_LIGHT_LEVEL);
    var sunTrack=(net.minecraft.world.timeline.AttributeTrack)tracks.get(EnvironmentAttributes.SUN_ANGLE);
    var skySampler=skyTrack.argumentTrack().bakeSampler(period,(LerpFunction)LerpFunction.ofFloat());
    var sunSampler=sunTrack.argumentTrack().bakeSampler(period,(LerpFunction)EnvironmentAttributes.SUN_ANGLE.type().keyframeLerp());
    var attribute=EnvironmentAttributes.SKY_LIGHT_LEVEL;var lerp=attribute.type().stateChangeLerp();
    var rainEntry=WeatherAttributes.RAIN.get(attribute);var thunderEntry=WeatherAttributes.THUNDER.get(attribute);
    var random=new Random(47_002L);var samples=new JsonArray();
    for(int i=0;i<24000+4000;i++){
      long ticks=i<24000?i:random.nextLong(0,10_000_000L);
      float rain=i<24000?0:random.nextInt(4)==0?1.0F:random.nextFloat(),thunder=i<24000?0:random.nextInt(3)==0?0:random.nextFloat()*rain;
      Float level=(Float)skyTrack.modifier().apply(base,skySampler.sample(ticks));
      float rainLevel=rain-thunder;
      if(rainLevel>0)level=(Float)lerp.apply(rainLevel,level,rainEntry.applyModifier(level));
      if(thunder>0)level=(Float)lerp.apply(thunder,level,thunderEntry.applyModifier(level));
      level=attribute.sanitizeValue(level);
      int darken=(int)(15.0F-level);
      Float sun=(Float)sunTrack.modifier().apply(EnvironmentAttributes.SUN_ANGLE.defaultValue(),sunSampler.sample(ticks));
      var row=new JsonArray();row.add(ticks);row.add(Float.floatToIntBits(rain));row.add(Float.floatToIntBits(thunder));
      row.add(darken);row.add(Float.floatToIntBits(sun));samples.add(row);
    }
    var result=new JsonObject();result.add("samples",samples);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    System.out.println("PASS: "+samples.size()+" day samples (a clear day tick by tick, then random times and weather)");
  }

  // ---- scenes ----

  static Probe probe(HolderLookup.Provider lookup)throws Exception{
    var theUnsafe=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");theUnsafe.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)theUnsafe.get(null);
    var server=(Server)unsafe.allocateInstance(Server.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var probe=(Probe)unsafe.allocateInstance(Probe.class);probe.server=server;
    probe.cells=new HashMap<>();probe.bodies=new ArrayList<>();
    var updater=Level.class.getDeclaredField("neighborUpdater");updater.setAccessible(true);
    updater.set(probe,new CollectingNeighborUpdater(probe,1_000_000));
    var players=ServerLevel.class.getDeclaredField("players");players.setAccessible(true);players.set(probe,new ArrayList<>());
    var seeds=Level.class.getDeclaredField("soundSeedGenerator");seeds.setAccessible(true);seeds.set(probe,RandomSource.create(0));
    probe.stubs=new Entity[]{(Entity)unsafe.allocateInstance(ItemEntity.class),(Entity)unsafe.allocateInstance(Zombie.class),
      (Entity)unsafe.allocateInstance(Arrow.class)};
    return probe;
  }

  static void setRandom(Probe probe,RandomSource random)throws Exception{
    probe.random=random;var f=Level.class.getDeclaredField("random");f.setAccessible(true);f.set(probe,random);
  }

  /** A state to set at `pos`: wire and tripwire as a player places them, the others as `/setblock` sets them. */
  static BlockState pick(Random random,Probe probe,BlockPos pos,BlockState cross,Method connection)throws Exception{
    var horizontal=List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST);
    var faces=List.of(AttachFace.FLOOR,AttachFace.WALL,AttachFace.CEILING);
    if(random.nextInt(3)==0)return pickTimed(random);
    int roll=random.nextInt(100);
    if(roll<16)return (BlockState)connection.invoke(Blocks.REDSTONE_WIRE,probe,cross,pos);
    if(roll<22)return Blocks.AIR.defaultBlockState();
    if(roll<29)return Blocks.STONE.defaultBlockState();
    if(roll<31)return Blocks.GLASS.defaultBlockState();
    if(roll<34)return Blocks.REDSTONE_BLOCK.defaultBlockState();
    if(roll<38)return Blocks.REDSTONE_TORCH.defaultBlockState();
    if(roll<41)return Blocks.REDSTONE_WALL_TORCH.defaultBlockState().setValue(RedstoneWallTorchBlock.FACING,any(random,horizontal));
    if(roll<45)return Blocks.LEVER.defaultBlockState().setValue(LeverBlock.FACE,any(random,faces)).setValue(LeverBlock.FACING,any(random,horizontal));
    if(roll<49)return (random.nextBoolean()?Blocks.STONE_BUTTON:Blocks.OAK_BUTTON).defaultBlockState()
      .setValue(ButtonBlock.FACE,any(random,faces)).setValue(ButtonBlock.FACING,any(random,horizontal));
    if(roll<55)return any(random,List.of(Blocks.STONE_PRESSURE_PLATE,Blocks.OAK_PRESSURE_PLATE,Blocks.LIGHT_WEIGHTED_PRESSURE_PLATE,
      Blocks.HEAVY_WEIGHTED_PRESSURE_PLATE)).defaultBlockState();
    if(roll<63)return Blocks.REDSTONE_LAMP.defaultBlockState();
    if(roll<68)return (random.nextBoolean()?Blocks.OAK_TRAPDOOR:Blocks.IRON_TRAPDOOR).defaultBlockState()
      .setValue(TrapDoorBlock.FACING,any(random,horizontal)).setValue(TrapDoorBlock.HALF,random.nextBoolean()?Half.TOP:Half.BOTTOM);
    if(roll<71)return Blocks.OAK_FENCE_GATE.defaultBlockState().setValue(FenceGateBlock.FACING,any(random,horizontal));
    if(roll<76)return Blocks.NOTE_BLOCK.defaultBlockState();
    if(roll<80)return Blocks.TNT.defaultBlockState();
    if(roll<83)return Blocks.TARGET.defaultBlockState();
    if(roll<87)return Blocks.DAYLIGHT_DETECTOR.defaultBlockState().setValue(DaylightDetectorBlock.INVERTED,random.nextBoolean());
    if(roll<91)return Blocks.TRIPWIRE_HOOK.defaultBlockState().setValue(TripWireHookBlock.FACING,any(random,horizontal));
    if(roll<96)return tripwire(probe,pos);
    return Blocks.LECTERN.defaultBlockState().setValue(LecternBlock.FACING,any(random,horizontal)).setValue(LecternBlock.HAS_BOOK,true);
  }

  /** VMC-048a's blocks: repeaters, comparators and observers in any state, chests, furnaces, cakes and composters. */
  static BlockState pickTimed(Random random){
    var horizontal=List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST);
    int roll=random.nextInt(100);
    if(roll<30)return Blocks.REPEATER.defaultBlockState().setValue(RepeaterBlock.FACING,any(random,horizontal))
      .setValue(RepeaterBlock.DELAY,1+random.nextInt(4)).setValue(RepeaterBlock.LOCKED,random.nextInt(4)==0)
      .setValue(RepeaterBlock.POWERED,random.nextInt(3)==0);
    if(roll<55)return Blocks.COMPARATOR.defaultBlockState().setValue(ComparatorBlock.FACING,any(random,horizontal))
      .setValue(ComparatorBlock.MODE,random.nextBoolean()?ComparatorMode.COMPARE:ComparatorMode.SUBTRACT)
      .setValue(ComparatorBlock.POWERED,random.nextInt(3)==0);
    if(roll<75)return Blocks.OBSERVER.defaultBlockState().setValue(ObserverBlock.FACING,any(random,List.of(Direction.values())))
      .setValue(ObserverBlock.POWERED,random.nextInt(4)==0);
    if(roll<87)return Blocks.CHEST.defaultBlockState().setValue(ChestBlock.FACING,any(random,horizontal));
    if(roll<92)return Blocks.FURNACE.defaultBlockState().setValue(FurnaceBlock.FACING,any(random,horizontal));
    if(roll<96)return Blocks.CAKE.defaultBlockState().setValue(CakeBlock.BITES,random.nextInt(7));
    // Not 7: a composter at 7 ticks itself to ready (not redstone).
    return Blocks.COMPOSTER.defaultBlockState().setValue(ComposterBlock.LEVEL,any(random,List.of(0,1,2,3,4,5,6,8)));
  }

  /** The items fills draw from (after bootstrap). */
  static List<net.minecraft.world.item.Item> fills(){return List.of(net.minecraft.world.item.Items.STONE,
    net.minecraft.world.item.Items.ENDER_PEARL,net.minecraft.world.item.Items.DIAMOND_SWORD,net.minecraft.world.item.Items.COBBLESTONE,
    net.minecraft.world.item.Items.SNOWBALL,net.minecraft.world.item.Items.TOTEM_OF_UNDYING,net.minecraft.world.item.Items.COAL,
    net.minecraft.world.item.Items.RAW_IRON);}

  /**
   * A container's new contents, as one change (`setChanged` once): each slot empty or a random
   * stack of a few items with different stack sizes. The action records them and vanilla's signal.
   */
  static JsonArray fill(Random random,Probe probe,BlockPos pos)throws Exception{
    var entity=(net.minecraft.world.level.block.entity.BaseContainerBlockEntity)probe.entities.get(pos);
    var getItems=net.minecraft.world.level.block.entity.BaseContainerBlockEntity.class.getDeclaredMethod("getItems");
    getItems.setAccessible(true);
    @SuppressWarnings("unchecked") var items=(List<net.minecraft.world.item.ItemStack>)getItems.invoke(entity);
    var slots=new JsonArray();int full=random.nextInt(4);
    for(int i=0;i<items.size();i++){
      if(full==0||random.nextInt(4)==0&&full<3){items.set(i,net.minecraft.world.item.ItemStack.EMPTY);continue;}
      var item=any(random,fills());int max=new net.minecraft.world.item.ItemStack(item).getMaxStackSize();
      int count=full==3?max:1+random.nextInt(max);
      items.set(i,new net.minecraft.world.item.ItemStack(item,count));
      var slot=new JsonArray();slot.add(i);slot.add(BuiltInRegistries.ITEM.getKey(item).toString());slot.add(count);slots.add(slot);
    }
    entity.setChanged();
    var a=action("fill",pos,net.minecraft.world.inventory.AbstractContainerMenu.getRedstoneSignalFromContainer(entity));
    a.add(slots);a.add(items.size());
    return a;
  }

  /** The comparators' outputs (their block entities'). */
  static Map<BlockPos,Integer> outputs(Probe probe){
    var out=new HashMap<BlockPos,Integer>();
    for(var e:probe.entities.entrySet())
      if(e.getValue() instanceof net.minecraft.world.level.block.entity.ComparatorBlockEntity c)out.put(e.getKey(),c.getOutputSignal());
    return out;
  }

  /** `TripWireBlock.getStateForPlacement`: connected toward hooks facing it and tripwire. */
  static BlockState tripwire(Probe probe,BlockPos pos){
    var wire=(TripWireBlock)Blocks.TRIPWIRE;
    return wire.defaultBlockState().setValue(TripWireBlock.NORTH,wire.shouldConnectTo(probe.cell(pos.north()),Direction.NORTH))
      .setValue(TripWireBlock.EAST,wire.shouldConnectTo(probe.cell(pos.east()),Direction.EAST))
      .setValue(TripWireBlock.SOUTH,wire.shouldConnectTo(probe.cell(pos.south()),Direction.SOUTH))
      .setValue(TripWireBlock.WEST,wire.shouldConnectTo(probe.cell(pos.west()),Direction.WEST));
  }

  static JsonArray action(String kind,BlockPos pos,Number... values){
    var a=new JsonArray();a.add(kind);a.add(pos.getX());a.add(pos.getY());a.add(pos.getZ());for(var v:values)a.add(v);return a;
  }

  static boolean usable(BlockState s){
    var b=s.getBlock();
    return b instanceof LeverBlock||b instanceof ButtonBlock||b instanceof DoorBlock||b instanceof TrapDoorBlock||b instanceof FenceGateBlock
      ||b instanceof NoteBlock||b instanceof DaylightDetectorBlock||b instanceof DiodeBlock;
  }

  static boolean touchable(BlockState s){
    var b=s.getBlock();return b instanceof BasePressurePlateBlock||b instanceof ButtonBlock||b instanceof TripWireBlock;
  }

  /** The cells holding a state that `filter` takes, sorted. */
  static List<BlockPos> cellsWhere(Probe probe,Predicate<BlockState> filter){
    var out=new ArrayList<BlockPos>();
    for(var e:probe.cells.entrySet())if(filter.test(e.getValue()))out.add(e.getKey());
    out.sort(Comparator.naturalOrder());return out;
  }

  /** An entity's contacts: `entityInside` of each plate, button and tripwire its deflated box touches. */
  static void contacts(Probe probe)throws Exception{
    for(var body:List.copyOf(probe.bodies)){
      var box=body.box().deflate(1.0E-5);var entity=probe.stubs[body.kind()];
      for(int z=Mth.floor(box.minZ);z<=Mth.floor(box.maxZ);z++)for(int y=Mth.floor(box.minY);y<=Mth.floor(box.maxY);y++)
        for(int x=Mth.floor(box.minX);x<=Mth.floor(box.maxX);x++){
          var pos=new BlockPos(x,y,z);var state=probe.cell(pos);
          if(!touchable(state))continue;
          if(state.getBlock() instanceof TripWireBlock&&!state.getShape(probe,pos).bounds().move(pos).intersects(box))continue;
          state.entityInside(probe,pos,entity,null,true);
        }
    }
  }

  static final class Mth{static int floor(double v){return net.minecraft.util.Mth.floor(v);}}

  static void scenes(String out,int sceneCount,long seed)throws Exception{
    var lookup=MiningToolOracle.initialize();var probe=probe(lookup);var random=new Random(seed);
    Method tickBlock=ServerLevel.class.getDeclaredMethod("tickBlock",BlockPos.class,Block.class);tickBlock.setAccessible(true);
    var crossField=RedStoneWire.crossField();var cross=(BlockState)crossField.get(Blocks.REDSTONE_WIRE);
    var connection=RedstoneWireBlock.class.getDeclaredMethod("getConnectionState",BlockGetter.class,BlockState.class,BlockPos.class);
    connection.setAccessible(true);
    var daylight=DaylightDetectorBlock.class.getDeclaredMethod("updateSignalStrength",BlockState.class,Level.class,BlockPos.class);
    daylight.setAccessible(true);
    var targetOutput=TargetBlock.class.getDeclaredMethod("setOutputPower",net.minecraft.world.level.LevelAccessor.class,BlockState.class,int.class,BlockPos.class,int.class);
    targetOutput.setAccessible(true);
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");unsafeField.setAccessible(true);
    var user=(User)((sun.misc.Unsafe)unsafeField.get(null)).allocateInstance(User.class);
    var abilitiesField=Player.class.getDeclaredField("abilities");abilitiesField.setAccessible(true);
    var abilities=new Abilities();abilitiesField.set(user,abilities);
    var stone=Blocks.STONE.defaultBlockState();var scenes=new JsonArray();
    var tally=new TreeMap<String,Integer>();
    // Torches' recent toggles are per level, which every scene reuses.
    var togglesField=RedstoneTorchBlock.class.getDeclaredField("RECENT_TOGGLES");togglesField.setAccessible(true);
    var toggles=(Map<?,?>)togglesField.get(null);
    for(int s=0;s<sceneCount;s++){
      long levelSeed=random.nextLong();setRandom(probe,RandomSource.create(levelSeed));
      probe.time=0;probe.subTick=0;probe.bodies.clear();toggles.clear();
      probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
      if(random.nextInt(8)==0)probe.rules.set(GameRules.TNT_EXPLODES,false,null);
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-16)>>4;cx<=(MAX_X+16)>>4;cx++)for(int cz=(MIN_Z-16)>>4;cz<=(MAX_Z+16)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      probe.cells=new HashMap<>();probe.entities=new HashMap<>();var cells=new JsonArray();
      for(int x=MIN_X-2;x<MAX_X+2;x++)for(int z=MIN_Z-2;z<MAX_Z+2;z++){
        var floor=new BlockPos(x,FLOOR_Y,z);probe.cells.put(floor,stone);cells.add(row(floor,Block.getId(stone)));
      }
      // Scripted actions: a lever-driven torch toggled fast enough to burn out, and a tripwire line.
      var scripted=new TreeMap<Integer,List<JsonArray>>();
      if(s%4==0){
        int x=MIN_X+random.nextInt(MAX_X-MIN_X),z=MIN_Z+random.nextInt(MAX_Z-MIN_Z),t0=random.nextInt(30);
        var block=new BlockPos(x,FLOOR_Y+1,z);var lever=block.west();
        scripted.computeIfAbsent(t0,k->new ArrayList<>()).add(action("set",block,Block.getId(stone)));
        scripted.computeIfAbsent(t0,k->new ArrayList<>()).add(action("set",block.above(),Block.getId(Blocks.REDSTONE_TORCH.defaultBlockState())));
        scripted.computeIfAbsent(t0,k->new ArrayList<>()).add(action("set",lever,Block.getId(Blocks.LEVER.defaultBlockState()
          .setValue(LeverBlock.FACE,AttachFace.WALL).setValue(LeverBlock.FACING,Direction.WEST))));
        for(int t=t0+1;t<t0+80;t+=3)scripted.computeIfAbsent(t,k->new ArrayList<>()).add(action("use",lever,4,1));
      }
      if(s%3==1){
        int x=MIN_X+random.nextInt(2),z=MIN_Z+1+random.nextInt(MAX_Z-MIN_Z-2),t0=random.nextInt(20);
        var a=new BlockPos(x,FLOOR_Y+1,z);var b=a.east(5);
        var sets=new ArrayList<JsonArray>();
        sets.add(action("set",a,Block.getId(stone)));sets.add(action("set",b,Block.getId(stone)));
        sets.add(action("set",a.east(),Block.getId(Blocks.TRIPWIRE_HOOK.defaultBlockState().setValue(TripWireHookBlock.FACING,Direction.EAST))));
        sets.add(action("placed",a.east()));
        sets.add(action("set",b.west(),Block.getId(Blocks.TRIPWIRE_HOOK.defaultBlockState().setValue(TripWireHookBlock.FACING,Direction.WEST))));
        sets.add(action("placed",b.west()));
        scripted.computeIfAbsent(t0,k->new ArrayList<>()).addAll(sets);
        for(int i=2;i<=3;i++)scripted.computeIfAbsent(t0+1+i,k->new ArrayList<>()).add(action("wire",a.east(i)));
        int t1=t0+10+random.nextInt(30);var over=a.east(2+random.nextInt(2));
        scripted.computeIfAbsent(t1,k->new ArrayList<>()).add(action("entity",over,over.getX()+0.2,over.getY(),over.getZ()+0.2,
          over.getX()+0.8,over.getY()+1.8,over.getZ()+0.8,1,t1+5+random.nextInt(30)));
      }
      if(s%5==2)repeaterChain(random,scripted);
      if(s%5==3)comparatorClock(random,scripted);
      if(s%5==4)observerPair(random,scripted);
      if(s%5==0)priorityRace(random,scripted);
      var steps=new JsonArray();
      for(int t=0;t<TICKS;t++){
        probe.time=t;probe.writes=new JsonArray();probe.events=new JsonArray();probe.sounds=new JsonArray();
        probe.blockEvents=new JsonArray();probe.primed=new JsonArray();var results=new JsonArray();
        var outputsBefore=outputs(probe);
        var now=new ArrayList<JsonArray>(scripted.getOrDefault(t,List.of()));
        final int tick=t;probe.bodies.removeIf(b->b.until()<=tick);
        // `ServerLevel.tick`: the due block ticks.
        probe.blockTicks.tick(t,65536,(pos,block)->{
          try{tickBlock.invoke(probe,pos,block);}catch(Exception e){throw new RuntimeException(e);}
        });
        if(probe.fluidTicks.count()>0)throw new AssertionError("fluid ticks in a redstone scene");
        // Daylight detectors' block entities, every twentieth tick.
        JsonArray day=null;
        if(t%20==0){
          probe.darken=random.nextInt(16);float angle=random.nextFloat()*360.0F;
          probe.attributes=EnvironmentAttributeSystem.builder()
            .addConstantLayer(EnvironmentAttributeMap.builder().set(EnvironmentAttributes.SUN_ANGLE,angle).build()).build();
          day=new JsonArray();day.add(probe.darken);day.add(Float.floatToIntBits(angle));
          for(var pos:cellsWhere(probe,st->st.is(Blocks.DAYLIGHT_DETECTOR)))daylight.invoke(null,probe.cell(pos),probe,pos);
        }
        // Random actions while the scene is active.
        if(t<ACTIVE)for(int n=random.nextInt(3);n>0;n--){
          int roll=random.nextInt(100);
          var pos=new BlockPos(MIN_X+random.nextInt(MAX_X-MIN_X),FLOOR_Y+(random.nextInt(4)==0?0:1+random.nextInt(3)),MIN_Z+random.nextInt(MAX_Z-MIN_Z));
          if(roll<55){
            var state=pick(random,probe,pos,cross,connection);
            if(random.nextInt(8)==0){
              var door=(random.nextBoolean()?Blocks.IRON_DOOR:Blocks.OAK_DOOR).defaultBlockState().setValue(DoorBlock.FACING,any(random,List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST)))
                .setValue(DoorBlock.HINGE,random.nextBoolean()?DoorHingeSide.LEFT:DoorHingeSide.RIGHT);
              now.add(action("set",pos,Block.getId(door.setValue(DoorBlock.HALF,DoubleBlockHalf.LOWER))));
              now.add(action("set",pos.above(),Block.getId(door.setValue(DoorBlock.HALF,DoubleBlockHalf.UPPER))));
            }else{
              now.add(action("set",pos,Block.getId(state)));
              if((state.is(Blocks.TRIPWIRE_HOOK)||state.getBlock() instanceof DiodeBlock)&&random.nextBoolean())now.add(action("placed",pos));
            }
          }else if(roll<75){
            var candidates=cellsWhere(probe,RedstoneOracle::usable);
            if(!candidates.isEmpty())now.add(action("use",any(random,candidates),random.nextInt(4)+2,random.nextInt(5)==0?0:1));
          }else if(roll<88){
            var candidates=cellsWhere(probe,RedstoneOracle::touchable);
            var at=!candidates.isEmpty()&&random.nextInt(4)!=0?any(random,candidates):pos;
            int kind=random.nextInt(3);double w=kind==1?0.6:kind==0?0.25:0.5,h=kind==1?1.8:kind==0?0.25:0.5;
            double cx=at.getX()+0.5+(random.nextDouble()-0.5)*0.8,cz=at.getZ()+0.5+(random.nextDouble()-0.5)*0.8;
            double y=at.getY()+any(random,List.of(0.0,0.03125,0.0625,0.5));
            now.add(action("entity",at,cx-w/2,y,cz-w/2,cx+w/2,y+h,cz+w/2,kind,t+1+random.nextInt(50)));
          }else if(roll<90){
            var candidates=cellsWhere(probe,st->st.is(Blocks.LECTERN));
            if(!candidates.isEmpty())now.add(action("page",any(random,candidates)));
          }else if(roll<94){
            var candidates=cellsWhere(probe,RedstoneOracle::entityBlock);
            candidates.removeIf(c->probe.cell(c).is(Blocks.COMPARATOR));
            if(!candidates.isEmpty())now.add(action("fill",any(random,candidates),0));
          }else if(roll<97){
            var candidates=cellsWhere(probe,st->st.is(Blocks.TARGET));
            if(!candidates.isEmpty())now.add(action("hit",any(random,candidates),1+random.nextInt(15),random.nextInt(2)));
          }else{
            var candidates=cellsWhere(probe,st->st.is(Blocks.TRIPWIRE));
            if(!candidates.isEmpty())now.add(action("disarm",any(random,candidates)));
          }
        }
        for(var a:now){
          var pos=new BlockPos(a.get(1).getAsInt(),a.get(2).getAsInt(),a.get(3).getAsInt());
          switch(a.get(0).getAsString()){
            case "set"->probe.setBlock(pos,Block.stateById(a.get(4).getAsInt()),Block.UPDATE_ALL);
            case "dust"->{
              var state=(BlockState)connection.invoke(Blocks.REDSTONE_WIRE,probe,cross,pos);
              a.set(0,new JsonPrimitive("set"));a.add(Block.getId(state));
              probe.setBlock(pos,state,Block.UPDATE_ALL);
            }
            case "fill"->{
              if(probe.entities.get(pos) instanceof net.minecraft.world.level.block.entity.BaseContainerBlockEntity){
                var filled=fill(random,probe,pos);a.set(4,filled.get(4));a.add(filled.get(5));a.add(filled.get(6));
              }else{a.set(4,new JsonPrimitive(-1));a.add(new JsonArray());a.add(0);}
            }
            case "wire"->{
              var state=tripwire(probe,pos);
              a.set(0,new JsonPrimitive("set"));a.add(Block.getId(state));
              probe.setBlock(pos,state,Block.UPDATE_ALL);
            }
            case "placed"->{
              var st=probe.cell(pos);
              if(st.is(Blocks.TRIPWIRE_HOOK)||st.getBlock() instanceof DiodeBlock)st.getBlock().setPlacedBy(probe,pos,st,null,net.minecraft.world.item.ItemStack.EMPTY);
            }
            case "use"->{
              var facing=Direction.from3DDataValue(a.get(4).getAsInt());abilities.mayBuild=a.get(5).getAsInt()==1;
              user.setYRot(facing.toYRot());
              // A scripted use of a cell a random set replaced passes (`useWithoutItem`'s default).
              var used=usable(probe.cell(pos))&&probe.cell(pos).useWithoutItem(probe,user,new BlockHitResult(Vec3.atCenterOf(pos),Direction.UP,pos,false)).consumesAction();
              results.add(used?1:0);
            }
            case "entity"->{
              var box=new AABB(a.get(4).getAsDouble(),a.get(5).getAsDouble(),a.get(6).getAsDouble(),a.get(7).getAsDouble(),a.get(8).getAsDouble(),a.get(9).getAsDouble());
              probe.bodies.add(new Body(box,a.get(10).getAsInt(),a.get(11).getAsInt()));
            }
            case "page"->{var st=probe.cell(pos);if(st.is(Blocks.LECTERN))LecternBlock.signalPageChange(probe,pos,st);}
            case "hit"->{
              var st=probe.cell(pos);
              if(st.is(Blocks.TARGET)&&!probe.getBlockTicks().hasScheduledTick(pos,Blocks.TARGET))
                targetOutput.invoke(null,probe,st,a.get(4).getAsInt(),pos,a.get(5).getAsInt()==1?20:8);
            }
            case "disarm"->{var st=probe.cell(pos);if(st.is(Blocks.TRIPWIRE))probe.setBlock(pos,st.setValue(TripWireBlock.DISARMED,true),260);}
            default->throw new AssertionError(a);
          }
        }
        contacts(probe);
        // The comparators whose output changed over the tick (a new one's from 0).
        var outputChanges=new JsonArray();
        var outputsAfter=new TreeMap<BlockPos,Integer>(outputs(probe));
        for(var e:outputsAfter.entrySet())if(e.getValue()!=(int)outputsBefore.getOrDefault(e.getKey(),0)){
          outputChanges.add(row(e.getKey(),e.getValue()));tally.merge("comparator outputs",1,Integer::sum);
        }
        for(var a:now)if(a.get(0).getAsString().equals("fill"))tally.merge("fills",1,Integer::sum);
        for(var w:probe.writes){
          var written=Block.stateById(w.getAsJsonArray().get(3).getAsInt());
          if(written.is(Blocks.REDSTONE_LAMP)&&written.getValue(RedstoneLampBlock.LIT))tally.merge("lamps lit",1,Integer::sum);
          if(written.getBlock() instanceof DoorBlock&&written.getValue(DoorBlock.POWERED))tally.merge("doors powered",1,Integer::sum);
          if(written.getBlock() instanceof TrapDoorBlock&&written.getValue(TrapDoorBlock.POWERED))tally.merge("trapdoors powered",1,Integer::sum);
          if(written.getBlock() instanceof FenceGateBlock&&written.getValue(FenceGateBlock.POWERED))tally.merge("gates powered",1,Integer::sum);
          if(written.getBlock() instanceof BasePressurePlateBlock&&!written.equals(written.getBlock().defaultBlockState()))tally.merge("plates pressed",1,Integer::sum);
          if(written.is(Blocks.TRIPWIRE_HOOK)&&written.getValue(TripWireHookBlock.POWERED))tally.merge("hooks powered",1,Integer::sum);
          if(written.is(Blocks.DAYLIGHT_DETECTOR)&&written.getValue(DaylightDetectorBlock.POWER)>0)tally.merge("detectors powered",1,Integer::sum);
          if(written.is(Blocks.REDSTONE_WIRE)&&written.getValue(RedstoneWireBlock.POWER)>0)tally.merge("wire powered",1,Integer::sum);
          if(written.is(Blocks.REPEATER)&&written.getValue(RepeaterBlock.POWERED))tally.merge("repeaters powered",1,Integer::sum);
          if(written.is(Blocks.REPEATER)&&written.getValue(RepeaterBlock.LOCKED))tally.merge("repeaters locked",1,Integer::sum);
          if(written.is(Blocks.COMPARATOR)&&written.getValue(ComparatorBlock.POWERED))tally.merge("comparators powered",1,Integer::sum);
          if(written.is(Blocks.OBSERVER)&&written.getValue(ObserverBlock.POWERED))tally.merge("observers powered",1,Integer::sum);
        }
        for(var e:probe.events)if(e.getAsJsonArray().get(3).getAsInt()==1502)tally.merge("burnouts",1,Integer::sum);
        tally.merge("note events",probe.blockEvents.size(),Integer::sum);tally.merge("primed",probe.primed.size(),Integer::sum);
        tally.merge("sounds",probe.sounds.size(),Integer::sum);tally.merge("writes",probe.writes.size(),Integer::sum);
        if(!now.isEmpty()||day!=null||!probe.writes.isEmpty()||!probe.events.isEmpty()||!probe.sounds.isEmpty()||!probe.blockEvents.isEmpty()
            ||!outputChanges.isEmpty()){
          var step=new JsonObject();step.addProperty("t",t);
          var acts=new JsonArray();now.forEach(acts::add);step.add("actions",acts);
          if(day!=null)step.add("day",day);
          step.add("results",results);step.add("writes",probe.writes);step.add("events",probe.events);step.add("sounds",probe.sounds);
          step.add("block_events",probe.blockEvents);step.add("primed",probe.primed);step.add("outputs",outputChanges);steps.add(step);
        }
      }
      var scene=new JsonObject();scene.addProperty("seed",levelSeed);scene.addProperty("tnt_explodes",probe.rules.get(GameRules.TNT_EXPLODES));
      scene.add("cells",cells);scene.add("steps",steps);scenes.add(scene);
    }
    var result=new JsonObject();result.add("scenes",scenes);
    Files.writeString(Path.of(out),new GsonBuilder().disableHtmlEscaping().create().toJson(result)+"\n");
    for(var key:List.of("lamps lit","doors powered","trapdoors powered","gates powered","plates pressed","hooks powered","detectors powered","burnouts","note events","primed",
        "repeaters powered","repeaters locked","comparators powered","observers powered","comparator outputs","fills"))
      if(tally.getOrDefault(key,0)<(key.equals("burnouts")||key.equals("hooks powered")?5:20))throw new AssertionError("thin scenes: "+tally);
    System.out.println("PASS: "+sceneCount+" redstone scenes of "+TICKS+" ticks; "+tally);
  }

  static void at(TreeMap<Integer,List<JsonArray>> scripted,int t,JsonArray a){scripted.computeIfAbsent(t,k->new ArrayList<>()).add(a);}

  static int id(BlockState state){return Block.getId(state);}

  /**
   * A lever, a line of repeaters with random delays east across x 128 into a lamp, and a lever
   * behind a repeater beside the line that locks one of them; both levers toggled now and then.
   */
  static void repeaterChain(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int z=MIN_Z+random.nextInt(MAX_Z-MIN_Z),y=FLOOR_Y+1,t0=random.nextInt(20),lockX=MIN_X+1+random.nextInt(4);
    var lever=Blocks.LEVER.defaultBlockState().setValue(LeverBlock.FACE,AttachFace.FLOOR);
    at(scripted,t0,action("set",new BlockPos(MIN_X-1,y,z),id(lever)));
    for(int x=MIN_X;x<MAX_X;x++){
      var pos=new BlockPos(x,y,z);
      at(scripted,t0,action("set",pos,id(Blocks.REPEATER.defaultBlockState().setValue(RepeaterBlock.FACING,Direction.WEST)
        .setValue(RepeaterBlock.DELAY,1+random.nextInt(4)))));
      at(scripted,t0,action("placed",pos));
    }
    at(scripted,t0,action("set",new BlockPos(MAX_X,y,z),id(Blocks.REDSTONE_LAMP.defaultBlockState())));
    at(scripted,t0,action("set",new BlockPos(lockX,y,z+1),id(Blocks.REPEATER.defaultBlockState().setValue(RepeaterBlock.FACING,Direction.SOUTH))));
    at(scripted,t0,action("set",new BlockPos(lockX,y,z+2),id(lever)));
    for(int t=t0+2+random.nextInt(10);t<TICKS-5;t+=4+random.nextInt(22))at(scripted,t,action("use",new BlockPos(MIN_X-1,y,z),4,1));
    for(int t=t0+20+random.nextInt(30);t<TICKS-5;t+=25+random.nextInt(40))at(scripted,t,action("use",new BlockPos(lockX,y,z+2),2,1));
  }

  /**
   * A subtract-mode comparator clock fed by a redstone block (its wire runs back into its side),
   * and a comparator reading a chest through a stone block into a lamp, the chest refilled now and then.
   */
  static void comparatorClock(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int y=FLOOR_Y+1,z=MIN_Z+random.nextInt(MAX_Z-MIN_Z+1),x=MIN_X+random.nextInt(4),t0=random.nextInt(20);
    var clock=new BlockPos(x,y,z);
    at(scripted,t0,action("set",clock,id(Blocks.COMPARATOR.defaultBlockState().setValue(ComparatorBlock.FACING,Direction.WEST)
      .setValue(ComparatorBlock.MODE,ComparatorMode.SUBTRACT))));
    at(scripted,t0,action("placed",clock));
    for(var wire:List.of(clock.east(),clock.east().south(),clock.south(),clock.east(2)))at(scripted,t0+1,action("dust",wire));
    at(scripted,t0+3,action("set",clock.west(),id(Blocks.REDSTONE_BLOCK.defaultBlockState())));
    at(scripted,t0+90+random.nextInt(40),action("set",clock.west(),id(Blocks.STONE.defaultBlockState())));
    int r=MIN_X+random.nextInt(5);var reader=new BlockPos(r,y,z-2);
    at(scripted,t0,action("set",reader.west(2),id(Blocks.CHEST.defaultBlockState().setValue(ChestBlock.FACING,Direction.NORTH))));
    at(scripted,t0,action("set",reader.west(),id(Blocks.STONE.defaultBlockState())));
    at(scripted,t0,action("set",reader,id(Blocks.COMPARATOR.defaultBlockState().setValue(ComparatorBlock.FACING,Direction.WEST))));
    at(scripted,t0,action("set",reader.east(),id(Blocks.REDSTONE_LAMP.defaultBlockState())));
    for(int t=t0+2+random.nextInt(8);t<TICKS-5;t+=6+random.nextInt(20))at(scripted,t,action("fill",reader.west(2),0));
  }

  /**
   * A race of tick priorities: a repeater turning off (very high) and one turning on (high, its
   * front wire) due the same tick, the second scheduled first; the second's wire feeds the first.
   * Lever A powers the wire behind repeater M; lever B is behind repeater N, whose front is that
   * wire. Each round turns A on, then B on and A off in one tick, then B off.
   */
  static void priorityRace(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int y=FLOOR_Y+1,z=MIN_Z+random.nextInt(MAX_Z-MIN_Z),x=MIN_X+random.nextInt(5),t0=random.nextInt(20);
    var lever=Blocks.LEVER.defaultBlockState().setValue(LeverBlock.FACE,AttachFace.FLOOR);
    var wire=new BlockPos(x,y,z);var leverA=wire.west();var leverB=wire.south(2);
    at(scripted,t0,action("set",leverA,id(lever)));
    at(scripted,t0,action("set",wire.east(),id(Blocks.REPEATER.defaultBlockState().setValue(RepeaterBlock.FACING,Direction.WEST))));
    at(scripted,t0,action("set",wire.east(2),id(Blocks.REDSTONE_LAMP.defaultBlockState())));
    at(scripted,t0,action("set",wire.south(),id(Blocks.REPEATER.defaultBlockState().setValue(RepeaterBlock.FACING,Direction.SOUTH))));
    at(scripted,t0,action("set",leverB,id(lever)));
    at(scripted,t0+1,action("dust",wire));
    for(int t=t0+5;t+25<TICKS;t+=30+random.nextInt(10)){
      at(scripted,t,action("use",leverA,4,1));
      at(scripted,t+10,action("use",leverB,2,1));
      at(scripted,t+10,action("use",leverA,4,1));
      at(scripted,t+20,action("use",leverB,2,1));
    }
  }

  /** Two observers facing each other (a clock) between two lamps, broken after a while. */
  static void observerPair(Random random,TreeMap<Integer,List<JsonArray>> scripted){
    int y=FLOOR_Y+1+random.nextInt(2),z=MIN_Z+random.nextInt(MAX_Z-MIN_Z),x=MIN_X+random.nextInt(4),t0=random.nextInt(30);
    var a=new BlockPos(x,y,z);
    at(scripted,t0,action("set",a.west(),id(Blocks.REDSTONE_LAMP.defaultBlockState())));
    at(scripted,t0,action("set",a.east(2),id(Blocks.REDSTONE_LAMP.defaultBlockState())));
    at(scripted,t0+1,action("set",a,id(Blocks.OBSERVER.defaultBlockState().setValue(ObserverBlock.FACING,Direction.EAST))));
    at(scripted,t0+1,action("set",a.east(),id(Blocks.OBSERVER.defaultBlockState().setValue(ObserverBlock.FACING,Direction.WEST))));
    at(scripted,t0+40+random.nextInt(60),action("set",a.east(),id(Blocks.AIR.defaultBlockState())));
  }

  static final class RedStoneWire{
    static Field crossField()throws Exception{var f=RedstoneWireBlock.class.getDeclaredField("crossState");f.setAccessible(true);return f;}
  }
}
