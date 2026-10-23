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
 * Plants that grow (VMC-039a), from pinned 26.3. Two modes:
 *
 * - `facts OUT`: the tree growers (`TreeGrower.GROWERS`: per grower its weighted tree, mega
 *   tree and flower tree features and `getMinimumHeight`) and each `SaplingBlock`'s grower.
 * - `scenes OUT [SCENES [SEED]]`: farms, cane and cactus beds and saplings over a probe level whose
 *   block ticks are vanilla's own `LevelTicks`; one sky light for every cell (no block light), one
 *   `skyDarken` and rain or not per scene. Each game tick applies its actions in order
 *   (`/setblock`-style `setBlock(UPDATE_ALL)`; a random tick as `ServerLevel.tickChunk` runs one
 *   at a randomly ticking cell; bone meal as `BoneMealItem.growCrop`, with `useOn`'s level event
 *   when it took the bone meal), then runs the due block
 *   ticks. A sapling that would grow its tree stops at `level.getChunkSource()` (the tree is the
 *   generator's, checked apart): the action's result is 2. Per tick the cell writes in order, the
 *   level events and each random tick's and bone meal's result (0 nothing, 1 bone meal used, 2 a
 *   tree grows). Fluid ticks are scheduled but never run.
 *
 * - `trees OUT [CASES [SEED]]`: `TreeGrower.growTree` of a sapling (or a 2 x 2 of them, a
 *   propagule) on a small plot with flowers and obstacles about it, with `RandomSource.create(seed)`
 *   as the random: whether it grew, and the cell writes in order.
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
 * Usage: GrowthOracle (facts|scenes|trees|transformers) OUT [COUNT [SEED]]
 */
public class GrowthOracle {
  static final int FLOOR_Y=60,MIN_X=120,MAX_X=136,MIN_Z=-8,MAX_Z=8;

  /** A tree that would grow: the probe stops the sapling where it asks for the generator. */
  static class Grow extends RuntimeException {Grow(){super(null,null,false,false);}}

  static class Server extends net.minecraft.server.dedicated.DedicatedServer {
    net.minecraft.server.ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }

  static class Probe extends ServerLevel {
    Map<BlockPos,BlockState> cells;Server server;RandomSource random;GameRules rules;RegistryAccess access;
    LevelTicks<Block> blockTicks;LevelTicks<Fluid> fluidTicks;long time,subTick;int sky,darken;boolean rain;
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
    @Override public ServerChunkCache getChunkSource(){throw new Grow();}
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
    @Override public boolean addFreshEntity(Entity entity){return false;}
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
    var result=FluidOracle.stamped(Block.BLOCK_STATE_REGISTRY.size());
    var g=new JsonObject();growers.forEach(g::add);result.add("growers",g);
    var s=new JsonObject();saplings.forEach(s::addProperty);result.add("saplings",s);
    Files.writeString(Path.of(out),new GsonBuilder().create().toJson(result)+"\n");
    System.out.println("PASS: "+growers.size()+" tree growers, "+saplings.size()+" saplings");
  }


  static <T extends Comparable<T>> BlockState with(BlockState state,net.minecraft.world.level.block.state.properties.Property<T> property,Random random){
    var values=new ArrayList<>(property.getPossibleValues());
    return state.setValue(property,values.get(random.nextInt(values.size())));
  }

  /** What bone meal may be tried on: the plants this slice grows and blocks it does not. */
  static boolean boneMealTarget(BlockState state){
    return state.getBlock() instanceof CropBlock||state.getBlock() instanceof StemBlock||state.getBlock() instanceof SaplingBlock
      ||state.is(Blocks.SUGAR_CANE)||state.is(Blocks.CACTUS)||state.is(Blocks.FARMLAND)||state.is(Blocks.ATTACHED_PUMPKIN_STEM);
  }

  static void scenes(String out,int sceneCount,long seed)throws Exception{
    var probe=probe(seed);var random=new Random(seed);
    Block[] CROPS={Blocks.WHEAT,Blocks.CARROTS,Blocks.POTATOES,Blocks.BEETROOTS};
    Block[] SAPLINGS={Blocks.OAK_SAPLING,Blocks.SPRUCE_SAPLING,Blocks.BIRCH_SAPLING,Blocks.JUNGLE_SAPLING,
      Blocks.ACACIA_SAPLING,Blocks.CHERRY_SAPLING,Blocks.DARK_OAK_SAPLING,Blocks.PALE_OAK_SAPLING,Blocks.POPLAR_SAPLING};
    Method tickBlock=ServerLevel.class.getDeclaredMethod("tickBlock",BlockPos.class,Block.class);tickBlock.setAccessible(true);
    var scenes=new JsonArray();
    int crops=0,stems=0,fruits=0,canes=0,cacti=0,flowers=0,dried=0,wetted=0,dirt=0,stages=0,trees=0,meals=0,used=0,broken=0;
    for(int s=0;s<sceneCount;s++){
      long levelSeed=random.nextLong();probe.random=RandomSource.create(levelSeed);
      probe.time=0;probe.subTick=0;
      probe.sky=8+random.nextInt(8);probe.darken=new int[]{0,0,4,11}[random.nextInt(4)];probe.rain=random.nextInt(4)==0;
      probe.blockTicks=new LevelTicks<>(p->true);probe.fluidTicks=new LevelTicks<>(p->true);
      for(int cx=(MIN_X-16)>>4;cx<=(MAX_X+16)>>4;cx++)for(int cz=(MIN_Z-16)>>4;cz<=(MAX_Z+16)>>4;cz++){
        probe.blockTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
        probe.fluidTicks.addContainer(new net.minecraft.world.level.ChunkPos(cx,cz),new LevelChunkTicks<>());
      }
      probe.cells=new HashMap<>();
      // One plot kind per 4 x 4 plot: a farm, a cane and cactus bed, or saplings.
      for(int px=MIN_X;px<MAX_X;px+=4)for(int pz=MIN_Z;pz<MAX_Z;pz+=4){
        int plot=random.nextInt(3);
        for(int x=px;x<px+4;x++)for(int z=pz;z<pz+4;z++){
          var floor=new BlockPos(x,FLOOR_Y,z);var above=floor.above();
          probe.cells.put(floor.below(),Blocks.STONE.defaultBlockState());
          int roll=random.nextInt(100);
          if(roll<8){probe.cells.put(floor,Blocks.WATER.defaultBlockState());continue;}
          if(plot==0){
            if(roll<80){
              probe.cells.put(floor,with(Blocks.FARMLAND.defaultBlockState(),FarmlandBlock.MOISTURE,random));
              int top=random.nextInt(100);
              if(top<45){var crop=(CropBlock)CROPS[random.nextInt(CROPS.length)];probe.cells.put(above,crop.getStateForAge(random.nextInt(crop.getMaxAge()+1)));}
              else if(top<60){var stem=(random.nextBoolean()?Blocks.PUMPKIN_STEM:Blocks.MELON_STEM).defaultBlockState();
                probe.cells.put(above,stem.setValue(StemBlock.AGE,random.nextInt(3)==0?7:random.nextInt(8)));}
              else if(top<65)probe.cells.put(above,Blocks.STONE.defaultBlockState());
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
          }else{
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
        if(random.nextInt(8)==0)now.add(action("bone_meal"));
        if(random.nextInt(20)==0)now.add(action("set"));
        for(var action:now){
          var kind=action.get(0).getAsString();
          var candidates=new ArrayList<BlockPos>();
          for(var entry:probe.cells.entrySet()){
            var state=entry.getValue();
            if(kind.equals("random")?state.isRandomlyTicking():kind.equals("bone_meal")?boneMealTarget(state)
              :entry.getKey().getY()>=FLOOR_Y&&!state.isAir())candidates.add(entry.getKey());
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
              }catch(Grow g){result=2;trees++;}
              results.add(result);
            }
            case "bone_meal"->{
              int result;
              try{result=BoneMealItem.growCrop(new ItemStack(Items.BONE_MEAL),probe,pos)?1:0;}catch(Grow g){result=2;trees++;}
              // `BoneMealItem.useOn`'s particles once `growCrop` took it.
              if(result>0){used++;probe.levelEvent(null,1505,pos,15);}
              meals++;results.add(result);
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
        for(var w:probe.writes){
          var row=w.getAsJsonArray();var written=Block.stateById(row.get(3).getAsInt());
          if(written.getBlock() instanceof CropBlock)crops++;
          if(written.getBlock() instanceof StemBlock)stems++;
          if(written.is(Blocks.PUMPKIN)||written.is(Blocks.MELON))fruits++;
          if(written.is(Blocks.SUGAR_CANE))canes++;
          if(written.is(Blocks.CACTUS))cacti++;
          if(written.is(Blocks.CACTUS_FLOWER))flowers++;
          if(written.is(Blocks.FARMLAND)&&written.getValue(FarmlandBlock.MOISTURE)<7)dried++;
          if(written.is(Blocks.FARMLAND)&&written.getValue(FarmlandBlock.MOISTURE)==7)wetted++;
          if(written.is(Blocks.DIRT))dirt++;
          if(written.getBlock() instanceof SaplingBlock&&written.hasProperty(SaplingBlock.STAGE)&&written.getValue(SaplingBlock.STAGE)==1)stages++;
        }
        for(var e:probe.events)if(e.getAsJsonArray().get(3).getAsInt()==2001)broken++;
        if(!now.isEmpty()||!probe.writes.isEmpty()||!probe.events.isEmpty()){
          var step=new JsonObject();step.addProperty("t",t);
          var acts=new JsonArray();now.forEach(acts::add);step.add("actions",acts);step.add("results",results);
          step.add("writes",probe.writes);step.add("events",probe.events);steps.add(step);
        }
      }
      var scene=new JsonObject();scene.addProperty("seed",levelSeed);scene.addProperty("sky",probe.sky);
      scene.addProperty("darken",probe.darken);scene.addProperty("rain",probe.rain);
      scene.add("cells",cells);scene.add("steps",steps);scenes.add(scene);
    }
    var result=new JsonObject();result.add("scenes",scenes);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    var counts=String.format("crops %d, stems %d, fruits %d, canes %d, cacti %d, cactus flowers %d, farmland dried %d, wetted %d, dirt %d, sapling stages %d, trees %d, bone meal %d (%d used), broken %d",
      crops,stems,fruits,canes,cacti,flowers,dried,wetted,dirt,stages,trees,meals,used,broken);
    if(crops<200||stems<50||fruits<10||canes<50||cacti<50||flowers<3||dried<50||wetted<50||dirt<5||stages<20||trees<20||used<100||broken<5)
      throw new AssertionError("scenes miss a behaviour: "+counts);
    System.out.println("PASS: "+sceneCount+" growth scenes; "+counts);
  }

  static void invoke(Method method,Probe probe,BlockPos pos,Object type){
    try{method.invoke(probe,pos,type);}catch(Exception e){throw new RuntimeException(e);}
  }

  static void trees(String out,int count,long seed)throws Exception{
    var probe=probe(seed);var random=new Random(seed);
    Block[] SAPLINGS={Blocks.OAK_SAPLING,Blocks.SPRUCE_SAPLING,Blocks.BIRCH_SAPLING,Blocks.JUNGLE_SAPLING,Blocks.ACACIA_SAPLING,
      Blocks.CHERRY_SAPLING,Blocks.DARK_OAK_SAPLING,Blocks.PALE_OAK_SAPLING,Blocks.POPLAR_SAPLING,Blocks.MANGROVE_PROPAGULE};
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
      var grower=(TreeGrower)field(block,SaplingBlock.class,"treeGrower");
      boolean placed=grower.growTree(probe,null,pos,probe.cell(pos),RandomSource.create(treeSeed));
      if(placed)grown++;else failed++;
      var json=new JsonObject();json.add("cells",cells);json.add("pos",row(pos));json.addProperty("seed",treeSeed);
      json.addProperty("grown",placed);json.add("writes",probe.writes);cases.add(json);
    }
    var result=new JsonObject();result.add("cases",cases);
    Files.writeString(Path.of(out),new Gson().toJson(result)+"\n");
    if(grown<count/3||failed<10||mega<count/5||flowered<count/5)
      throw new AssertionError("trees miss a case: grown "+grown+", failed "+failed+", mega "+mega+", flowers "+flowered);
    System.out.println("PASS: "+count+" trees; "+grown+" grown, "+failed+" failed, "+mega+" with a 2 x 2, "+flowered+" by flowers");
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
