import com.google.gson.*;
import java.lang.reflect.Method;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerChunkCache;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundSource;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.item.BoneMealItem;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.level.block.grower.TreeGrower;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BambooLeaves;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.redstone.CollectingNeighborUpdater;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.ticks.LevelChunkTicks;
import net.minecraft.world.ticks.LevelTicks;
import net.minecraft.world.ticks.ScheduledTick;
import net.minecraft.world.ticks.TickPriority;

/**
 * Plants that grow and the tools that till (VMC-039a, VMC-039b, VMC-039c), from pinned 26.3. Five modes:
 *
 * - `facts OUT`: the tree growers (`TreeGrower.GROWERS`: per grower its weighted tree, mega
 *   tree and flower tree features and `getMinimumHeight`), each `SaplingBlock`'s grower and the
 *   azaleas', and the states a grass block or mycelium (`SpreadingSnowyBlock.canStayAlive`) and
 *   nylium (`canBeNylium`) die under, as runs of state ids; per biome its bone meal features, per
 *   mushroom its huge mushroom and the height it needs, per feature placer (moss) and nylium the
 *   feature it places above itself, per Nether fungus its planted huge fungus and the block it
 *   grows on, and the states sky light passes down through (`propagatesSkylightDown`).
 * - `scenes OUT [SCENES [SEED]]`: farms, cane and cactus beds, saplings, meadows, sea beds, Nether
 *   plants and vines, bamboo groves and lush, pale and crimson floors over a probe level whose block ticks are vanilla's own `LevelTicks`;
 *   one sky light for every cell (no block light), one `skyDarken`, rain or not and a biome
 *   (warm ocean, which grows corals from bone meal, or plains) per scene. Each game tick applies
 *   its actions in order (`/setblock`-style `setBlock(UPDATE_ALL)`; a random tick as
 *   `ServerLevel.tickChunk` runs one at a randomly ticking cell; bone meal as `BoneMealItem.useOn`
 *   on the cell's top face: `growCrop`, else `growWaterPlant` on the water above, with the level
 *   event when it took the bone meal), then runs the due block ticks. A sapling or azalea that
 *   would grow its tree stops at `level.getChunkSource()` (the tree is the generator's, checked
 *   apart). Per tick the cell writes in order, the level events and each random tick's and bone
 *   meal's result (0 nothing, 1 bone meal used, 2 the generator grows, 3 used and an item
 *   dropped). Bone meal on grass blocks, nylium, moss and mushrooms reaches the generator too
 *   (result 2), as do fungi; what it places is checked apart, and a grass block's draws before it are not the
 *   level's. Fluid ticks are scheduled but never run.
 *
 * - `trees OUT [CASES [SEED]]`: `TreeGrower.growTree` of a sapling (or a 2 x 2 of them, a
 *   propagule, an azalea) on a small plot with flowers and obstacles about it, with `RandomSource.create(seed)`
 *   as the random: whether it grew, and the cell writes in order.
 *
 * - `features OUT [CASES [SEED]]`: what bone meal places through the generator: a grass block's
 *   grass and flowers in a biome, nylium's and moss's features, a mushroom's huge mushroom, a
 *   fungus's planted huge fungus, each on
 *   a bumpy plot with covers, with `RandomSource.create(seed)` as the random; the cell writes.
 *
 * - `transformers OUT`: the tools' block transformers (`BlockTransformer.transformBlock`: hoes
 *   till, shovels flatten, axes strip, scrape and unwax): per item with a default
 *   `block_transformer` its transformer; per transformer its entries in order, each with its
 *   disallowed faces, sound, particle (level event, 0 none), loot table, drop strategy,
 *   neighbour-shape update, transform type, consumption and item damage, and per clicked state
 *   the state its provider gives with air (the `air` tag) above and with anything else above
 *   (-1 none). The providers are checked to read nothing but the cell and the one above it and
 *   no random.
 *
 * Usage: GrowthOracle (facts|scenes|trees|features|transformers) OUT [COUNT [SEED]]
 */
public class GrowthOracle {
  static final int FLOOR_Y=60,MIN_X=120,MAX_X=136,MIN_Z=-8,MAX_Z=8;

  /** A tree that would grow: the probe stops the sapling where it asks for the generator. */
  static class Grow extends RuntimeException {Grow(){super(null,null,false,false);}}

  /** The features bone meal places read only their placement context's bounds from the generator. */
  static class Chunks extends ServerChunkCache {
    net.minecraft.world.level.chunk.ChunkGenerator generator;
    private Chunks(){super(null,null,null,null,null,null,0,0,false,null);}
    @Override public net.minecraft.world.level.chunk.ChunkGenerator getGenerator(){return generator;}
  }

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.server.ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Server server;RandomSource random;GameRules rules;RegistryAccess access;
    LevelTicks<Block> blockTicks;LevelTicks<Fluid> fluidTicks;long time,subTick;int sky,darken,pops;boolean rain;
    Holder<net.minecraft.world.level.biome.Biome> biome;
    net.minecraft.world.level.chunk.PalettedContainerFactory factory;
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
    @Override public RegistryAccess registryAccess(){return access;}
    @Override public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    @Override public LevelTicks<Block> getBlockTicks(){return blockTicks;}
    @Override public LevelTicks<Fluid> getFluidTicks(){return fluidTicks;}
    @Override public boolean isClientSide(){return false;}
    @Override public boolean isLoaded(BlockPos pos){return !isOutsideBuildHeight(pos);}
    @Override public boolean hasChunkAt(BlockPos pos){return true;}
    @Override public int getRawBrightness(BlockPos pos,int darkening){return Math.max(sky-darkening,0);}
    @Override public int getSkyDarken(){return darken;}
    @Override public boolean isRainingAt(BlockPos pos){return rain;}
    @Override public int getBrightness(net.minecraft.world.level.LightLayer layer,BlockPos pos){return layer==net.minecraft.world.level.LightLayer.SKY?sky:0;}
    @Override public Holder<net.minecraft.world.level.biome.Biome> getBiome(BlockPos pos){return biome;}
    /** A chunk source whose generator is none (`features` mode), else the generator stops the probe. */
    Chunks chunks;
    @Override public ServerChunkCache getChunkSource(){if(chunks==null)throw new Grow();return chunks;}
    @Override public net.minecraft.world.level.chunk.PalettedContainerFactory palettedContainerFactory(){return factory;}
    /** A chunk of the cells as they are (farmland scans its sections for water). */
    @Override public net.minecraft.world.level.chunk.LevelChunk getChunk(int x,int z){
      var chunk=new net.minecraft.world.level.chunk.LevelChunk(this,new net.minecraft.world.level.ChunkPos(x,z));
      for(var e:cells.entrySet()){
        var p=e.getKey();
        if((p.getX()>>4)!=x||(p.getZ()>>4)!=z)continue;
        chunk.getSection(chunk.getSectionIndex(p.getY())).setBlockState(p.getX()&15,p.getY()&15,p.getZ()&15,e.getValue(),false);
      }
      return chunk;
    }
    @Override public void levelEvent(Entity source,int type,BlockPos pos,int data){events.add(row(pos,type,data));}
    @Override public void gameEvent(Holder<GameEvent> event,Vec3 at,GameEvent.Context context){}
    @Override public void gameEvent(Entity source,Holder<GameEvent> event,BlockPos pos){}
    @Override public void playSound(Entity except,BlockPos pos,SoundEvent sound,SoundSource source,float volume,float pitch){}
    /** A dropped item counts (bone meal on a tall flower pops a copy); nothing is added. */
    @Override public int getNextEntityId(){return 1;}
    @Override public long getSeed(){return 0;}
    @Override public boolean addFreshEntity(Entity entity){if(entity instanceof net.minecraft.world.entity.item.ItemEntity)pops++;return false;}
    // No entities stand on the plants (farmland turning to dirt pushes none up).
    @Override public List<Entity> getEntities(Entity except,net.minecraft.world.phys.AABB box,java.util.function.Predicate<? super Entity> filter){return List.of();}
    @Override public void scheduleTick(BlockPos pos,Block block,int delay,TickPriority priority){
      blockTicks.schedule(new ScheduledTick<>(block,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Block block,int delay){scheduleTick(pos,block,delay,TickPriority.NORMAL);}
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay,TickPriority priority){
      fluidTicks.schedule(new ScheduledTick<>(fluid,pos.immutable(),time+delay,priority,subTick++));
    }
    @Override public void scheduleTick(BlockPos pos,Fluid fluid,int delay){scheduleTick(pos,fluid,delay,TickPriority.NORMAL);}

    /** `Level.setBlock` with `LevelChunk.setBlockState`'s hooks, over the map (as FluidOracle's). */
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

  static Probe probe(long seed)throws Exception{
    var lookup=FluidOracle.initialize();
    var access=StructureOracle.serverRegistries();
    var theUnsafe=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");theUnsafe.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)theUnsafe.get(null);
    var server=(Server)unsafe.allocateInstance(Server.class);
    server.registries=new net.minecraft.server.ReloadableServerRegistries.Holder(lookup);
    var probe=(Probe)unsafe.allocateInstance(Probe.class);probe.server=server;probe.access=access;
    probe.factory=net.minecraft.world.level.chunk.PalettedContainerFactory.create(access);
    probe.random=RandomSource.create(seed);probe.rules=new GameRules(FeatureFlags.DEFAULT_FLAGS);
    probe.cells=new HashMap<>();probe.sky=15;
    var updater=Level.class.getDeclaredField("neighborUpdater");updater.setAccessible(true);
    updater.set(probe,new CollectingNeighborUpdater(probe,1_000_000));
    var players=ServerLevel.class.getDeclaredField("players");players.setAccessible(true);players.set(probe,new ArrayList<>());
    return probe;
  }

  public static void main(String[] args)throws Exception{
    switch(args[0]){
      case "facts"->facts(args[1]);
      case "scenes"->scenes(args[1],args.length>2?Integer.parseInt(args[2]):120,args.length>3?Long.parseLong(args[3]):39_001L);
      case "transformers"->transformers(args[1]);
      case "trees"->trees(args[1],args.length>2?Integer.parseInt(args[2]):600,args.length>3?Long.parseLong(args[3]):39_002L);
      case "features"->features(args[1],args.length>2?Integer.parseInt(args[2]):400,args.length>3?Long.parseLong(args[3]):39_003L);
      default->throw new IllegalArgumentException(args[0]);
    }
  }

  @SuppressWarnings("unchecked")
  static JsonArray weighted(Object list)throws Exception{
    var out=new JsonArray();
    for(var entry:(List<net.minecraft.util.random.Weighted<net.minecraft.resources.ResourceKey<?>>>)list.getClass().getMethod("unwrap").invoke(list)){
      var pair=new JsonArray();pair.add(entry.value().identifier().toString());pair.add(entry.weight());out.add(pair);
    }
    return out;
  }

  static Object field(Object owner,Class<?> type,String name)throws Exception{
    var f=type.getDeclaredField(name);f.setAccessible(true);return f.get(owner);
  }

  static void facts(String out)throws Exception{
    var probe=probe(0);
    var growers=new TreeMap<String,JsonObject>();
    var all=(Map<String,TreeGrower>)field(null,TreeGrower.class,"GROWERS");
    for(var grower:all.values()){
      var json=new JsonObject();
      json.add("trees",weighted(field(grower,TreeGrower.class,"trees")));
      json.add("mega",weighted(field(grower,TreeGrower.class,"megaTrees")));
      json.add("flowers",weighted(field(grower,TreeGrower.class,"flowerTrees")));
      json.addProperty("min_height",grower.getMinimumHeight(probe).orElse(0));
      growers.put((String)field(grower,TreeGrower.class,"name"),json);
    }
    var saplings=new TreeMap<String,String>();
    for(var block:BuiltInRegistries.BLOCK)if(block instanceof SaplingBlock){
      var grower=(TreeGrower)field(block,SaplingBlock.class,"treeGrower");
      saplings.put(BuiltInRegistries.BLOCK.getKey(block).getPath(),(String)field(grower,TreeGrower.class,"name"));
    }
    var azaleas=new JsonObject();
    for(var block:new Block[]{Blocks.AZALEA,Blocks.FLOWERING_AZALEA})
      azaleas.addProperty(BuiltInRegistries.BLOCK.getKey(block).getPath(),(String)field(TreeGrower.AZALEA,TreeGrower.class,"name"));
    // The states a grass block (or mycelium) and nylium die under: `canStayAlive` and `canBeNylium`
    // read only the cell above, the same for each of their states.
    var smothers=new JsonObject();
    Method grass=SpreadingSnowyBlock.class.getDeclaredMethod("canStayAlive",BlockState.class,net.minecraft.world.level.LevelReader.class,BlockPos.class);
    Method nylium=NyliumBlock.class.getDeclaredMethod("canBeNylium",BlockState.class,net.minecraft.world.level.LevelReader.class,BlockPos.class);
    grass.setAccessible(true);nylium.setAccessible(true);
    BlockState[] grasses={Blocks.GRASS_BLOCK.defaultBlockState(),Blocks.GRASS_BLOCK.defaultBlockState().setValue(SnowyBlock.SNOWY,true),
      Blocks.MYCELIUM.defaultBlockState(),Blocks.MYCELIUM.defaultBlockState().setValue(SnowyBlock.SNOWY,true)};
    BlockState[] nyliums={Blocks.CRIMSON_NYLIUM.defaultBlockState(),Blocks.WARPED_NYLIUM.defaultBlockState()};
    var origin=new BlockPos(0,64,0);
    for(var entry:List.of(Map.entry("grass",Map.entry(grass,grasses)),Map.entry("nylium",Map.entry(nylium,nyliums)))){
      var runs=new JsonArray();int first=-1;
      for(int id=0;id<=Block.BLOCK_STATE_REGISTRY.size();id++){
        boolean dies=false;
        if(id<Block.BLOCK_STATE_REGISTRY.size()){
          Boolean seen=null;
          for(var state:entry.getValue().getValue()){
            probe.cells=new HashMap<>();probe.cells.put(origin,state);probe.cells.put(origin.above(),Block.stateById(id));
            boolean d=!(boolean)entry.getValue().getKey().invoke(null,state,probe,origin);
            if(seen!=null&&seen!=d)throw new AssertionError(entry.getKey()+" lives under "+Block.stateById(id)+" by its state");
            seen=d;
          }
          dies=seen;
        }
        if(dies&&first<0)first=id;
        if(!dies&&first>=0){var run=new JsonArray();run.add(first);run.add(id-1);runs.add(run);first=-1;}
      }
      smothers.add(entry.getKey(),runs);
    }
    // Bone meal that places features: each biome's bone meal features (a grass block's flowers),
    // the huge mushroom of each mushroom and the height it needs, the feature each feature placer
    // (moss) and nylium places above itself.
    var features=probe.access.lookupOrThrow(net.minecraft.core.registries.Registries.FEATURE);
    var flowers=new TreeMap<String,JsonArray>();
    probe.access.lookupOrThrow(net.minecraft.core.registries.Registries.BIOME).listElements().forEach(h->{
      var list=new JsonArray();
      for(var f:h.value().getGenerationSettings().getBoneMealFeatures())list.add(features.getKey(f).toString());
      if(!list.isEmpty())flowers.put(h.key().identifier().toString(),list);
    });
    // The states sky light passes down through (`propagatesSkylightDown`: netherrack takes nylium
    // under them, VMC-039c), as runs.
    var skylight=new JsonArray();int open=-1;
    for(int id=0;id<=Block.BLOCK_STATE_REGISTRY.size();id++){
      boolean passes=id<Block.BLOCK_STATE_REGISTRY.size()&&Block.stateById(id).propagatesSkylightDown();
      if(passes&&open<0)open=id;
      if(!passes&&open>=0){var run=new JsonArray();run.add(open);run.add(id-1);skylight.add(run);open=-1;}
    }
    // Per Nether fungus its planted huge fungus and the block it grows on.
    var fungi=new JsonObject();
    var mushrooms=new JsonObject();var placers=new JsonObject();
    for(var block:BuiltInRegistries.BLOCK){
      var name=BuiltInRegistries.BLOCK.getKey(block).getPath();
      if(block instanceof MushroomBlock){
        var key=(net.minecraft.resources.ResourceKey<?>)field(block,MushroomBlock.class,"feature");
        var feature=features.getValue(key.identifier());
        var json=new JsonObject();json.addProperty("feature",key.identifier().toString());
        json.addProperty("height",4+((net.minecraft.world.level.levelgen.feature.AbstractHugeMushroomFeature)feature).foliageRadius());
        mushrooms.add(name,json);
      }else if(block instanceof BonemealableFeaturePlacerBlock)
        placers.addProperty(name,((net.minecraft.resources.ResourceKey<?>)field(block,BonemealableFeaturePlacerBlock.class,"feature")).identifier().toString());
      else if(block instanceof NyliumBlock)
        placers.addProperty(name,net.minecraft.data.worldgen.features.NetherFeatures.NYLIUM_BONEMEAL.identifier().toString());
      else if(block instanceof NetherFungusBlock){
        var json=new JsonObject();
        json.addProperty("feature",((net.minecraft.resources.ResourceKey<?>)field(block,NetherFungusBlock.class,"feature")).identifier().toString());
        json.addProperty("base",BuiltInRegistries.BLOCK.getKey((Block)field(block,NetherFungusBlock.class,"requiredBlock")).getPath());
        fungi.add(name,json);
      }
    }
    var result=FluidOracle.stamped(Block.BLOCK_STATE_REGISTRY.size());
    var g=new JsonObject();growers.forEach(g::add);result.add("growers",g);
    var s=new JsonObject();saplings.forEach(s::addProperty);result.add("saplings",s);
    result.add("azaleas",azaleas);result.add("smothers",smothers);
    var f=new JsonObject();flowers.forEach(f::add);result.add("bone_meal_features",f);
    result.add("mushrooms",mushrooms);result.add("feature_placers",placers);
    result.add("fungi",fungi);result.add("skylight",skylight);
    Files.writeString(Path.of(out),new GsonBuilder().create().toJson(result)+"\n");
    System.out.println("PASS: "+growers.size()+" tree growers, "+saplings.size()+" saplings, "+azaleas.size()+" azaleas, "
      +flowers.size()+" biomes with bone meal features, "+mushrooms.size()+" mushrooms, "+placers.size()+" feature placers, "
      +fungi.size()+" fungi, "+skylight.size()+" runs of states sky light passes down");
  }


  static <T extends Comparable<T>> BlockState with(BlockState state,net.minecraft.world.level.block.state.properties.Property<T> property,Random random){
    var values=new ArrayList<>(property.getPossibleValues());
    return state.setValue(property,values.get(random.nextInt(values.size())));
  }

  /** What bone meal may be tried on: the plants VMC-039a, VMC-039b and VMC-039c grow and blocks they do not. */
  static boolean boneMealTarget(BlockState state){
    var b=state.getBlock();
    return b instanceof CropBlock||b instanceof StemBlock||b instanceof SaplingBlock||b instanceof AzaleaBlock||b instanceof CocoaBlock
      ||b instanceof SweetBerryBushBlock||b instanceof PitcherCropBlock||b instanceof TallGrassBlock||b instanceof TallFlowerBlock
      ||b instanceof FlowerBedBlock||b instanceof SeagrassBlock||b instanceof GrowingPlantHeadBlock||b instanceof GrowingPlantBodyBlock
      ||b instanceof BushBlock||b instanceof FireflyBushBlock||b instanceof ShortDryGrassBlock||b instanceof TallDryGrassBlock
      ||b instanceof SeaPickleBlock||b instanceof MangroveLeavesBlock||b instanceof RootedDirtBlock||b instanceof NetherWartBlock
      ||b instanceof BambooSaplingBlock||b instanceof BambooStalkBlock||b instanceof GlowLichenBlock||b instanceof SmallDripleafBlock
      ||b instanceof BigDripleafBlock||b instanceof BigDripleafStemBlock||b instanceof NetherrackBlock||b instanceof HangingMossBlock
      ||b instanceof MossyCarpetBlock||generated(state)
      ||state.is(Blocks.SUGAR_CANE)||state.is(Blocks.CACTUS)||state.is(Blocks.FARMLAND)||state.is(Blocks.ATTACHED_PUMPKIN_STEM);
  }

  /** Bone meal that places features (grass blocks, nylium, moss, mushrooms, fungi): the generator's. */
  static boolean generated(BlockState state){
    var b=state.getBlock();
    return state.is(Blocks.GRASS_BLOCK)||b instanceof NyliumBlock||b instanceof BonemealableFeaturePlacerBlock||b instanceof MushroomBlock
      ||b instanceof NetherFungusBlock;
  }

  /**
   * `BoneMealItem.useOn` on `pos`'s face `face`: 0 nothing, 1 used, 2 the generator grows (a tree,
   * or what bone meal places), 3 used and a copy dropped. What the generator places draws from
   * its own random (as ValiMC's tasks seed theirs): a grass block's draws before it reaches the
   * generator are not the level's, and a mushroom's removal before it is undone.
   */
  static int useBoneMeal(Probe probe,BlockPos pos,Direction face){
    var stack=new ItemStack(Items.BONE_MEAL);probe.pops=0;
    int result;
    var level=probe.random;var cells=new HashMap<>(probe.cells);int writes=probe.writes.size();
    var clicked=probe.cell(pos);
    if(clicked.is(Blocks.GRASS_BLOCK)&&((BonemealableBlock)clicked.getBlock()).isValidBonemealTarget(probe,pos,clicked,BonemealSource.INTERACTION))
      probe.random=RandomSource.create(0);
    try{
      if(BoneMealItem.growCrop(stack,probe,pos)){probe.levelEvent(null,1505,pos,15);result=1;}
      else{
        var relative=pos.relative(face);
        if(probe.cell(pos).isFaceSturdy(probe,pos,face)&&BoneMealItem.growWaterPlant(stack,probe,relative,face)){probe.levelEvent(null,1505,relative,15);result=1;}
        else result=0;
      }
    }catch(Grow g){
      probe.cells=cells;while(probe.writes.size()>writes)probe.writes.remove(writes);
      probe.levelEvent(null,1505,pos,15);return 2;
    }finally{probe.random=level;}
    return result==1&&probe.pops>0?3:result;
  }

  static void half(Probe probe,BlockPos pos,BlockState lower){
    probe.cells.put(pos,lower.setValue(BlockStateProperties.DOUBLE_BLOCK_HALF,net.minecraft.world.level.block.state.properties.DoubleBlockHalf.LOWER));
    probe.cells.put(pos.above(),lower.setValue(BlockStateProperties.DOUBLE_BLOCK_HALF,net.minecraft.world.level.block.state.properties.DoubleBlockHalf.UPPER));
  }

  /** A growing plant `length` long from `start` toward `up`: body blocks, then its head at a random age. */
  static void plant(Probe probe,Random random,BlockPos start,boolean up,int length,Block head,Block body){
    for(int i=0;i<length;i++){
      var pos=up?start.above(i):start.below(i);
      var state=i==length-1?head.defaultBlockState().setValue(GrowingPlantHeadBlock.AGE,random.nextInt(4)==0?25:random.nextInt(25)):body.defaultBlockState();
      if(state.hasProperty(BlockStateProperties.BERRIES))state=state.setValue(BlockStateProperties.BERRIES,random.nextInt(3)==0);
      probe.cells.put(pos,state);
    }
  }

  static void scenes(String out,int sceneCount,long seed)throws Exception{
    var probe=probe(seed);var random=new Random(seed);
    Block[] CROPS={Blocks.WHEAT,Blocks.CARROTS,Blocks.POTATOES,Blocks.BEETROOTS,Blocks.TORCHFLOWER_CROP};
    Block[] SAPLINGS={Blocks.OAK_SAPLING,Blocks.SPRUCE_SAPLING,Blocks.BIRCH_SAPLING,Blocks.JUNGLE_SAPLING,
      Blocks.ACACIA_SAPLING,Blocks.CHERRY_SAPLING,Blocks.DARK_OAK_SAPLING,Blocks.PALE_OAK_SAPLING,Blocks.POPLAR_SAPLING};
    Block[] TALL_FLOWERS={Blocks.SUNFLOWER,Blocks.LILAC,Blocks.ROSE_BUSH,Blocks.PEONY};
    Block[] CORAL_BLOCKS={Blocks.TUBE_CORAL_BLOCK,Blocks.BRAIN_CORAL_BLOCK,Blocks.BUBBLE_CORAL_BLOCK,Blocks.FIRE_CORAL_BLOCK,Blocks.HORN_CORAL_BLOCK};
    var biomes=probe.access.lookupOrThrow(net.minecraft.core.registries.Registries.BIOME);
    Method tickBlock=ServerLevel.class.getDeclaredMethod("tickBlock",BlockPos.class,Block.class);tickBlock.setAccessible(true);
    var scenes=new JsonArray();
    var count=new TreeMap<String,Integer>();
    for(int s=0;s<sceneCount;s++){
      long levelSeed=random.nextLong();probe.random=RandomSource.create(levelSeed);
      probe.time=0;probe.subTick=0;
      probe.sky=8+random.nextInt(8);probe.darken=new int[]{0,0,4,11}[random.nextInt(4)];probe.rain=random.nextInt(4)==0;
      boolean corals=random.nextInt(3)==0;
      probe.biome=biomes.getOrThrow(corals?net.minecraft.world.level.biome.Biomes.WARM_OCEAN:net.minecraft.world.level.biome.Biomes.PLAINS);
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-16)>>4;cx<=(MAX_X+16)>>4;cx++)for(int cz=(MIN_Z-16)>>4;cz<=(MAX_Z+16)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      probe.cells=new HashMap<>();
      // One plot kind per 4 x 4 plot: a farm, a cane and cactus bed, saplings, a meadow, a sea bed,
      // Nether plants, vines and what hangs from a ceiling, a bamboo grove, or a lush, pale and
      // crimson floor.
      for(int px=MIN_X;px<MAX_X;px+=4)for(int pz=MIN_Z;pz<MAX_Z;pz+=4){
        int plot=random.nextInt(8);
        for(int x=px;x<px+4;x++)for(int z=pz;z<pz+4;z++){
          var floor=new BlockPos(x,FLOOR_Y,z);var above=floor.above();
          probe.cells.put(floor.below(),Blocks.STONE.defaultBlockState());
          int roll=random.nextInt(100);
          if(roll<8&&plot!=4){probe.cells.put(floor,Blocks.WATER.defaultBlockState());continue;}
          if(plot==0){
            if(roll<80){
              probe.cells.put(floor,with(Blocks.FARMLAND.defaultBlockState(),FarmlandBlock.MOISTURE,random));
              int top=random.nextInt(100);
              if(top<45){var crop=(CropBlock)CROPS[random.nextInt(CROPS.length)];probe.cells.put(above,crop.getStateForAge(random.nextInt(crop.getMaxAge()+1)));}
              else if(top<60){var stem=(random.nextBoolean()?Blocks.PUMPKIN_STEM:Blocks.MELON_STEM).defaultBlockState();
                probe.cells.put(above,stem.setValue(StemBlock.AGE,random.nextInt(3)==0?7:random.nextInt(8)));}
              else if(top<65)probe.cells.put(above,Blocks.STONE.defaultBlockState());
              else if(top<73){
                var pitcher=Blocks.PITCHER_CROP.defaultBlockState().setValue(PitcherCropBlock.AGE,random.nextInt(5));
                if(pitcher.getValue(PitcherCropBlock.AGE)>=3)half(probe,above,pitcher);else probe.cells.put(above,pitcher);
              }
            }else probe.cells.put(floor,(random.nextBoolean()?Blocks.DIRT:Blocks.PODZOL).defaultBlockState());
          }else if(plot==1){
            probe.cells.put(floor,(roll<70?Blocks.SAND:Blocks.DIRT).defaultBlockState());
            int top=random.nextInt(100);
            Block plant=top<40?Blocks.CACTUS:top<80?Blocks.SUGAR_CANE:null;
            if(plant!=null){
              int height=1+random.nextInt(3);
              for(int h=0;h<height;h++){
                var state=plant.defaultBlockState();int age=random.nextInt(4)==0?15:random.nextInt(3)==0?8:random.nextInt(16);
                probe.cells.put(above.above(h),state.setValue(BlockStateProperties.AGE_15,age));
              }
            }
          }else if(plot==2){
            probe.cells.put(floor,(roll<60?Blocks.PODZOL:roll<85?Blocks.DIRT:Blocks.MUD).defaultBlockState());
            int top=random.nextInt(100);
            if(top<40){
              var sapling=SAPLINGS[random.nextInt(SAPLINGS.length)].defaultBlockState().setValue(SaplingBlock.STAGE,random.nextInt(2));
              probe.cells.put(above,sapling);
              // Mega growers need a 2 x 2.
              if(random.nextInt(3)==0)for(int i=0;i<4;i++){
                var other=above.offset(i&1,0,i>>1);
                if(other.getX()<px+4&&other.getZ()<pz+4)probe.cells.put(other,sapling);
              }
            }else if(top<50)probe.cells.put(above,Blocks.MANGROVE_PROPAGULE.defaultBlockState().setValue(BlockStateProperties.AGE_4,random.nextInt(5)));
            else if(top<58)probe.cells.put(above,(random.nextBoolean()?Blocks.POPPY:Blocks.DANDELION).defaultBlockState());
            else if(top<66){
              // A propagule hanging from mangrove leaves.
              var leaves=above.above(2);probe.cells.put(leaves,Blocks.MANGROVE_LEAVES.defaultBlockState().setValue(LeavesBlock.PERSISTENT,true));
              probe.cells.put(leaves.below(),Blocks.MANGROVE_PROPAGULE.defaultBlockState().setValue(MangrovePropaguleBlock.HANGING,true)
                .setValue(BlockStateProperties.AGE_4,random.nextInt(5)));
            }
          }else if(plot==3){
            // A meadow: grass, dirt and mycelium under plants and covers.
            probe.cells.put(floor,(roll<55?Blocks.GRASS_BLOCK:roll<82?Blocks.DIRT:roll<92?Blocks.MYCELIUM:Blocks.COARSE_DIRT).defaultBlockState());
            int top=random.nextInt(100);
            if(top<12)probe.cells.put(above,Blocks.SHORT_GRASS.defaultBlockState());
            else if(top<18)probe.cells.put(above,Blocks.FERN.defaultBlockState());
            else if(top<26)half(probe,above,TALL_FLOWERS[random.nextInt(TALL_FLOWERS.length)].defaultBlockState());
            else if(top<32)probe.cells.put(above,(random.nextBoolean()?Blocks.PINK_PETALS:Blocks.WILDFLOWERS).defaultBlockState()
              .setValue(FlowerBedBlock.AMOUNT,1+random.nextInt(4)).setValue(FlowerBedBlock.FACING,Direction.Plane.HORIZONTAL.getRandomDirection(RandomSource.create(random.nextLong()))));
            else if(top<36)probe.cells.put(above,Blocks.BUSH.defaultBlockState());
            else if(top<39)probe.cells.put(above,Blocks.FIREFLY_BUSH.defaultBlockState());
            else if(top<46)probe.cells.put(above,Blocks.SWEET_BERRY_BUSH.defaultBlockState().setValue(SweetBerryBushBlock.AGE,random.nextInt(4)));
            else if(top<50)probe.cells.put(above,(random.nextBoolean()?Blocks.AZALEA:Blocks.FLOWERING_AZALEA).defaultBlockState());
            else if(top<53)probe.cells.put(above,Blocks.SHORT_DRY_GRASS.defaultBlockState());
            else if(top<56)probe.cells.put(above,Blocks.TALL_DRY_GRASS.defaultBlockState());
            else if(top<60)probe.cells.put(above,Blocks.STONE.defaultBlockState());
            else if(top<63)probe.cells.put(above,Blocks.STONE_SLAB.defaultBlockState());
            else if(top<66)probe.cells.put(above,Blocks.SNOW.defaultBlockState().setValue(SnowLayerBlock.LAYERS,1+random.nextInt(3)));
            else if(top<68)probe.cells.put(above,Blocks.WATER.defaultBlockState());
            else if(top<70)probe.cells.put(above,Blocks.GLASS.defaultBlockState());
          }else if(plot==4){
            // A sea bed three deep: kelp, seagrass and pickles.
            probe.cells.put(floor,(roll<35?Blocks.SAND:roll<55?Blocks.GRAVEL:roll<70?Blocks.DIRT:CORAL_BLOCKS[random.nextInt(CORAL_BLOCKS.length)]).defaultBlockState());
            for(int h=0;h<3;h++)probe.cells.put(above.above(h),Blocks.WATER.defaultBlockState());
            int top=random.nextInt(100);
            if(top<20)plant(probe,random,above,true,1+random.nextInt(3),Blocks.KELP,Blocks.KELP_PLANT);
            else if(top<35)probe.cells.put(above,Blocks.SEAGRASS.defaultBlockState());
            else if(top<42)half(probe,above,Blocks.TALL_SEAGRASS.defaultBlockState());
            else if(top<50)probe.cells.put(above,Blocks.SEA_PICKLE.defaultBlockState().setValue(SeaPickleBlock.PICKLES,1+random.nextInt(4)));
          }else if(plot==6){
            // A bamboo grove: saplings and stalks up to 15 tall (VMC-039c).
            probe.cells.put(floor,(roll<40?Blocks.PODZOL:roll<70?Blocks.DIRT:roll<85?Blocks.SAND:Blocks.GRAVEL).defaultBlockState());
            int top=random.nextInt(100);
            if(top<25)probe.cells.put(above,Blocks.BAMBOO_SAPLING.defaultBlockState());
            else if(top<80){
              int height=1+random.nextInt(random.nextInt(3)==0?15:6);int age=random.nextInt(2);
              for(int h=0;h<height;h++){
                var leaves=h==height-1?(random.nextBoolean()?BambooLeaves.LARGE:BambooLeaves.SMALL):h==height-2&&random.nextBoolean()?BambooLeaves.SMALL:BambooLeaves.NONE;
                int stage=h==height-1&&random.nextInt(5)==0?1:0;
                probe.cells.put(above.above(h),Blocks.BAMBOO.defaultBlockState().setValue(BambooStalkBlock.AGE,age)
                  .setValue(BambooStalkBlock.LEAVES,leaves).setValue(BambooStalkBlock.STAGE,stage));
              }
            }else if(top<85)probe.cells.put(above,Blocks.STONE.defaultBlockState());
          }else if(plot==7){
            // Lush, pale and crimson floors (VMC-039c): dripleaves, glow lichen, hanging moss and moss
            // carpets, fungi, netherrack beside nylium.
            var ceiling=floor.above(5);
            int top=random.nextInt(100);
            var facing=Direction.Plane.HORIZONTAL.getRandomDirection(RandomSource.create(random.nextLong()));
            probe.cells.put(floor,(random.nextBoolean()?Blocks.CLAY:Blocks.MOSS_BLOCK).defaultBlockState());
            if(top<12){
              var leaf=Blocks.SMALL_DRIPLEAF.defaultBlockState().setValue(SmallDripleafBlock.FACING,facing)
                .setValue(BlockStateProperties.WATERLOGGED,random.nextInt(3)==0);
              half(probe,above,leaf);
            }else if(top<22){
              int stems=random.nextInt(3);
              for(int h=0;h<stems;h++)probe.cells.put(above.above(h),Blocks.BIG_DRIPLEAF_STEM.defaultBlockState().setValue(BigDripleafStemBlock.FACING,facing));
              probe.cells.put(above.above(stems),Blocks.BIG_DRIPLEAF.defaultBlockState().setValue(BigDripleafBlock.FACING,facing));
            }else if(top<34){
              // Lichen on the floor, a wall or the ceiling.
              int where=random.nextInt(3);
              if(where==0)probe.cells.put(above,Blocks.GLOW_LICHEN.defaultBlockState().setValue(MultifaceBlock.getFaceProperty(Direction.DOWN),true));
              else if(where==1){
                probe.cells.put(above,Blocks.STONE.defaultBlockState());probe.cells.put(above.above(),Blocks.STONE.defaultBlockState());
                var side=above.above().relative(facing);
                if(!probe.cells.containsKey(side))probe.cells.put(side,Blocks.GLOW_LICHEN.defaultBlockState().setValue(MultifaceBlock.getFaceProperty(facing.getOpposite()),true));
              }else{
                probe.cells.put(ceiling,Blocks.STONE.defaultBlockState());
                probe.cells.put(ceiling.below(),Blocks.GLOW_LICHEN.defaultBlockState().setValue(MultifaceBlock.getFaceProperty(Direction.UP),true));
              }
            }else if(top<46){
              // Pale hanging moss under pale oak leaves or stone, its tip at the bottom.
              probe.cells.put(ceiling,(random.nextBoolean()?Blocks.PALE_OAK_LEAVES.defaultBlockState().setValue(LeavesBlock.PERSISTENT,true):Blocks.STONE.defaultBlockState()));
              int length=1+random.nextInt(3);
              for(int h=1;h<=length;h++)probe.cells.put(ceiling.below(h),Blocks.PALE_HANGING_MOSS.defaultBlockState().setValue(HangingMossBlock.TIP,h==length));
            }else if(top<56){
              probe.cells.put(floor,(random.nextBoolean()?Blocks.STONE:Blocks.PALE_MOSS_BLOCK).defaultBlockState());
              probe.cells.put(above,Blocks.PALE_MOSS_CARPET.defaultBlockState());
            }else if(top<70){
              boolean crimson=random.nextBoolean();
              probe.cells.put(floor,(crimson?Blocks.CRIMSON_NYLIUM:Blocks.WARPED_NYLIUM).defaultBlockState());
              // Now and then on the other nylium, where it does not grow.
              if(random.nextInt(4)>0)probe.cells.put(above,(crimson?Blocks.CRIMSON_FUNGUS:Blocks.WARPED_FUNGUS).defaultBlockState());
              else probe.cells.put(above,(crimson?Blocks.WARPED_FUNGUS:Blocks.CRIMSON_FUNGUS).defaultBlockState());
            }else if(top<85){
              probe.cells.put(floor,Blocks.NETHERRACK.defaultBlockState());
              if(random.nextInt(4)==0)probe.cells.put(above,(random.nextBoolean()?Blocks.STONE:Blocks.GLASS).defaultBlockState());
            }else probe.cells.put(floor,(random.nextBoolean()?Blocks.CRIMSON_NYLIUM:Blocks.WARPED_NYLIUM).defaultBlockState());
          }else{
            // Nether plants, cocoa, and vines, roots and leaves under a ceiling.
            var ceiling=floor.above(5);
            int top=random.nextInt(100);
            probe.cells.put(floor,Blocks.DIRT.defaultBlockState());
            if(top<15){probe.cells.put(floor,Blocks.SOUL_SAND.defaultBlockState());probe.cells.put(above,Blocks.NETHER_WART.defaultBlockState().setValue(NetherWartBlock.AGE,random.nextInt(4)));}
            else if(top<28){probe.cells.put(floor,Blocks.NETHERRACK.defaultBlockState());plant(probe,random,above,true,1+random.nextInt(3),Blocks.TWISTING_VINES,Blocks.TWISTING_VINES_PLANT);}
            else if(top<42){
              probe.cells.put(floor,(random.nextBoolean()?Blocks.CRIMSON_NYLIUM:Blocks.WARPED_NYLIUM).defaultBlockState());
              int cover=random.nextInt(4);
              if(cover==1)probe.cells.put(above,Blocks.STONE.defaultBlockState());
              else if(cover==2)probe.cells.put(above,Blocks.STONE_SLAB.defaultBlockState());
            }else if(top<55){
              probe.cells.put(above,Blocks.JUNGLE_LOG.defaultBlockState());
              var facing=Direction.Plane.HORIZONTAL.getRandomDirection(RandomSource.create(random.nextLong()));
              probe.cells.put(above.relative(facing.getOpposite()),Blocks.COCOA.defaultBlockState().setValue(CocoaBlock.FACING,facing).setValue(CocoaBlock.AGE,random.nextInt(3)));
            }else if(top<68){probe.cells.put(ceiling,Blocks.NETHERRACK.defaultBlockState());plant(probe,random,ceiling.below(),false,1+random.nextInt(3),Blocks.WEEPING_VINES,Blocks.WEEPING_VINES_PLANT);}
            else if(top<80){probe.cells.put(ceiling,Blocks.STONE.defaultBlockState());plant(probe,random,ceiling.below(),false,1+random.nextInt(3),Blocks.CAVE_VINES,Blocks.CAVE_VINES_PLANT);}
            else if(top<88)probe.cells.put(ceiling,Blocks.ROOTED_DIRT.defaultBlockState());
            else if(top<95)probe.cells.put(ceiling,Blocks.MANGROVE_LEAVES.defaultBlockState().setValue(LeavesBlock.PERSISTENT,true));
          }
        }
      }
      var cells=new JsonArray();
      var sorted=new ArrayList<>(probe.cells.keySet());sorted.sort(Comparator.naturalOrder());
      for(var pos:sorted)cells.add(row(pos,Block.getId(probe.cells.get(pos))));
      var steps=new JsonArray();
      for(int t=0;t<400;t++){
        probe.time=t;probe.writes=new JsonArray();probe.events=new JsonArray();var results=new JsonArray();
        var now=new ArrayList<JsonArray>();
        // A few random ticks a tick, a bone meal now and then, a change now and then.
        int ticks=random.nextInt(5);
        for(int i=0;i<ticks;i++)now.add(action("random"));
        if(random.nextInt(6)==0)now.add(action("bone_meal"));
        if(random.nextInt(20)==0)now.add(action("set"));
        for(var action:now){
          var kind=action.get(0).getAsString();
          var candidates=new ArrayList<BlockPos>();
          for(var entry:probe.cells.entrySet()){
            var state=entry.getValue();var pos=entry.getKey();
            // Bone meal on the sea bed's top face reaches the water above it.
            boolean water=pos.getY()==FLOOR_Y&&probe.cell(pos.above()).is(Blocks.WATER);
            if(kind.equals("random")?state.isRandomlyTicking():kind.equals("bone_meal")?boneMealTarget(state)||water
              :pos.getY()>=FLOOR_Y&&!state.isAir())candidates.add(pos);
          }
          if(candidates.isEmpty()){results.add(0);continue;}
          candidates.sort(Comparator.naturalOrder());
          var pos=candidates.get(random.nextInt(candidates.size()));
          action.add(pos.getX());action.add(pos.getY());action.add(pos.getZ());
          var state=probe.cell(pos);
          switch(kind){
            case "random"->{
              int result=0;
              try{
                state.randomTick(probe,pos,probe.random);
                var fluid=state.getFluidState();if(fluid.isRandomlyTicking())fluid.randomTick(probe,pos,probe.random);
              }catch(Grow g){result=2;}
              bump(count,"random "+result);
              results.add(result);
            }
            case "bone_meal"->{
              // Clicked on its top face.
              action.add(Direction.UP.get3DDataValue());
              int result=useBoneMeal(probe,pos,Direction.UP);
              bump(count,"bone meal "+result);
              results.add(result);
            }
            default->{
              // Remove a plant or fruit, cover farmland, add or take water.
              int roll=random.nextInt(4);
              BlockState to=roll==0?Blocks.STONE.defaultBlockState():roll==1?Blocks.WATER.defaultBlockState():Blocks.AIR.defaultBlockState();
              if(roll==0)pos=pos.above();
              action.set(1,new JsonPrimitive(pos.getX()));action.set(2,new JsonPrimitive(pos.getY()));action.set(3,new JsonPrimitive(pos.getZ()));
              action.add(Block.getId(to));
              probe.setBlock(pos,to,Block.UPDATE_ALL);
            }
          }
        }
        probe.blockTicks.tick(t,65536,(pos,block)->invoke(tickBlock,probe,pos,block));
        var before=new HashMap<BlockPos,BlockState>();
        for(var w:probe.writes){
          var row=w.getAsJsonArray();var written=Block.stateById(row.get(3).getAsInt());
          var name=BuiltInRegistries.BLOCK.getKey(written.getBlock()).getPath();
          if(written.getBlock() instanceof CropBlock||written.getBlock() instanceof StemBlock)name="crop or stem";
          if(written.getBlock() instanceof SaplingBlock&&written.hasProperty(SaplingBlock.STAGE)&&written.getValue(SaplingBlock.STAGE)==1)name="sapling stage";
          if(written.is(Blocks.FARMLAND))name=written.getValue(FarmlandBlock.MOISTURE)<7?"farmland dried":"farmland wetted";
          if(written.getBlock() instanceof BaseCoralPlantTypeBlock)name="coral";
          bump(count,"write "+name);
        }
        for(var e:probe.events)if(e.getAsJsonArray().get(3).getAsInt()==2001)bump(count,"broken");
        if(!now.isEmpty()||!probe.writes.isEmpty()||!probe.events.isEmpty()){
          var step=new JsonObject();step.addProperty("t",t);
          var acts=new JsonArray();now.forEach(acts::add);step.add("actions",acts);step.add("results",results);
          step.add("writes",probe.writes);step.add("events",probe.events);steps.add(step);
        }
      }
      var scene=new JsonObject();scene.addProperty("seed",levelSeed);scene.addProperty("sky",probe.sky);
      scene.addProperty("darken",probe.darken);scene.addProperty("rain",probe.rain);scene.addProperty("corals",corals);
      scene.add("cells",cells);scene.add("steps",steps);scenes.add(scene);
    }
    var result=new JsonObject();result.add("scenes",scenes);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    // Each behaviour shows up: (what, at least).
    Object[][] wanted={{"write crop or stem",200},{"write pumpkin",5},{"write sugar_cane",50},{"write cactus",50},{"write cactus_flower",3},
      {"write farmland dried",15},{"write farmland wetted",50},{"write dirt",5},{"write sapling stage",20},{"random 2",10},{"bone meal 2",5},
      {"bone meal 1",100},{"bone meal 3",10},{"broken",5},{"write grass_block",30},{"write mycelium",5},{"write netherrack",3},
      {"write torchflower",3},{"write pitcher_crop",20},{"write nether_wart",10},{"write cocoa",10},{"write sweet_berry_bush",20},
      {"write kelp",20},{"write weeping_vines",5},{"write twisting_vines",5},{"write cave_vines",5},{"write cave_vines_plant",3},
      {"write tall_grass",5},{"write large_fern",3},{"write pink_petals",3},{"write wildflowers",3},{"write tall_seagrass",5},
      {"write seagrass",30},{"write coral",3},{"write sea_pickle",3},{"write bush",3},{"write short_dry_grass",3},{"write tall_dry_grass",3},
      {"write hanging_roots",3},{"write mangrove_propagule",3},{"write bamboo",40},{"write glow_lichen",10},{"write big_dripleaf",10},
      {"write big_dripleaf_stem",10},{"write crimson_nylium",5},{"write warped_nylium",5},{"write pale_hanging_moss",5},
      {"write pale_moss_carpet",5}};
    var missing=new ArrayList<String>();
    for(var w:wanted)if(count.getOrDefault((String)w[0],0)<(int)w[1])missing.add(w[0]+" "+count.getOrDefault((String)w[0],0));
    if(!missing.isEmpty())throw new AssertionError("scenes miss a behaviour: "+missing+"; "+count);
    System.out.println("PASS: "+sceneCount+" growth scenes; "+count);
  }

  static void bump(Map<String,Integer> count,String key){count.merge(key,1,Integer::sum);}

  static void invoke(Method method,Probe probe,BlockPos pos,Object type){
    try{method.invoke(probe,pos,type);}catch(Exception e){throw new RuntimeException(e);}
  }

  static void trees(String out,int count,long seed)throws Exception{
    var probe=probe(seed);var random=new Random(seed);
    Block[] SAPLINGS={Blocks.OAK_SAPLING,Blocks.SPRUCE_SAPLING,Blocks.BIRCH_SAPLING,Blocks.JUNGLE_SAPLING,Blocks.ACACIA_SAPLING,
      Blocks.CHERRY_SAPLING,Blocks.DARK_OAK_SAPLING,Blocks.PALE_OAK_SAPLING,Blocks.POPLAR_SAPLING,Blocks.MANGROVE_PROPAGULE,
      Blocks.AZALEA,Blocks.FLOWERING_AZALEA};
    var cases=new JsonArray();int grown=0,failed=0,mega=0,flowered=0;
    for(int c=0;c<count;c++){
      probe.cells=new HashMap<>();probe.writes=new JsonArray();probe.events=new JsonArray();
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-32)>>4;cx<=(MAX_X+32)>>4;cx++)for(int cz=(MIN_Z-32)>>4;cz<=(MAX_Z+32)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      var block=SAPLINGS[c%SAPLINGS.length];
      // Near a chunk corner, so trees cross chunk lines.
      var pos=new BlockPos(120+random.nextInt(16),FLOOR_Y+1,-8+random.nextInt(16));
      var ground=new Block[]{Blocks.DIRT,Blocks.GRASS_BLOCK,Blocks.PODZOL,Blocks.MUD}[random.nextInt(4)];
      for(int x=-3;x<=3;x++)for(int z=-3;z<=3;z++){
        probe.cells.put(pos.offset(x,-1,z),ground.defaultBlockState());
        probe.cells.put(pos.offset(x,-2,z),Blocks.STONE.defaultBlockState());
      }
      var sapling=block.defaultBlockState();
      if(sapling.hasProperty(SaplingBlock.STAGE))sapling=sapling.setValue(SaplingBlock.STAGE,1);
      probe.cells.put(pos,sapling);
      if(random.nextInt(3)==0){
        mega++;
        int dx=-random.nextInt(2),dz=-random.nextInt(2);
        for(int i=0;i<4;i++)probe.cells.put(pos.offset(dx+(i&1),0,dz+(i>>1)),sapling);
      }
      if(random.nextInt(3)==0){flowered++;probe.cells.put(pos.offset(2,0,random.nextInt(5)-2),Blocks.POPPY.defaultBlockState());}
      // Obstacles: a block over the plot, leaves beside it.
      int roll=random.nextInt(4);
      if(roll==0)probe.cells.put(pos.above(2+random.nextInt(8)),Blocks.STONE.defaultBlockState());
      else if(roll==1)probe.cells.put(pos.offset(random.nextInt(5)-2,1+random.nextInt(5),random.nextInt(5)-2),Blocks.OAK_LEAVES.defaultBlockState());
      var cells=new JsonArray();
      var sorted=new ArrayList<>(probe.cells.keySet());sorted.sort(Comparator.naturalOrder());
      for(var p:sorted)cells.add(row(p,Block.getId(probe.cells.get(p))));
      long treeSeed=random.nextLong();
      var grower=block instanceof SaplingBlock?(TreeGrower)field(block,SaplingBlock.class,"treeGrower"):TreeGrower.AZALEA;
      boolean placed=grower.growTree(probe,null,pos,probe.cell(pos),RandomSource.create(treeSeed));
      if(placed)grown++;else failed++;
      var json=new JsonObject();json.add("cells",cells);json.add("pos",row(pos));json.addProperty("seed",treeSeed);
      json.addProperty("grown",placed);json.addProperty("kind","tree");json.addProperty("biome","minecraft:plains");
      json.add("writes",probe.writes);cases.add(json);
    }
    var result=new JsonObject();result.add("cases",cases);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    if(grown<count/3||failed<10||mega<count/5||flowered<count/5)
      throw new AssertionError("trees miss a case: grown "+grown+", failed "+failed+", mega "+mega+", flowers "+flowered);
    System.out.println("PASS: "+count+" trees; "+grown+" grown, "+failed+" failed, "+mega+" with a 2 x 2, "+flowered+" by flowers");
  }

  /**
   * What bone meal places through the generator: on a grass block (`GrassBlock.performBonemeal`, in
   * a biome with bone meal features or none), nylium and moss (their feature above), and a
   * mushroom's huge mushroom (`growMushroom`), on a bumpy plot with covers about it, with
   * `RandomSource.create(seed)` as the random.
   */
  static void features(String out,int count,long seed)throws Exception{
    var probe=probe(seed);var random=new Random(seed);
    var unsafe=(sun.misc.Unsafe)field(null,sun.misc.Unsafe.class,"theUnsafe");
    probe.chunks=(Chunks)unsafe.allocateInstance(Chunks.class);
    probe.chunks.generator=(net.minecraft.world.level.chunk.ChunkGenerator)unsafe.allocateInstance(net.minecraft.world.level.levelgen.DebugLevelSource.class);
    var biomes=probe.access.lookupOrThrow(net.minecraft.core.registries.Registries.BIOME);
    String[] BIOMES={"plains","sunflower_plains","flower_forest","meadow","cherry_grove","swamp","birch_forest","pale_garden","forest","warm_ocean"};
    var cases=new JsonArray();var kinds=new TreeMap<String,Integer>();int changed=0;
    for(int c=0;c<count;c++){
      probe.cells=new HashMap<>();probe.writes=new JsonArray();probe.events=new JsonArray();
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-32)>>4;cx<=(MAX_X+32)>>4;cx++)for(int cz=(MIN_Z-32)>>4;cz<=(MAX_Z+32)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      var biome="minecraft:"+BIOMES[random.nextInt(BIOMES.length)];
      probe.biome=biomes.getOrThrow(net.minecraft.resources.ResourceKey.create(net.minecraft.core.registries.Registries.BIOME,net.minecraft.resources.Identifier.parse(biome)));
      String kind=new String[]{"grass","grass","grass","mushroom","moss","nylium","fungus"}[random.nextInt(7)];
      boolean crimson=random.nextBoolean();
      Block ground=switch(kind){case "mushroom"->new Block[]{Blocks.DIRT,Blocks.MYCELIUM,Blocks.PODZOL}[random.nextInt(3)];
        case "moss"->Blocks.STONE;case "nylium"->Blocks.NETHERRACK;case "fungus"->crimson?Blocks.CRIMSON_NYLIUM:Blocks.WARPED_NYLIUM;
        default->Blocks.GRASS_BLOCK;};
      // Near a chunk corner, so what grows crosses chunk lines.
      var pos=new BlockPos(120+random.nextInt(16),FLOOR_Y,-8+random.nextInt(16));
      for(int x=-8;x<=8;x++)for(int z=-8;z<=8;z++){
        var floor=pos.offset(x,random.nextInt(8)==0?1:random.nextInt(8)==0?-1:0,z);
        probe.cells.put(floor.below(),Blocks.STONE.defaultBlockState());
        int roll=random.nextInt(100);
        var at=roll<75?ground:roll<85?Blocks.DIRT:roll<92?Blocks.STONE:kind.equals("nylium")?Blocks.WARPED_NYLIUM:Blocks.GRASS_BLOCK;
        probe.cells.put(floor,at.defaultBlockState());
        int top=random.nextInt(100);
        if(top<12)probe.cells.put(floor.above(),(kind.equals("fungus")?(crimson?Blocks.CRIMSON_ROOTS:Blocks.NETHER_SPROUTS):Blocks.SHORT_GRASS).defaultBlockState());
        else if(top<16)probe.cells.put(floor.above(),Blocks.STONE.defaultBlockState());
        else if(top<18)probe.cells.put(floor.above(),Blocks.POPPY.defaultBlockState());
      }
      var self=switch(kind){case "mushroom"->(random.nextBoolean()?Blocks.BROWN_MUSHROOM:Blocks.RED_MUSHROOM).defaultBlockState();
        case "fungus"->(crimson?Blocks.CRIMSON_FUNGUS:Blocks.WARPED_FUNGUS).defaultBlockState();
        // Pale moss's carpets settle their sides by shape updates (as above): moss only.
        case "moss"->Blocks.MOSS_BLOCK.defaultBlockState();
        case "nylium"->(random.nextBoolean()?Blocks.CRIMSON_NYLIUM:Blocks.WARPED_NYLIUM).defaultBlockState();
        default->Blocks.GRASS_BLOCK.defaultBlockState();};
      boolean plant=kind.equals("mushroom")||kind.equals("fungus");
      if(plant){pos=pos.above();probe.cells.put(pos.below(),ground.defaultBlockState());}
      probe.cells.put(pos,self);
      if(!plant)probe.cells.remove(pos.above());
      // A cover over the mushroom or fungus now and then.
      if(plant&&random.nextInt(3)==0)probe.cells.put(pos.above(2+random.nextInt(6)),Blocks.STONE.defaultBlockState());
      // Only covers that stand: vanilla's shape updates take the rest as features write beside them,
      // which ValiMC's owner runs once the placement commits, not the generator.
      for(var p:new ArrayList<>(probe.cells.keySet())){
        var state=probe.cells.get(p);
        if((state.is(Blocks.SHORT_GRASS)||state.is(Blocks.POPPY)||state.is(Blocks.CRIMSON_ROOTS)||state.is(Blocks.NETHER_SPROUTS))
          &&!state.canSurvive(probe,p))probe.cells.remove(p);
      }
      var cells=new JsonArray();
      var sorted=new ArrayList<>(probe.cells.keySet());sorted.sort(Comparator.naturalOrder());
      for(var p:sorted)cells.add(row(p,Block.getId(probe.cells.get(p))));
      long caseSeed=random.nextLong();var r=RandomSource.create(caseSeed);
      boolean grown=true;
      var block=self.getBlock();
      if(block instanceof MushroomBlock m)grown=m.growMushroom(probe,pos,self,r);
      else ((BonemealableBlock)block).performBonemeal(probe,r,pos,self,BonemealSource.INTERACTION);
      if(probe.writes.size()>0)changed++;
      kinds.merge(kind+(grown?"":" failed"),1,Integer::sum);
      var json=new JsonObject();json.add("cells",cells);json.add("pos",row(pos));json.addProperty("seed",caseSeed);
      json.addProperty("biome",biome);json.addProperty("kind",kind);json.addProperty("grown",grown);json.add("writes",probe.writes);cases.add(json);
    }
    var result=new JsonObject();result.add("cases",cases);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    if(changed<count*3/4||kinds.getOrDefault("mushroom",0)<10||kinds.getOrDefault("mushroom failed",0)<5||kinds.getOrDefault("fungus",0)<20)
      throw new AssertionError("bone meal features miss a case: "+kinds+", "+changed+" changed");
    System.out.println("PASS: "+count+" bone meal features; "+kinds+", "+changed+" changed");
  }

  static void transformers(String out)throws Exception{
    var probe=probe(0);var origin=new BlockPos(0,64,0);
    var registry=probe.access.lookupOrThrow(net.minecraft.core.registries.Registries.BLOCK_TRANSFORMER);
    var items=new TreeMap<String,String>();
    for(var item:BuiltInRegistries.ITEM){
      var holder=item.components().get(net.minecraft.core.component.DataComponents.BLOCK_TRANSFORMER);
      if(holder!=null)items.put(BuiltInRegistries.ITEM.getKey(item).getPath(),holder.unwrapKey().orElseThrow().identifier().getPath());
    }
    var transformers=new JsonObject();int rows=0;
    var keys=new ArrayList<>(registry.listElements().toList());
    keys.sort(Comparator.comparing(h->h.key().identifier().toString()));
    BlockState[] open={Blocks.AIR.defaultBlockState(),Blocks.CAVE_AIR.defaultBlockState()};
    BlockState[] closed={Blocks.STONE.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.OAK_LEAVES.defaultBlockState()};
    for(var holder:keys){
      var entries=new JsonArray();
      for(var data:holder.value().transforms()){
        var json=new JsonObject();
        var faces=new JsonArray();data.disallowedFaces().forEach(f->faces.add(f.getSerializedName()));json.add("disallowed_faces",faces);
        json.addProperty("sound",data.sound().value().location().toString());
        json.addProperty("particle",(int)field(data.particle(),net.minecraft.core.component.BlockTransformer.TransformParticle.class,"levelEvent"));
        json.addProperty("loot",data.loot().map(k->k.identifier().toString()).orElse(null));
        json.addProperty("drop",data.dropStrategy().getSerializedName());
        json.addProperty("update_from_neighbors",data.updateFromNeighbors());
        json.addProperty("type",data.transformType().getSerializedName());
        json.addProperty("consume",data.consumeOnUse());
        json.addProperty("damage",data.itemDamagePerUse());
        var results=new JsonArray();
        var provider=data.blockStateProvider().value();
        for(int id=0;id<Block.BLOCK_STATE_REGISTRY.size();id++){
          var state=Block.stateById(id);
          int[] got=new int[2];
          for(int a=0;a<2;a++){
            var tops=a==0?open:closed;Integer seen=null;
            for(var top:tops)for(boolean walls:new boolean[]{false,true})for(long seed:new long[]{1,2}){
              probe.cells=new HashMap<>();probe.cells.put(origin,state);probe.cells.put(origin.above(),top);
              if(walls)for(var d:Direction.values())if(d!=Direction.UP)probe.cells.put(origin.relative(d),Blocks.STONE.defaultBlockState());
              var result=provider.getOptionalState(probe,RandomSource.create(seed),origin);
              int value=result==null?-1:Block.getId(result);
              if(seen!=null&&seen!=value)throw new AssertionError("a block transformer reads more than the cell and the one above: "+holder.key()+" "+state);
              seen=value;
            }
            got[a]=seen;
          }
          if(got[0]!=-1||got[1]!=-1){var row=new JsonArray();row.add(id);row.add(got[0]);row.add(got[1]);results.add(row);rows++;}
        }
        json.add("results",results);entries.add(json);
      }
      transformers.add(holder.key().identifier().getPath(),entries);
    }
    var result=FluidOracle.stamped(Block.BLOCK_STATE_REGISTRY.size());
    var i=new JsonObject();items.forEach(i::addProperty);result.add("items",i);result.add("transformers",transformers);
    Files.writeString(Path.of(out),new GsonBuilder().create().toJson(result)+"\n");
    System.out.println("PASS: "+keys.size()+" block transformers on "+items.size()+" items, "+rows+" transforming states");
  }

  static JsonArray action(String kind){var a=new JsonArray();a.add(kind);return a;}
}
