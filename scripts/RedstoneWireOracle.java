import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.ReloadableServerRegistries;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.*;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.redstone.CollectingNeighborUpdater;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.ticks.LevelTicks;
import net.minecraft.world.ticks.TickPriority;

/**
 * Redstone wire's block updates (VMC-077m): random scenes over a stone floor, each a series of
 * `Level.setBlock(pos, state, UPDATE_ALL)` calls that vanilla's own `CollectingNeighborUpdater`,
 * `RedstoneWireBlock` with its default evaluator, and the signal sources' hooks run over a probe
 * level. The probe keeps cells in a map and runs `Level.setBlock` with `LevelChunk.setBlockState`'s
 * hooks (`affectNeighborsAfterRemoval`, then `onPlace`), without light, heightmaps or clients.
 * Each call records every cell write in order, the blocks broken with particles (level event
 * 2001) and the ticks scheduled. Wire takes the state a player places (`getStateForPlacement`);
 * the other states (stone, glass, slabs, redstone blocks, torches, levers, buttons, pressure
 * plates, air) are set as `/setblock` sets them. The run fails unless its scenes power wire,
 * pop wire off and break blocks by their shape updates often enough.
 * Usage: RedstoneWireOracle OUT.json [SCENES [ACTIONS [SEED]]]
 */
public class RedstoneWireOracle {
  static final int FLOOR_Y=63,FLOOR_MIN=-3,FLOOR_MAX=8,SIZE=6;

  static class Server extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Server server;RandomSource random;LevelTicks<Block> blockTicks;
    JsonArray writes,breaks,ticks;
    private Probe(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    BlockState cell(BlockPos pos){return cells.getOrDefault(pos,Blocks.AIR.defaultBlockState());}
    @Override public BlockState getBlockState(BlockPos pos){return cell(pos);}
    @Override public FluidState getFluidState(BlockPos pos){return cell(pos).getFluidState();}
    @Override public int getMinY(){return -64;}
    @Override public int getHeight(){return 384;}
    @Override public MinecraftServer getServer(){return server;}
    @Override public RandomSource getRandom(){return random;}
    @Override public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    @Override public LevelTicks<Block> getBlockTicks(){return blockTicks;}
    @Override public void levelEvent(Entity source,int type,BlockPos pos,int data){if(type==2001)breaks.add(row(pos,data));}
    @Override public void gameEvent(Holder<GameEvent> event,Vec3 at,GameEvent.Context context){}
    @Override public boolean addFreshEntity(Entity entity){return false;}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay){ticks.add(row(pos,BuiltInRegistries.BLOCK.getId(block),delay));}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay,TickPriority priority){scheduleTick(pos,block,delay);}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay){throw new AssertionError("fluid tick "+pos);}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay,TickPriority priority){scheduleTick(pos,fluid,delay);}

    /** `Level.setBlock` with `LevelChunk.setBlockState`'s hooks, over the map. */
    @Override public boolean setBlock(BlockPos pos,BlockState state,int flags,int limit){
      if(isOutsideBuildHeight(pos))return false;
      pos=pos.immutable();var old=cell(pos);
      if(old==state)return false;
      cells.put(pos,state);writes.add(row(pos,Block.getId(state)));
      var block=state.getBlock();
      if(!old.is(block)&&(flags&1)!=0)old.affectNeighborsAfterRemoval(this,pos,false);
      if(!cell(pos).is(block))return false;
      if((flags&512)==0)state.onPlace(this,pos,old,false);
      if(cell(pos)!=state)return true;
      if((flags&1)!=0){
        updateNeighborsAt(pos,old.getBlock());
        if(state.hasAnalogOutputSignal())throw new AssertionError("analog output "+state);
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

  static JsonArray row(BlockPos pos,int... values){
    var row=new JsonArray();row.add(pos.getX());row.add(pos.getY());row.add(pos.getZ());
    for(int v:values)row.add(v);
    return row;
  }

  static <T> T any(Random random,List<T> values){return values.get(random.nextInt(values.size()));}

  /** A state to set at `pos`: wire as a player places it, the others as `/setblock` sets them. */
  static BlockState pick(Random random,Probe probe,BlockPos pos,BlockState cross,java.lang.reflect.Method connection)throws Exception{
    var horizontal=List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST);
    var faces=List.of(AttachFace.FLOOR,AttachFace.WALL,AttachFace.CEILING);
    int roll=random.nextInt(100);
    if(roll<30)return (BlockState)connection.invoke(Blocks.REDSTONE_WIRE,probe,cross,pos);
    if(roll<42)return Blocks.AIR.defaultBlockState();
    if(roll<52)return Blocks.STONE.defaultBlockState();
    if(roll<56)return Blocks.GLASS.defaultBlockState();
    if(roll<64)return Blocks.STONE_SLAB.defaultBlockState().setValue(SlabBlock.TYPE,roll<60?SlabType.BOTTOM:SlabType.TOP);
    if(roll<70)return Blocks.REDSTONE_BLOCK.defaultBlockState();
    if(roll<76)return Blocks.REDSTONE_TORCH.defaultBlockState();
    if(roll<80)return Blocks.REDSTONE_WALL_TORCH.defaultBlockState().setValue(RedstoneWallTorchBlock.FACING,any(random,horizontal));
    if(roll<88)return Blocks.LEVER.defaultBlockState().setValue(LeverBlock.FACE,any(random,faces))
      .setValue(LeverBlock.FACING,any(random,horizontal)).setValue(LeverBlock.POWERED,random.nextBoolean());
    if(roll<93)return Blocks.STONE_BUTTON.defaultBlockState().setValue(ButtonBlock.FACE,any(random,faces))
      .setValue(ButtonBlock.FACING,any(random,horizontal)).setValue(ButtonBlock.POWERED,random.nextBoolean());
    if(roll<97)return Blocks.STONE_PRESSURE_PLATE.defaultBlockState().setValue(PressurePlateBlock.POWERED,random.nextBoolean());
    return Blocks.HEAVY_WEIGHTED_PRESSURE_PLATE.defaultBlockState().setValue(WeightedPressurePlateBlock.POWER,random.nextInt(16));
  }

  public static void main(String[] args)throws Exception{
    var lookup=MiningToolOracle.initialize();
    int sceneCount=args.length>1?Integer.parseInt(args[1]):240,actionCount=args.length>2?Integer.parseInt(args[2]):48;
    long seed=args.length>3?Long.parseLong(args[3]):77_013L;
    var theUnsafe=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");theUnsafe.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)theUnsafe.get(null);
    var server=(Server)unsafe.allocateInstance(Server.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var probe=(Probe)unsafe.allocateInstance(Probe.class);probe.server=server;probe.random=RandomSource.create(seed);
    probe.blockTicks=new LevelTicks<>(p->true);
    var updater=Level.class.getDeclaredField("neighborUpdater");updater.setAccessible(true);
    updater.set(probe,new CollectingNeighborUpdater(probe,1_000_000));
    var crossField=RedstoneWireBlock.class.getDeclaredField("crossState");crossField.setAccessible(true);
    var cross=(BlockState)crossField.get(Blocks.REDSTONE_WIRE);
    var connection=RedstoneWireBlock.class.getDeclaredMethod("getConnectionState",BlockGetter.class,BlockState.class,BlockPos.class);
    connection.setAccessible(true);

    var random=new Random(seed);var floor=Blocks.STONE.defaultBlockState();var scenes=new JsonArray();
    int writes=0,breaks=0,ticks=0,powered=0,removed=0;
    for(int s=0;s<sceneCount;s++){
      probe.cells=new HashMap<>();
      for(int x=FLOOR_MIN;x<=FLOOR_MAX;x++)for(int z=FLOOR_MIN;z<=FLOOR_MAX;z++)probe.cells.put(new BlockPos(x,FLOOR_Y,z),floor);
      var actions=new JsonArray();
      for(int a=0;a<actionCount;a++){
        int y=random.nextInt(3)==0?FLOOR_Y:FLOOR_Y+1+random.nextInt(3);
        var pos=new BlockPos(random.nextInt(SIZE),y,random.nextInt(SIZE));
        var state=pick(random,probe,pos,cross,connection);
        probe.writes=new JsonArray();probe.breaks=new JsonArray();probe.ticks=new JsonArray();
        probe.setBlock(pos,state,Block.UPDATE_ALL);
        for(var w:probe.writes){
          var write=w.getAsJsonArray();var written=Block.stateById(write.get(3).getAsInt());
          if(written.is(Blocks.REDSTONE_WIRE)&&written.getValue(RedstoneWireBlock.POWER)>0)powered++;
          var at=new BlockPos(write.get(0).getAsInt(),write.get(1).getAsInt(),write.get(2).getAsInt());
          if(written.isAir()&&!at.equals(pos))removed++;
        }
        var action=new JsonObject();action.add("set",row(pos,Block.getId(state)));
        action.add("writes",probe.writes);action.add("breaks",probe.breaks);action.add("ticks",probe.ticks);
        writes+=probe.writes.size();breaks+=probe.breaks.size();ticks+=probe.ticks.size();
        actions.add(action);
      }
      scenes.add(actions);
    }
    if(powered<500||breaks<100||removed-breaks<20)throw new AssertionError("thin scenes: powered "+powered+", breaks "+breaks+", removed "+removed);
    var out=new JsonObject();
    var floorJson=new JsonObject();floorJson.addProperty("state",Block.getId(floor));floorJson.addProperty("y",FLOOR_Y);
    floorJson.addProperty("min",FLOOR_MIN);floorJson.addProperty("max",FLOOR_MAX);
    out.add("floor",floorJson);out.add("scenes",scenes);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out)+"\n");
    System.out.println("PASS: "+sceneCount+" redstone scenes of "+actionCount+" block changes; "+writes+" writes, "
      +powered+" powered wire writes, "+removed+" blocks removed by updates ("+breaks+" with particles), "+ticks+" ticks");
  }
}
