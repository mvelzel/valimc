import com.google.gson.*;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.registries.Registries;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.ReloadableServerRegistries;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.util.RandomSource;
import net.minecraft.world.attribute.EnvironmentAttributes;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.BucketItem;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.ClipContext;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.*;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.material.Fluids;
import net.minecraft.world.level.redstone.CollectingNeighborUpdater;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.CollisionContext;
import net.minecraft.world.phys.shapes.VoxelShape;
import net.minecraft.world.ticks.LevelChunkTicks;
import net.minecraft.world.ticks.LevelTicks;
import net.minecraft.world.ticks.ScheduledTick;
import net.minecraft.world.ticks.TickPriority;

/**
 * Water and lava (VMC-031a), from pinned 26.3. Four modes:
 *
 * - `facts OUT`: what the fluid rules read beyond the block fact table. `dimensions`: each
 *   dimension type's `fast_lava` and `water_evaporates` (no biome sets either); `game_rules`: the
 *   source conversion rules' defaults; `liquid`: per state a byte (hex), bit 0 a
 *   `LiquidBlockContainer`, bit f (1..4) its `canPlaceLiquid` (no user) for fluid registry id f,
 *   bit 5 `canBeReplaced(WATER)`, bit 6 `canBeReplaced(LAVA)`, bit 7 `ignitedByLava`; `waterlogs`: `(state, after)` u16
 *   pairs (hex), what `placeLiquid` with a water source sets, for every container that takes it
 *   (each also schedules its water tick); `pickups`: `(state, after, item)` (hex, u16, u16, u8)
 *   for every `BucketPickup` state whose `pickupBlock` (no user) returns an item: the state it
 *   sets first (a waterlogged block that cannot stand then breaks) and the item, an index into
 *   `pickup_items`.
 * - `outlines OUT`: per state its outline shape (`getShape` with an empty collision context, as
 *   a bucket's clip sees it): a palette of geometries (grid axes, sizes and filled cells, and the
 *   boxes `toAabbs` gives), per state its index (hex u16), and
 *   `offsets`, `[state, kind, horizontal, vertical]` for the states whose outline moves by their
 *   position offset (kind 1 XZ, 2 XYZ, with the block's largest offsets; their geometry is the
 *   outline at offset zero). Other offset blocks keep their outline in place.
 * - `clips OUT`: `BlockGetter.clip` with outline shapes and the fluid modes NONE and
 *   SOURCE_ONLY over random scenes of blocks and fluids: per ray its hit (or miss). Fluid shapes
 *   are first cached at their own heights (`FlowingFluid` keeps the first one it computes).
 *   `views`: `calculateViewVector` for random pitches and yaws.
 * - `scenes OUT [SCENES [SEED]]`: flow over a probe level whose block and fluid ticks are
 *   vanilla's own `LevelTicks`, run as `ServerLevel.tick` runs them (block ticks, then fluid
 *   ticks, each in drain order). Scenes straddle chunk and 8 x 8 chunk section lines. Each game
 *   tick first applies its actions (`/setblock`-style `setBlock(UPDATE_ALL)`, a water or lava
 *   bucket's `emptyContents` without a user or hit, a `BucketPickup.pickupBlock`, or a random tick
 *   of a lava cell as `ServerLevel.tickChunk` runs one: the block's, then its fluid's), then runs
 *   the due ticks; per tick the cell writes in order, the level events (1501 fizz, 2001 break)
 *   and each bucket's outcome (emptied, or the item picked up). Some scenes convert lava sources,
 *   keep water from converting or keep lava from lighting fires (`canSpreadFireAround`). Fire's
 *   own ticks do not run.
 *
 * Usage: FluidOracle (facts|outlines|clips|scenes) OUT [SCENES [SEED]]
 */
public class FluidOracle {
  static final int FLOOR_Y=60,BASE_Y=56,MIN_X=120,MAX_X=136,MIN_Z=-8,MAX_Z=8;

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Server server;RandomSource random;GameRules rules;
    LevelTicks<Block> blockTicks;LevelTicks<Fluid> fluidTicks;long time,subTick;boolean fireSpread;net.minecraft.world.attribute.EnvironmentAttributeSystem attributes;
    JsonArray writes=new JsonArray(),events=new JsonArray();
    private Probe(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    BlockState cell(BlockPos pos){return cells.getOrDefault(pos,Blocks.AIR.defaultBlockState());}
    @Override public BlockState getBlockState(BlockPos pos){return cell(pos);}
    @Override public FluidState getFluidState(BlockPos pos){return cell(pos).getFluidState();}
    @Override public BlockEntity getBlockEntity(BlockPos pos){return null;}
    @Override public int getMinY(){return -64;}
    @Override public int getHeight(){return 384;}
    @Override public MinecraftServer getServer(){return server;}
    @Override public RandomSource getRandom(){return random;}
    @Override public GameRules getGameRules(){return rules;}
    @Override public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    @Override public LevelTicks<Block> getBlockTicks(){return blockTicks;}
    @Override public LevelTicks<Fluid> getFluidTicks(){return fluidTicks;}
    @Override public boolean isClientSide(){return false;}
    @Override public boolean isLoaded(BlockPos pos){return !isOutsideBuildHeight(pos);}
    @Override public boolean hasChunkAt(BlockPos pos){return true;}
    @Override public boolean canSpreadFireAround(BlockPos pos){return fireSpread;}
    @Override public net.minecraft.world.attribute.EnvironmentAttributeSystem environmentAttributes(){return attributes;}
    @Override public void levelEvent(Entity source,int type,BlockPos pos,int data){events.add(row(pos,type,data));}
    @Override public void gameEvent(Holder<GameEvent> event,Vec3 at,GameEvent.Context context){}
    @Override public void gameEvent(Entity source,Holder<GameEvent> event,BlockPos pos){}
    @Override public void playSound(Entity except,BlockPos pos,SoundEvent sound,SoundSource source,float volume,float pitch){}
    @Override public boolean addFreshEntity(Entity entity){return false;}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay,TickPriority priority){
      blockTicks.schedule(new ScheduledTick<>(block,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Block block,int delay){scheduleTick(pos,block,delay,TickPriority.NORMAL);}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay,TickPriority priority){
      fluidTicks.schedule(new ScheduledTick<>(fluid,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay){scheduleTick(pos,fluid,delay,TickPriority.NORMAL);}

    /** `Level.setBlock` with `LevelChunk.setBlockState`'s hooks, over the map (as RedstoneWireOracle's). */
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
      if((flags&1)!=0)updateNeighborsAt(pos,old.getBlock());
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

  /** The jar's block tags (`MiningToolOracle.initialize`) and fluid tags, bound. */
  static HolderLookup.Provider initialize()throws Exception{
    var lookup=MiningToolOracle.initialize();
    try(var resources=new net.minecraft.server.packs.resources.MultiPackResourceManager(net.minecraft.server.packs.PackType.SERVER_DATA,
        List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=net.minecraft.tags.TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.FLUID.key(),(id,required)->BuiltInRegistries.FLUID.get(id));
      var memberships=new HashMap<Holder<Fluid>,List<net.minecraft.tags.TagKey<Fluid>>>();
      tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
      for(var fluid:BuiltInRegistries.FLUID)bind.invoke(fluid.builtInRegistryHolder(),memberships.getOrDefault(fluid.builtInRegistryHolder(),List.of()));
    }
    if(!Fluids.WATER.is(net.minecraft.tags.FluidTags.WATER))throw new AssertionError("fluid tags unbound");
    return lookup;
  }

  static Probe probe(long seed)throws Exception{
    var lookup=initialize();
    var theUnsafe=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");theUnsafe.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)theUnsafe.get(null);
    var server=(Server)unsafe.allocateInstance(Server.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var probe=(Probe)unsafe.allocateInstance(Probe.class);probe.server=server;probe.random=RandomSource.create(seed);
    probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);probe.cells=new HashMap<>();
    probe.writes=new JsonArray();probe.events=new JsonArray();
    var updater=Level.class.getDeclaredField("neighborUpdater");updater.setAccessible(true);
    updater.set(probe,new CollectingNeighborUpdater(probe,1_000_000));
    // Evaporating water sends particles to the level's (no) players.
    var players=ServerLevel.class.getDeclaredField("players");players.setAccessible(true);players.set(probe,new ArrayList<>());
    PROBE_LOOKUP=lookup;
    return probe;
  }
  static HolderLookup.Provider PROBE_LOOKUP;

  public static void main(String[] args)throws Exception{
    switch(args[0]){
      case "facts"->facts(args[1]);
      case "outlines"->outlines(args[1]);
      case "clips"->clips(args[1]);
      case "scenes"->scenes(args[1],args.length>2?Integer.parseInt(args[2]):160,args.length>3?Long.parseLong(args[3]):31_001L);
      default->throw new IllegalArgumentException(args[0]);
    }
  }

  static void facts(String out)throws Exception{
    var probe=probe(0);var origin=new BlockPos(0,64,0);int count=Block.BLOCK_STATE_REGISTRY.size();
    Fluid[] FLUIDS={Fluids.EMPTY,Fluids.FLOWING_WATER,Fluids.WATER,Fluids.FLOWING_LAVA,Fluids.LAVA};
    for(int f=0;f<FLUIDS.length;f++)if(BuiltInRegistries.FLUID.getId(FLUIDS[f])!=f)throw new AssertionError("fluid ids");
    var result=stamped(count);
    // Dimension attributes; no biome sets them.
    var dimensions=new JsonObject();
    var types=new ArrayList<>(PROBE_LOOKUP.lookupOrThrow(Registries.DIMENSION_TYPE).listElements().toList());
    types.sort(Comparator.comparing(entry->entry.key().identifier().toString()));
    for(var entry:types){
      var attributes=entry.value().attributes();var values=new JsonObject();
      values.addProperty("fast_lava",attributes.applyModifier(EnvironmentAttributes.FAST_LAVA,EnvironmentAttributes.FAST_LAVA.defaultValue()));
      values.addProperty("water_evaporates",attributes.applyModifier(EnvironmentAttributes.WATER_EVAPORATES,EnvironmentAttributes.WATER_EVAPORATES.defaultValue()));
      dimensions.add(entry.key().identifier().toString(),values);
    }
    for(var biome:PROBE_LOOKUP.lookupOrThrow(Registries.BIOME).listElements().toList()){
      var attributes=biome.value().getAttributes();
      if(attributes.contains(EnvironmentAttributes.FAST_LAVA)||attributes.contains(EnvironmentAttributes.WATER_EVAPORATES))
        throw new AssertionError("a biome sets a fluid attribute: "+biome.key());
    }
    result.add("dimensions",dimensions);
    var rules=new JsonObject();
    rules.addProperty("water_source_conversion",probe.rules.get(GameRules.WATER_SOURCE_CONVERSION));
    rules.addProperty("lava_source_conversion",probe.rules.get(GameRules.LAVA_SOURCE_CONVERSION));
    rules.addProperty("fire_spread_radius_around_player",probe.rules.get(GameRules.FIRE_SPREAD_RADIUS_AROUND_PLAYER));
    result.add("game_rules",rules);

    var liquid=new StringBuilder();var waterlogs=new StringBuilder();var pickups=new StringBuilder();
    var items=new ArrayList<String>();int containers=0,waterlogging=0,taken=0;
    for(int id=0;id<count;id++){
      var state=Block.stateById(id);var block=state.getBlock();
      int bits=(state.canBeReplaced(Fluids.WATER)?32:0)|(state.canBeReplaced(Fluids.LAVA)?64:0)|(state.ignitedByLava()?128:0);
      if(block instanceof LiquidBlockContainer container){
        bits|=1;containers++;
        for(int f=1;f<FLUIDS.length;f++)if(container.canPlaceLiquid(null,probe,origin,state,FLUIDS[f]))bits|=1<<f;
        probe.cells.clear();probe.cells.put(origin,state);
        probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(0,0),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(0,0),new LevelChunkTicks<>());
        if(container.placeLiquid(probe,origin,state,Fluids.WATER.getSource(false))){
          if(!probe.fluidTicks.hasScheduledTick(origin,Fluids.WATER))throw new AssertionError("placeLiquid without its tick "+state);
          waterlogs.append(String.format(Locale.ROOT,"%04x%04x",id,Block.getId(probe.cell(origin))));waterlogging++;
        }
      }
      liquid.append(String.format(Locale.ROOT,"%02x",bits));
      if(block instanceof BucketPickup pickup){
        probe.cells.clear();probe.cells.put(origin,state);probe.writes=new JsonArray();
        var item=pickup.pickupBlock(null,probe,origin,state);
        if(!item.isEmpty()){
          // What it sets first (a waterlogged block that cannot stand alone breaks after).
          int after=probe.writes.get(0).getAsJsonArray().get(3).getAsInt();
          var name=BuiltInRegistries.ITEM.getKey(item.getItem()).toString();
          if(!items.contains(name))items.add(name);
          pickups.append(String.format(Locale.ROOT,"%04x%04x%02x",id,after,items.indexOf(name)));taken++;
        }
      }
    }
    if(waterlogging<1000||taken<1000)throw new AssertionError("thin facts: "+waterlogging+" waterlogging, "+taken+" pickups");
    result.addProperty("liquid",liquid.toString());result.addProperty("waterlogs",waterlogs.toString());
    result.addProperty("pickups",pickups.toString());var names=new JsonArray();items.forEach(names::add);result.add("pickup_items",names);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    System.out.println("PASS: fluid facts for "+count+" states; "+containers+" liquid containers ("+waterlogging
      +" take water), "+taken+" bucket pickups, "+dimensions.size()+" dimension types");
  }

  static void outlines(String out)throws Exception{
    initialize();int count=Block.BLOCK_STATE_REGISTRY.size();
    var palette=new JsonArray();var indexes=new HashMap<String,Integer>();var hex=new StringBuilder();var moving=new JsonArray();
    var gson=new Gson();var maxH=BlockBehaviour.class.getDeclaredMethod("getMaxHorizontalOffset");maxH.setAccessible(true);
    var maxV=BlockBehaviour.class.getDeclaredMethod("getMaxVerticalOffset");maxV.setAccessible(true);
    var probe=new BlockPos(29,-3,-17);int offsets=0;
    for(int id=0;id<count;id++){
      var state=Block.stateById(id);var block=state.getBlock();
      var shape=state.getShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO,CollisionContext.empty());
      int kind=0;
      if(state.hasOffsetFunction()){
        // Most offset blocks keep their outline in place; the rest move it by the offset.
        var moved=state.getShape(EmptyBlockGetter.INSTANCE,probe,CollisionContext.empty());
        if(!near(moved.toAabbs(),shape.toAabbs())){
          var offset=state.getOffset(BlockPos.ZERO);var at=state.getOffset(probe);
          shape=shape.move(-offset.x,-offset.y,-offset.z);offsets++;kind=at.y!=0.0||offset.y!=0.0?2:1;
          if(!near(moved.toAabbs(),shape.move(at.x,at.y,at.z).toAabbs()))throw new AssertionError("outline not its offset base "+state);
        }
      }
      var geometry=BlockFactsOracle.geometry(shape);geometry.remove("full_block");
      var key=gson.toJson(geometry);Integer index=indexes.get(key);
      if(index==null){index=palette.size();indexes.put(key,index);palette.add(geometry);}
      hex.append(String.format(Locale.ROOT,"%04x",index));
      if(kind!=0){
        var entry=new JsonArray();entry.add(id);entry.add(kind);
        entry.add(((Float)maxH.invoke(block)).doubleValue());entry.add(((Float)maxV.invoke(block)).doubleValue());moving.add(entry);
      }
    }
    var result=stamped(count);result.add("palette",palette);result.addProperty("states",hex.toString());result.add("offsets",moving);
    Files.writeString(Path.of(out),gson.toJson(result)+"\n");
    System.out.println("PASS: outline shapes of "+count+" states in "+palette.size()+" geometries; "+offsets+" offset states");
  }

  /** A fact file's release stamps (`Valimc.Data.Facts`) and state count. */
  static JsonObject stamped(int count)throws Exception{
    var out=new JsonObject();var version=net.minecraft.SharedConstants.getCurrentVersion();
    out.addProperty("version",version.id());out.addProperty("data_version",version.dataVersion().version());
    out.addProperty("server_sha1",VersionMetadata.serverSha1());out.addProperty("state_count",count);
    return out;
  }

  static boolean near(List<net.minecraft.world.phys.AABB> a,List<net.minecraft.world.phys.AABB> b){
    if(a.size()!=b.size())return false;
    for(int i=0;i<a.size();i++){
      var p=a.get(i);var q=b.get(i);
      if(Math.abs(p.minX-q.minX)>1e-9||Math.abs(p.minY-q.minY)>1e-9||Math.abs(p.minZ-q.minZ)>1e-9
        ||Math.abs(p.maxX-q.maxX)>1e-9||Math.abs(p.maxY-q.maxY)>1e-9||Math.abs(p.maxZ-q.maxZ)>1e-9)return false;
    }
    return true;
  }

  /** Blocks a clip scene or flow scene draws from. */
  static BlockState pick(Random random,boolean scene){
    var horizontal=List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST);
    int roll=random.nextInt(110);boolean wet=random.nextInt(3)==0;
    if(roll<16)return Blocks.WATER.defaultBlockState();
    if(roll<22)return Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,1+random.nextInt(15));
    if(roll<32)return Blocks.LAVA.defaultBlockState();
    if(roll<36)return Blocks.LAVA.defaultBlockState().setValue(LiquidBlock.LEVEL,1+random.nextInt(15));
    if(roll<46)return Blocks.AIR.defaultBlockState();
    if(roll<54)return Blocks.STONE.defaultBlockState();
    if(roll<57)return Blocks.GLASS.defaultBlockState();
    if(roll<62)return Blocks.OAK_STAIRS.defaultBlockState().setValue(StairBlock.FACING,horizontal.get(random.nextInt(4)))
      .setValue(StairBlock.HALF,random.nextBoolean()?Half.TOP:Half.BOTTOM).setValue(StairBlock.WATERLOGGED,wet);
    if(roll<67){
      var type=SlabType.values()[random.nextInt(3)];
      return Blocks.OAK_SLAB.defaultBlockState().setValue(SlabBlock.TYPE,type).setValue(SlabBlock.WATERLOGGED,wet&&type!=SlabType.DOUBLE);
    }
    if(roll<71)return Blocks.OAK_FENCE.defaultBlockState().setValue(FenceBlock.WATERLOGGED,wet);
    if(roll<75)return Blocks.TORCH.defaultBlockState();
    if(roll<77)return Blocks.SOUL_SOIL.defaultBlockState();
    if(roll<81)return Blocks.BLUE_ICE.defaultBlockState();
    if(roll<83)return Blocks.OAK_TRAPDOOR.defaultBlockState().setValue(TrapDoorBlock.FACING,horizontal.get(random.nextInt(4)))
      .setValue(TrapDoorBlock.OPEN,random.nextBoolean()).setValue(TrapDoorBlock.HALF,random.nextBoolean()?Half.TOP:Half.BOTTOM)
      .setValue(TrapDoorBlock.WATERLOGGED,wet);
    if(roll<85)return Blocks.GLASS_PANE.defaultBlockState().setValue(IronBarsBlock.WATERLOGGED,wet);
    if(roll<87)return Blocks.SHORT_GRASS.defaultBlockState();
    if(roll<89)return Blocks.COBBLESTONE.defaultBlockState();
    if(roll<91)return Blocks.ICE.defaultBlockState();
    if(roll<93)return Blocks.LANTERN.defaultBlockState().setValue(LanternBlock.HANGING,random.nextBoolean()).setValue(LanternBlock.WATERLOGGED,wet);
    if(roll<95)return Blocks.SEAGRASS.defaultBlockState();
    if(roll<97)return Blocks.KELP.defaultBlockState();
    if(roll<99)return Blocks.POWDER_SNOW.defaultBlockState();
    if(roll<100)return Blocks.POINTED_DRIPSTONE.defaultBlockState().setValue(PointedDripstoneBlock.WATERLOGGED,wet);
    if(roll<102)return Blocks.MAGMA_BLOCK.defaultBlockState();
    if(roll<104)return Blocks.SOUL_SAND.defaultBlockState();
    if(roll<106)return Blocks.BUBBLE_COLUMN.defaultBlockState().setValue(BubbleColumnBlock.DRAG_DOWN,random.nextBoolean());
    if(roll<108)return Blocks.OAK_PLANKS.defaultBlockState();
    return Blocks.HAY_BLOCK.defaultBlockState();
  }

  static void clips(String out)throws Exception{
    var probe=probe(5);var random=new Random(31_002L);var scenes=new JsonArray();int hits=0,fluidHits=0;
    // `FlowingFluid` caches each fluid state's shape at the height of the first cell asked:
    // ask every state where no fluid stands above, so sources keep their own height.
    for(var fluidState:Fluid.FLUID_STATE_REGISTRY)fluidState.getShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO);
    for(int s=0;s<200;s++){
      probe.cells=new HashMap<>();var cells=new JsonArray();var placed=new ArrayList<BlockPos>();
      for(int i=0;i<60;i++){
        var pos=new BlockPos(random.nextInt(8)-4,60+random.nextInt(6),random.nextInt(8)-4);var state=pick(random,false);
        probe.cells.put(pos,state);cells.add(row(pos,Block.getId(state)));placed.add(pos);
      }
      var rays=new JsonArray();
      for(int r=0;r<20;r++){
        var from=new Vec3(random.nextDouble()*10-5,60+random.nextDouble()*7,random.nextDouble()*10-5);
        // Mostly toward a placed cell, past it.
        var target=placed.get(random.nextInt(placed.size()));
        var aim=new Vec3(target.getX()+random.nextDouble(),target.getY()+random.nextDouble(),target.getZ()+random.nextDouble());
        var to=random.nextInt(4)==0?from.add(random.nextGaussian()*3,random.nextGaussian()*3,random.nextGaussian()*3)
          :from.add(aim.subtract(from).scale(1.0+random.nextDouble()));
        boolean source=random.nextBoolean();
        var hit=probe.clip(new ClipContext(from,to,ClipContext.Block.OUTLINE,source?ClipContext.Fluid.SOURCE_ONLY:ClipContext.Fluid.NONE,CollisionContext.empty()));
        var ray=new JsonArray();for(double v:new double[]{from.x,from.y,from.z,to.x,to.y,to.z})ray.add(v);ray.add(source);
        ray.add(hit.getType()==HitResult.Type.MISS?0:1);
        ray.add(hit.getBlockPos().getX());ray.add(hit.getBlockPos().getY());ray.add(hit.getBlockPos().getZ());ray.add(hit.getDirection().ordinal());
        ray.add(hit.getLocation().x);ray.add(hit.getLocation().y);ray.add(hit.getLocation().z);
        if(hit.getType()!=HitResult.Type.MISS){hits++;if(!probe.cell(hit.getBlockPos()).getFluidState().isEmpty())fluidHits++;}
        rays.add(ray);
      }
      var scene=new JsonObject();scene.add("cells",cells);scene.add("rays",rays);scenes.add(scene);
    }
    if(hits<1500||fluidHits<300)throw new AssertionError("thin clips: "+hits+" hits, "+fluidHits+" in fluid cells");
    // `Entity.calculateViewVector`, which aims an item's clip.
    var views=new JsonArray();
    for(int i=0;i<2000;i++){
      float pitch=(float)(random.nextDouble()*180-90),yaw=(float)(random.nextDouble()*720-360);
      var v=net.minecraft.world.entity.Entity.calculateViewVector(pitch,yaw);
      var row=new JsonArray();row.add(pitch);row.add(yaw);row.add(v.x);row.add(v.y);row.add(v.z);views.add(row);
    }
    var result=new JsonObject();result.add("scenes",scenes);result.add("views",views);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    System.out.println("PASS: 4000 clips over 200 scenes; "+hits+" hits, "+fluidHits+" at fluid cells; 2000 view vectors");
  }

  static void scenes(String out,int sceneCount,long seed)throws Exception{
    var probe=probe(seed);var random=new Random(seed);
    Method tickBlock=ServerLevel.class.getDeclaredMethod("tickBlock",BlockPos.class,Block.class);tickBlock.setAccessible(true);
    Method tickFluid=ServerLevel.class.getDeclaredMethod("tickFluid",BlockPos.class,Fluid.class);tickFluid.setAccessible(true);
    var water=(BucketItem)Items.WATER_BUCKET;var lava=(BucketItem)Items.LAVA_BUCKET;
    var stone=Blocks.STONE.defaultBlockState();var scenes=new JsonArray();
    int writes=0,fires=0,columns=0,obsidian=0,cobble=0,stoneMade=0,basalt=0,sources=0,flowing=0,waterlogged=0,fizz=0,pickups=0,emptied=0;
    for(int s=0;s<sceneCount;s++){
      long levelSeed=random.nextLong();probe.random=RandomSource.create(levelSeed);
      var dimension=s%2==1?"minecraft:the_nether":"minecraft:overworld";probe.attributes=attributes(dimension);
      probe.time=0;probe.subTick=0;
      probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
      boolean waterConversion=random.nextInt(6)!=0,lavaConversion=random.nextInt(6)==0;
      probe.rules.set(GameRules.WATER_SOURCE_CONVERSION,waterConversion,null);
      probe.rules.set(GameRules.LAVA_SOURCE_CONVERSION,lavaConversion,null);
      probe.fireSpread=random.nextInt(6)!=0;
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-16)>>4;cx<=(MAX_X+16)>>4;cx++)for(int cz=(MIN_Z-16)>>4;cz<=(MAX_Z+16)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      probe.cells=new HashMap<>();var cells=new JsonArray();
      for(int x=MIN_X-8;x<MAX_X+8;x++)for(int z=MIN_Z-8;z<MAX_Z+8;z++){
        var base=new BlockPos(x,BASE_Y,z);probe.cells.put(base,stone);cells.add(row(base,Block.getId(stone)));
        if(x>=MIN_X&&x<MAX_X&&z>=MIN_Z&&z<MAX_Z&&random.nextInt(10)!=0){
          var floor=new BlockPos(x,FLOOR_Y,z);int kind=random.nextInt(24);
          var state=kind<2?Blocks.SOUL_SOIL.defaultBlockState():kind==2?Blocks.MAGMA_BLOCK.defaultBlockState()
            :kind==3?Blocks.SOUL_SAND.defaultBlockState():kind==4?Blocks.OAK_PLANKS.defaultBlockState():stone;
          probe.cells.put(floor,state);cells.add(row(floor,Block.getId(state)));
        }
      }
      // Basalt sites: soul soil in the floor beside blue ice.
      for(int i=0;i<3;i++){
        var soil=new BlockPos(MIN_X+1+random.nextInt(MAX_X-MIN_X-2),FLOOR_Y,MIN_Z+1+random.nextInt(MAX_Z-MIN_Z-2));var ice=soil.above().east();
        probe.cells.put(soil,Blocks.SOUL_SOIL.defaultBlockState());cells.add(row(soil,Block.getId(Blocks.SOUL_SOIL.defaultBlockState())));
        probe.cells.put(ice,Blocks.BLUE_ICE.defaultBlockState());cells.add(row(ice,Block.getId(Blocks.BLUE_ICE.defaultBlockState())));
      }
      // Actions at random ticks over the first 160, then the scene settles to 320.
      var actions=new TreeMap<Integer,List<JsonArray>>();int actionCount=10+random.nextInt(30);
      // Bubble column sites: a pool of three sources over stone that becomes magma or soul sand.
      for(int i=0;i<2;i++){
        int x=MIN_X+1+random.nextInt(MAX_X-MIN_X-2),z=MIN_Z+1+random.nextInt(MAX_Z-MIN_Z-2);
        probe.cells.put(new BlockPos(x,FLOOR_Y,z),stone);cells.add(row(new BlockPos(x,FLOOR_Y,z),Block.getId(stone)));
        for(int y=FLOOR_Y+1;y<=FLOOR_Y+3;y++){
          var pool=new BlockPos(x,y,z);var source=Blocks.WATER.defaultBlockState();
          probe.cells.put(pool,source);cells.add(row(pool,Block.getId(source)));
        }
        var action=new JsonArray();action.add("set");action.add(x);action.add(FLOOR_Y);action.add(z);
        action.add(Block.getId((random.nextBoolean()?Blocks.MAGMA_BLOCK:Blocks.SOUL_SAND).defaultBlockState()));
        actions.computeIfAbsent(random.nextInt(40),k->new ArrayList<>()).add(action);
      }
      // Random ticks of lava cells, as a random tick speed would pick them.
      for(int t=0;t<320;t++)if(random.nextInt(3)==0){
        var action=new JsonArray();action.add("random");action.add(MIN_X);action.add(FLOOR_Y);action.add(MIN_Z);
        actions.computeIfAbsent(t,k->new ArrayList<>()).add(action);
      }
      for(int a=0;a<actionCount;a++){
        int t=random.nextInt(160);
        var pos=new BlockPos(MIN_X+random.nextInt(MAX_X-MIN_X),FLOOR_Y+(random.nextInt(4)==0?0:1+random.nextInt(3)),MIN_Z+random.nextInt(MAX_Z-MIN_Z));
        var action=new JsonArray();int roll=random.nextInt(100);
        if(roll<70){action.add("set");action.add(pos.getX());action.add(pos.getY());action.add(pos.getZ());action.add(Block.getId(pick(random,true)));}
        else if(roll<80){action.add("empty");action.add(pos.getX());action.add(pos.getY());action.add(pos.getZ());action.add(2);}
        else if(roll<88){action.add("empty");action.add(pos.getX());action.add(pos.getY());action.add(pos.getZ());action.add(4);}
        else{action.add("pickup");action.add(pos.getX());action.add(pos.getY());action.add(pos.getZ());}
        actions.computeIfAbsent(t,k->new ArrayList<>()).add(action);
      }
      var steps=new JsonArray();
      for(int t=0;t<320;t++){
        probe.time=t;probe.writes=new JsonArray();probe.events=new JsonArray();var items=new JsonArray();
        var now=actions.getOrDefault(t,List.of());
        for(var action:now){
          var pos=new BlockPos(action.get(1).getAsInt(),action.get(2).getAsInt(),action.get(3).getAsInt());
          switch(action.get(0).getAsString()){
            case "set"->probe.setBlock(pos,Block.stateById(action.get(4).getAsInt()),Block.UPDATE_ALL);
            case "random"->{
              // `ServerLevel.tickChunk` at a random lava cell, if any: the block's random tick
              // (lava's), then its fluid's.
              var candidates=new ArrayList<BlockPos>();
              for(var entry:probe.cells.entrySet())if(entry.getValue().is(Blocks.LAVA))candidates.add(entry.getKey());
              candidates.sort(Comparator.naturalOrder());
              if(!candidates.isEmpty()){
                pos=candidates.get(random.nextInt(candidates.size()));
                action.set(1,new JsonPrimitive(pos.getX()));action.set(2,new JsonPrimitive(pos.getY()));action.set(3,new JsonPrimitive(pos.getZ()));
              }
              var state=probe.cell(pos);
              if(state.is(Blocks.LAVA)){
                var fluidState=state.getFluidState();
                state.randomTick(probe,pos,probe.random);fluidState.randomTick(probe,pos,probe.random);
              }
            }
            case "empty"->{
              boolean done=(action.get(4).getAsInt()==2?water:lava).emptyContents(null,probe,pos,null);
              items.add(done?1:0);if(done)emptied++;
            }
            default->{
              // A pickup takes a random cell that gives an item, if any.
              var candidates=new ArrayList<BlockPos>();
              for(var entry:probe.cells.entrySet())if(entry.getValue().getFluidState().isSource()||entry.getValue().is(Blocks.POWDER_SNOW))candidates.add(entry.getKey());
              candidates.sort(Comparator.naturalOrder());
              if(!candidates.isEmpty()&&random.nextInt(5)!=0){
                pos=candidates.get(random.nextInt(candidates.size()));
                action.set(1,new JsonPrimitive(pos.getX()));action.set(2,new JsonPrimitive(pos.getY()));action.set(3,new JsonPrimitive(pos.getZ()));
              }
              var state=probe.cell(pos);var taken=ItemStack.EMPTY;
              if(state.getBlock() instanceof BucketPickup pickup)taken=pickup.pickupBlock(null,probe,pos,state);
              items.add(taken.isEmpty()?"":BuiltInRegistries.ITEM.getKey(taken.getItem()).toString());
              if(!taken.isEmpty())pickups++;
            }
          }
        }
        // Fire's own ticks (burning, spreading) are another slice.
        probe.blockTicks.tick(t,65536,(pos,block)->{if(block!=Blocks.FIRE)invoke(tickBlock,probe,pos,block);});
        probe.fluidTicks.tick(t,65536,(pos,fluid)->invoke(tickFluid,probe,pos,fluid));
        for(var w:probe.writes){
          var written=Block.stateById(w.getAsJsonArray().get(3).getAsInt());
          if(written.is(Blocks.OBSIDIAN))obsidian++;
          if(written.is(Blocks.COBBLESTONE))cobble++;
          if(written.is(Blocks.STONE))stoneMade++;
          if(written.is(Blocks.BASALT))basalt++;
          if(written.is(Blocks.FIRE)||written.is(Blocks.SOUL_FIRE))fires++;
          if(written.is(Blocks.BUBBLE_COLUMN))columns++;
          var fluid=written.getFluidState();
          if(fluid.isSource()&&written.getBlock() instanceof LiquidBlock)sources++;
          if(!fluid.isEmpty()&&!fluid.isSource())flowing++;
          if(written.hasProperty(BlockStateProperties.WATERLOGGED)&&written.getValue(BlockStateProperties.WATERLOGGED))waterlogged++;
        }
        for(var e:probe.events)if(e.getAsJsonArray().get(3).getAsInt()==1501)fizz++;
        writes+=probe.writes.size();
        if(!now.isEmpty()||!probe.writes.isEmpty()||!probe.events.isEmpty()){
          var step=new JsonObject();step.addProperty("t",t);
          var acts=new JsonArray();now.forEach(acts::add);step.add("actions",acts);step.add("items",items);
          step.add("writes",probe.writes);step.add("events",probe.events);steps.add(step);
        }
      }
      var scene=new JsonObject();scene.addProperty("seed",levelSeed);scene.addProperty("dimension",dimension);
      scene.addProperty("fire_spread",probe.fireSpread);scene.addProperty("water_conversion",waterConversion);scene.addProperty("lava_conversion",lavaConversion);
      scene.add("cells",cells);scene.add("steps",steps);scenes.add(scene);
    }
    var result=new JsonObject();result.add("scenes",scenes);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    if(obsidian<40||cobble<200||stoneMade<20||basalt<3||sources<500||flowing<20000||waterlogged<100||fizz<300||pickups<100||emptied<300||fires<100||columns<300)
      throw new AssertionError("thin scenes: obsidian "+obsidian+", cobblestone "+cobble+", stone "+stoneMade+", basalt "+basalt
        +", sources "+sources+", flowing "+flowing+", waterlogged "+waterlogged+", fizz "+fizz+", pickups "+pickups+", emptied "+emptied+", fires "+fires+", bubble columns "+columns);
    System.out.println("PASS: "+sceneCount+" fluid scenes of 320 ticks; "+writes+" writes: "+flowing+" flowing, "+sources
      +" new sources, "+waterlogged+" waterlogged, "+obsidian+" obsidian, "+cobble+" cobblestone, "+stoneMade+" stone, "+basalt
      +" basalt; "+fizz+" fizzes, "+emptied+" buckets emptied, "+pickups+" picked up; "+fires+" fires, "+columns+" bubble column writes");
  }

  /** A dimension type's constant attributes, as its level reads them. */
  static net.minecraft.world.attribute.EnvironmentAttributeSystem attributes(String dimension){
    var key=net.minecraft.resources.ResourceKey.create(Registries.DIMENSION_TYPE,net.minecraft.resources.Identifier.parse(dimension));
    var type=PROBE_LOOKUP.lookupOrThrow(Registries.DIMENSION_TYPE).getOrThrow(key).value();
    return net.minecraft.world.attribute.EnvironmentAttributeSystem.builder().addConstantLayer(type.attributes()).build();
  }

  static void invoke(Method method,Probe probe,BlockPos pos,Object type){
    try{method.invoke(probe,pos,type);}catch(Exception e){throw new RuntimeException(e);}
  }
}
