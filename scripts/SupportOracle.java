import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.stream.IntStream;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.level.material.*;
import net.minecraft.world.flag.FeatureFlags;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;

/**
 * Original survival-rule extraction (VMC-029c). Vanilla's own canSurvive and updateShape run
 * against a synthetic world that records every position read. Per state the oracle finds the
 * offsets canSurvive reads, partitions all states at each offset into classes that give the
 * same result and read the same positions in every context (refined until stable), and
 * tabulates survival over all class combinations. updateShape then gives, per direction,
 * whether an update breaks the state at once, schedules its tick or does nothing while it
 * cannot survive, and which neighbours break it although it can (two-block halves). Light
 * reads are existential: a state survives if bright or dark light lets it.
 * Usage: SupportOracle FACTS.json CASES.json, or SupportOracle worldgen SURVIVAL.json: survival
 * as decoration checks it (VMC-025), before the block is placed, so the block's own position
 * is read like any neighbour, under the light of unlit chunks (sky 15, block 0); per state its
 * rule, with the same partitions and tables.
 */
public class SupportOracle {
  static final class Unsupported extends RuntimeException {
    Unsupported(String reason){super(reason,null,false,false);}
  }
  static final Direction[] DIRS=Direction.values();
  static final BlockPos ORIGIN=new BlockPos(0,64,0);
  // Offsets within ±R of the origin are small indexes into a W³ cube.
  static final int R=4,W=2*R+1,CELLS=W*W*W,SELF=index(0,0,0);
  static final int MAX_OFFSETS=8,FULL_CONTEXTS=64,MAX_TABLE=65536;
  static boolean WORLDGEN;
  static BlockState[] STATES;static int COUNT;static BlockState AIR;
  static int index(int dx,int dy,int dz){return ((dx+R)*W+(dy+R))*W+(dz+R);}
  static int index(Direction d){return index(d.getStepX(),d.getStepY(),d.getStepZ());}
  static int[] offset(int i){return new int[]{i/(W*W)-R,i/W%W-R,i%W-R};}

  /** One thread's synthetic world: `self` at the origin, `cells` by offset index, air elsewhere. */
  static final class Probe implements InvocationHandler {
    BlockState self;final BlockState[] cells=new BlockState[CELLS];final int[] set=new int[CELLS];int setCount;
    final int[] stamp=new int[CELLS];int generation;int trace;final int[] reads=new int[CELLS];int readCount;
    boolean bright=true,light;final List<Integer> ticks=new ArrayList<>();TickLevel ticker;
    final RandomSource random=RandomSource.create(0L);
    final LevelReader level=(LevelReader)Proxy.newProxyInstance(LevelReader.class.getClassLoader(),new Class<?>[]{LevelReader.class},this);
    final ScheduledTickAccess tickAccess=(ScheduledTickAccess)Proxy.newProxyInstance(ScheduledTickAccess.class.getClassLoader(),new Class<?>[]{ScheduledTickAccess.class},(proxy,m,a)->{
      if(!m.getName().equals("scheduleTick"))throw new Unsupported("ticks."+m.getName());
      var p=(BlockPos)a[0];
      if(a[1] instanceof Block block&&p.equals(ORIGIN)&&block==self.getBlock())ticks.add((Integer)a[2]);
      return null;
    });
    BlockState at(BlockPos p){
      int dx=p.getX()-ORIGIN.getX(),dy=p.getY()-ORIGIN.getY(),dz=p.getZ()-ORIGIN.getZ();
      if(Math.abs(dx)>R||Math.abs(dy)>R||Math.abs(dz)>R)throw new Unsupported("far read");
      int i=index(dx,dy,dz);if(i==SELF&&!WORLDGEN)return self;
      if(stamp[i]!=generation){stamp[i]=generation;reads[readCount++]=i;trace=trace*31+i;}
      var s=cells[i];return s==null?AIR:s;
    }
    public Object invoke(Object proxy,Method m,Object[] a)throws Throwable{
      switch(m.getName()){
        case "getBlockState":return at((BlockPos)a[0]);
        case "getFluidState":return at((BlockPos)a[0]).getFluidState();
        case "getBlockEntity":return null;
        case "getMinY":if(a==null)return -64;break;
        case "getHeight":if(a==null)return 384;break;
        case "isClientSide":return false;
        case "getSeaLevel":return 63;
        case "enabledFeatures":return FeatureFlags.DEFAULT_FLAGS;
        case "getRawBrightness":case "getMaxLocalRawBrightness":light=true;return WORLDGEN||bright?15:0;
        case "getBrightness":light=true;return WORLDGEN?(a[0]==net.minecraft.world.level.LightLayer.BLOCK?0:15):bright?15:0;
        case "canSeeSky":light=true;return WORLDGEN||bright;
        case "getSkyDarken":return 0;
        case "hashCode":return System.identityHashCode(proxy);
        case "equals":return proxy==a[0];
        case "toString":return "SupportProbe";
      }
      if(m.isDefault())try{return InvocationHandler.invokeDefault(proxy,m,a);}catch(InvocationTargetException e){throw e.getCause();}
      throw new Unsupported("level."+m.getName());
    }
    void clear(){for(int k=0;k<setCount;k++)cells[set[k]]=null;setCount=0;}
    void put(int i,BlockState s){if(cells[i]==null)set[setCount++]=i;cells[i]=s;}
    void world(BlockState s,Map<Integer,BlockState> context){clear();self=s;context.forEach(this::put);}
    void begin(){generation++;readCount=0;trace=1;}
    /** canSurvive of `self` in the current cells: bright light, else dark if light was read. */
    boolean survive(){
      if(WORLDGEN){begin();light=false;return self.canSurvive(level,ORIGIN);}
      begin();light=false;bright=true;
      if(self.canSurvive(level,ORIGIN))return true;
      if(!light)return false;
      bright=false;try{return self.canSurvive(level,ORIGIN);}finally{bright=true;}
    }
    boolean survive(BlockState s,Map<Integer,BlockState> context){world(s,context);return survive();}
    /**
     * updateShape from `d` in the current cells: -1 break, n>0 a self tick n ticks later while
     * the block cannot survive (its tick breaks it), 0 otherwise.
     */
    int update(Direction d){
      begin();ticks.clear();var pos=ORIGIN.relative(d);
      var result=self.updateShape(level,tickAccess,ORIGIN,d,pos,at(pos),random);
      if(result.isAir())return -1;
      if(ticks.isEmpty())return 0;
      int delay=ticks.get(0);
      return survive()?0:delay;
    }
    BlockState cell(int i){var s=cells[i];return s==null?AIR:s;}
    int update(BlockState s,Map<Integer,BlockState> context,Direction d){world(s,context);return update(d);}
  }

  /**
   * A server level whose blocks are the probe's cells, for vanilla's own `tick`: it records
   * what the tick does to the origin (break with drops, set another state, remove).
   */
  static final class TickLevel extends net.minecraft.server.level.ServerLevel {
    // Allocated without a constructor, so fields are set by tickLevel.
    Probe probe;List<String> actions;
    private TickLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos p){return probe.at(p);}
    public FluidState getFluidState(BlockPos p){return probe.at(p).getFluidState();}
    public boolean setBlock(BlockPos p,BlockState s,int flags,int limit){actions.add(!p.equals(ORIGIN)?"other":s.isAir()?"remove":"set");return true;}
    public boolean removeBlock(BlockPos p,boolean moved){actions.add(p.equals(ORIGIN)?"remove":"other");return true;}
    public boolean destroyBlock(BlockPos p,boolean drop,net.minecraft.world.entity.Entity e,int limit){actions.add(p.equals(ORIGIN)&&drop?"destroy":"other");return true;}
    public int getRawBrightness(BlockPos p,int darkening){probe.light=true;return probe.bright?15:0;}
    public int getMaxLocalRawBrightness(BlockPos p){probe.light=true;return probe.bright?15:0;}
    public boolean canSeeSky(BlockPos p){probe.light=true;return probe.bright;}
    public RandomSource getRandom(){return probe.random;}
  }
  static TickLevel tickLevel(Probe p){
    try{
      var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
      var level=(TickLevel)((sun.misc.Unsafe)field.get(null)).allocateInstance(TickLevel.class);level.probe=p;level.actions=new ArrayList<>();return level;
    }catch(ReflectiveOperationException e){throw new AssertionError(e);}
  }
  /** A tick reaction holds only if vanilla's tick breaks the block exactly when it cannot survive. */
  static void verifyTick(Probe p,BlockState s,List<Map<Integer,BlockState>> unsupported,List<Map<Integer,BlockState>> good){
    if(p.ticker==null)p.ticker=tickLevel(p);
    for(var worlds:List.of(unsupported,good))for(var world:worlds){
      p.world(s,world);p.begin();p.ticker.actions.clear();
      try{s.tick(p.ticker,ORIGIN,p.random);}catch(Unsupported e){throw e;}catch(RuntimeException e){throw new Unsupported("tick "+e.getClass().getSimpleName());}
      var origin=p.ticker.actions.stream().filter(a->!a.equals("other")).toList();
      if(!origin.equals(worlds==unsupported?List.of("destroy"):List.of()))throw new Unsupported("tick action");
    }
  }

  record Rule(int[] offsets,int[][] classes,int[] radix,BitSet table,int size){}
  /** Neighbour overrides from one direction: per class 0 follow the rule, 1 break, 2 keep. */
  record Override(int direction,int[] classes,int[] codes){}
  record Facts(Rule rule,int[] reactions,List<Override> overrides,boolean light){}

  /**
   * Contexts for refining `skip`: every combination of the other offsets' representatives, or
   * one change at a time around an all-first-class context and around a surviving one.
   */
  static List<int[]> contexts(List<List<BlockState>> reps,int skip,int[] alive){
    int[] radix=new int[reps.size()];long product=1;
    for(int i=0;i<radix.length;i++){radix[i]=i==skip?1:reps.get(i).size();product*=radix[i];}
    var out=new LinkedHashMap<List<Integer>,int[]>();
    if(product<=FULL_CONTEXTS){int[] choice=new int[radix.length];do add(out,choice);while(next(choice,radix));}
    else{
      around(out,new int[radix.length],radix);
      if(alive!=null){int[] base=alive.clone();base[skip]=0;around(out,base,radix);}
    }
    return new ArrayList<>(out.values());
  }
  static void add(Map<List<Integer>,int[]> out,int[] choice){out.putIfAbsent(Arrays.stream(choice).boxed().toList(),choice.clone());}
  static void around(Map<List<Integer>,int[]> out,int[] base,int[] radix){
    add(out,base);
    for(int i=0;i<radix.length;i++)for(int c=0;c<radix[i];c++)if(c!=base[i]){int[] choice=base.clone();choice[i]=c;add(out,choice);}
  }
  static boolean next(int[] choice,int[] radix){
    for(int i=choice.length-1;i>=0;i--){if(++choice[i]<radix[i])return true;choice[i]=0;}
    return false;
  }
  static void place(Probe p,BlockState s,List<Integer> offsets,List<List<BlockState>> reps,int[] choice){
    p.clear();p.self=s;for(int i=0;i<choice.length;i++)p.put(offsets.get(i),reps.get(i).get(choice[i]));
  }
  /** A combination of representatives under which `s` survives (all of them, or a seeded sample). */
  static int[] surviving(Probe p,BlockState s,List<Integer> offsets,List<List<BlockState>> reps,Random random){
    int[] radix=new int[reps.size()];long product=1;
    for(int i=0;i<radix.length;i++){radix[i]=reps.get(i).size();product*=radix[i];}
    int[] choice=new int[radix.length];
    if(product<=4096){do{place(p,s,offsets,reps,choice);if(p.survive())return choice;}while(next(choice,radix));return null;}
    for(int k=0;k<4096;k++){
      for(int i=0;i<radix.length;i++)choice[i]=random.nextInt(radix[i]);
      place(p,s,offsets,reps,choice);if(p.survive())return choice;
    }
    return null;
  }

  // Final partitions by block and offset: a block's later states start from them, so
  // refinement usually only confirms them (one pass per offset).
  // Only first states write it, so later states see the same partitions in any thread order.
  static final Map<Long,int[]> WARM=new ConcurrentHashMap<>();static volatile boolean warming=true;
  // Partitions repeat across thousands of states; one shared copy each keeps the heap small.
  record Classes(int[] values){
    public boolean equals(Object o){return o instanceof Classes c&&Arrays.equals(values,c.values);}
    public int hashCode(){return Arrays.hashCode(values);}
  }
  static final Map<Classes,int[]> INTERNED=new ConcurrentHashMap<>();
  static int[] intern(int[] classes){return INTERNED.computeIfAbsent(new Classes(classes),Classes::values);}
  static long warmKey(BlockState s,int offset){return (long)BuiltInRegistries.BLOCK.getId(s.getBlock())<<32|offset;}
  static void start(BlockState s,int offset,List<List<BlockState>> reps,List<int[]> classes){
    var warm=WORLDGEN?null:WARM.get(warmKey(s,offset));
    if(warm==null){
      // Worldgen rules read the block's own cell too, so a rule may need two cells right at
      // once (tall seagrass: a sturdy floor and water in place): common states seed the search.
      // A live rule may need two neighbours at once too (a big dripleaf stem: stem or soil below
      // and stem or leaf above, VMC-039c): the block itself seeds it beside air.
      reps.add(WORLDGEN?List.of(AIR,Blocks.STONE.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState(),
          Blocks.GRASS_BLOCK.defaultBlockState(),Blocks.DIRT.defaultBlockState(),Blocks.SAND.defaultBlockState()):s.isAir()?List.of(AIR):List.of(AIR,s));
      classes.add(null);return;
    }
    var first=new ArrayList<BlockState>();
    for(int n=0;n<COUNT;n++)if(warm[n]==first.size())first.add(STATES[n]);
    reps.add(first);classes.add(warm);
  }

  /**
   * Survival rule of `s`: null when canSurvive reads no neighbour and holds, a rule without
   * offsets when it reads none and fails (a multiface block without faces).
   */
  static Rule rule(Probe p,BlockState s){
    boolean empty=p.survive(s,Map.of());
    var offsets=new ArrayList<Integer>();for(int k=0;k<p.readCount;k++)offsets.add(p.reads[k]);
    if(offsets.isEmpty()){
      if(empty)return null;
      return new Rule(new int[0],new int[0][],new int[0],new BitSet(),1);
    }
    var reps=new ArrayList<List<BlockState>>();var classes=new ArrayList<int[]>();
    for(int o:offsets)start(s,o,reps,classes);
    var dirty=new ArrayDeque<Integer>();for(int i=0;i<offsets.size();i++)dirty.add(i);
    var random=new Random(Block.getId(s));int rounds=0;
    while(!dirty.isEmpty()){
      if(++rounds>64)throw new Unsupported("unstable partition");
      int o=dirty.poll();int known=offsets.size();
      var contexts=contexts(reps,o,surviving(p,s,offsets,reps,random));
      var signatures=new long[COUNT][contexts.size()];
      for(int c=0;c<contexts.size();c++){
        place(p,s,offsets,reps,contexts.get(c));int key=offsets.get(o);
        for(int n=0;n<COUNT;n++){
          p.put(key,STATES[n]);boolean alive=p.survive();
          signatures[n][c]=(alive?1L:0L)<<32|(p.trace&0xffffffffL);
          for(int k=0;k<p.readCount;k++)if(!offsets.contains(p.reads[k]))offsets.add(p.reads[k]);
        }
      }
      if(offsets.size()>MAX_OFFSETS)throw new Unsupported("offsets");
      var seen=new HashMap<List<Long>,Integer>();int[] cls=new int[COUNT];var found=new ArrayList<BlockState>();
      for(int n=0;n<COUNT;n++){
        var sig=Arrays.stream(signatures[n]).boxed().toList();Integer c=seen.get(sig);
        if(c==null){c=seen.size();seen.put(sig,c);found.add(STATES[n]);}
        cls[n]=c;
      }
      boolean grown=offsets.size()>known;
      for(int i=known;i<offsets.size();i++)start(s,offsets.get(i),reps,classes);
      cls=intern(cls);
      boolean changed=classes.get(o)==null||!Arrays.equals(classes.get(o),cls);
      classes.set(o,cls);reps.set(o,found);
      if(found.size()>255)throw new Unsupported("classes");
      if(changed||grown)for(int i=0;i<offsets.size();i++)if(i!=o&&!dirty.contains(i))dirty.add(i);
      if(grown&&!dirty.contains(o))dirty.add(o);
    }
    int[] keys=offsets.stream().mapToInt(Integer::intValue).toArray();
    int[] radix=new int[keys.length];long size=1;for(int i=0;i<keys.length;i++){radix[i]=reps.get(i).size();size*=radix[i];}
    if(size>MAX_TABLE)throw new Unsupported("table");
    var table=new BitSet();int[] choice=new int[radix.length];int index=0;
    do{
      place(p,s,offsets,reps,choice);
      if(p.survive())table.set(index);
      for(int k=0;k<p.readCount;k++){int r=p.reads[k];if(Arrays.stream(keys).noneMatch(x->x==r))throw new Unsupported("unstable reads");}
      index++;
    }while(next(choice,radix));
    if(warming)for(int i=0;i<keys.length;i++)WARM.put(warmKey(s,keys[i]),classes.get(i));
    return new Rule(keys,classes.toArray(int[][]::new),radix,table,(int)size);
  }

  /** The context of table combination `index` (first member of each class). */
  static Map<Integer,BlockState> combination(Rule rule,int index){
    var map=new HashMap<Integer,BlockState>();
    for(int i=rule.offsets.length-1;i>=0;i--){
      int c=index%rule.radix[i];index/=rule.radix[i];
      int n=0;while(rule.classes[i][n]!=c)n++;
      map.put(rule.offsets[i],STATES[n]);
    }
    return map;
  }
  static List<Map<Integer,BlockState>> combinations(Rule rule,boolean value,int limit){
    var out=new ArrayList<Map<Integer,BlockState>>();
    for(int i=0;i<rule.size&&out.size()<limit;i++)if(rule.table.get(i)==value)out.add(combination(rule,i));
    return out;
  }
  /** The generated rule (not vanilla) on the probe's cells. */
  static boolean table(Probe p,Rule rule){
    if(rule==null)return true;
    int index=0;
    for(int i=0;i<rule.offsets.length;i++)index=index*rule.radix[i]+rule.classes[i][Block.getId(p.cell(rule.offsets[i]))];
    return rule.table.get(index);
  }
  /** The generated outcome of an update from `d` on the probe's cells, without or with overrides. */
  static int model(Probe p,Rule rule,int[] reactions,int d){
    return reactions[d]==0||table(p,rule)?0:reactions[d];
  }
  static int model(Probe p,Facts f,int d){
    for(var o:f.overrides)if(o.direction==d){
      int code=o.codes[o.classes[Block.getId(p.cell(index(DIRS[d])))]];
      if(code==1)return -1;if(code==2)return 0;
    }
    return model(p,f.rule,f.reactions,d);
  }
  /** Neighbours that may need an override: plain probes, the block's own states and its class's blocks. */
  static List<BlockState> probes(BlockState s){
    var out=new LinkedHashSet<BlockState>(List.of(AIR,Blocks.STONE.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState()));
    out.addAll(s.getBlock().getStateDefinition().getPossibleStates());
    for(var block:BuiltInRegistries.BLOCK)if(block.getClass()==s.getBlock().getClass()&&out.size()<4096)out.addAll(block.getStateDefinition().getPossibleStates());
    return new ArrayList<>(out);
  }

  static Facts analyze(Probe p,BlockState s){
    var rule=rule(p,s);boolean light=false;
    int[] reactions=new int[6];var worlds=new ArrayList<Map<Integer,BlockState>>();
    if(rule!=null){
      for(int i=0;i<rule.size&&!light;i++){p.survive(s,combination(rule,i));light=p.light;}
      var unsupported=combinations(rule,false,32);var good=combinations(rule,true,1);
      if(unsupported.isEmpty()){rule=null;worlds.add(Map.of());}
      else{
        for(int d=0;d<6;d++){
          int reaction=p.update(s,unsupported.get(0),DIRS[d]);
          for(var world:unsupported)if(p.update(s,world,DIRS[d])!=reaction)throw new Unsupported("context reaction");
          reactions[d]=reaction;
        }
        if(Arrays.stream(reactions).anyMatch(r->r>0))verifyTick(p,s,unsupported,good);
        worlds.addAll(good);worlds.add(unsupported.get(0));
      }
    }else worlds.add(Map.of());
    var overrides=new ArrayList<Override>();var probes=probes(s);
    for(int d=0;d<6;d++){
      int o=index(DIRS[d]);boolean need=false;
      for(var world:worlds){
        p.world(s,world);
        for(var probe:probes){p.put(o,probe);if(p.update(DIRS[d])!=model(p,rule,reactions,d)){need=true;break;}}
        if(need)break;
      }
      if(!need)continue;
      int[] code=new int[COUNT];
      for(int n=0;n<COUNT;n++){
        boolean agree=true,same=true;int first=Integer.MIN_VALUE;
        for(var world:worlds){
          p.world(s,world);p.put(o,STATES[n]);
          int vanilla=p.update(DIRS[d]);if(vanilla!=model(p,rule,reactions,d))agree=false;
          if(first==Integer.MIN_VALUE)first=vanilla;else if(vanilla!=first)same=false;
        }
        if(agree)code[n]=0;
        else if(same&&first<=0)code[n]=first==-1?1:2;
        else throw new Unsupported("override");
      }
      int[] cls=new int[COUNT];var ids=new LinkedHashMap<Integer,Integer>();
      for(int n=0;n<COUNT;n++)cls[n]=ids.computeIfAbsent(code[n],k->ids.size());
      overrides.add(new Override(d,intern(cls),ids.keySet().stream().mapToInt(Integer::intValue).toArray()));
    }
    if(rule==null&&overrides.isEmpty())return null;
    var facts=new Facts(rule,reactions,overrides,light);
    validate(p,s,facts);
    return facts;
  }
  /** The model must reproduce vanilla on random neighbourhoods, else the state is excluded. */
  static void validate(Probe p,BlockState s,Facts f){
    var random=new Random(~(long)Block.getId(s));
    for(int k=0;k<48;k++){
      p.world(s,neighbourhood(f,random));
      if(f.rule!=null&&p.survive()!=table(p,f.rule))throw new Unsupported("model survival");
      int d=random.nextInt(6);
      if(p.update(DIRS[d])!=model(p,f,d))throw new Unsupported("model update");
    }
  }
  /** Members of random classes at the read offsets and overrides, random states at some faces. */
  static Map<Integer,BlockState> neighbourhood(Facts f,Random random){
    var world=new HashMap<Integer,BlockState>();
    if(f.rule!=null)for(int i=0;i<f.rule.offsets.length;i++)world.put(f.rule.offsets[i],member(f.rule.classes[i],random));
    for(var o:f.overrides)world.put(index(DIRS[o.direction]),member(o.classes,random));
    for(var d:DIRS)if(random.nextInt(3)==0)world.put(index(d),STATES[random.nextInt(COUNT)]);
    return world;
  }
  static final Map<Classes,int[][]> MEMBERS=new ConcurrentHashMap<>();
  static BlockState member(int[] classes,Random random){
    var byClass=MEMBERS.computeIfAbsent(new Classes(classes),k->{
      int count=Arrays.stream(classes).max().getAsInt()+1;int[] sizes=new int[count];
      for(int c:classes)sizes[c]++;
      int[][] out=new int[count][];for(int c=0;c<count;c++)out[c]=new int[sizes[c]];
      Arrays.fill(sizes,0);for(int n=0;n<COUNT;n++)out[classes[n]][sizes[classes[n]]++]=n;
      return out;
    });
    var list=byClass[random.nextInt(byClass.length)];
    return STATES[list[random.nextInt(list.length)]];
  }

  /** Cheap filter: canSurvive reads a neighbour, or an update breaks the state in an empty world. */
  static boolean candidate(Probe p,BlockState s){
    if(s.isAir())return false;
    p.survive(s,Map.of());if(p.readCount>0)return true;
    for(var d:DIRS)for(var probe:List.of(AIR,Blocks.STONE.defaultBlockState(),Blocks.WATER.defaultBlockState(),s))
      if(p.update(s,Map.of(index(d),probe),d)==-1)return true;
    return false;
  }

  // Partitions are deduplicated; each is written as runs [first state, class, ...].
  static final class Partitions {
    final List<int[]> list=new ArrayList<>();final Map<Integer,List<Integer>> byHash=new HashMap<>();
    int index(int[] classes){
      int h=Arrays.hashCode(classes);
      for(int i:byHash.getOrDefault(h,List.of()))if(Arrays.equals(list.get(i),classes))return i;
      list.add(classes);byHash.computeIfAbsent(h,k->new ArrayList<>()).add(list.size()-1);return list.size()-1;
    }
    JsonArray json(){
      var all=new JsonArray();
      for(int[] classes:list){var runs=new JsonArray();for(int n=0;n<COUNT;n++)if(n==0||classes[n]!=classes[n-1]){runs.add(n);runs.add(classes[n]);}all.add(runs);}
      return all;
    }
  }
  static String bits(BitSet table,int size){var b=new StringBuilder(size);for(int i=0;i<size;i++)b.append(table.get(i)?'1':'0');return b.toString();}
  static JsonArray json(int[] values){var a=new JsonArray();for(int v:values)a.add(v);return a;}

  /** Fluid tags from the vanilla data pack (survival checks ask whether a neighbour is water). */
  static void bindFluidTags()throws Exception{
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.FLUID.key(),(id,required)->BuiltInRegistries.FLUID.get(id));
      var memberships=new HashMap<Holder<Fluid>,List<TagKey<Fluid>>>();
      tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
      for(var fluid:BuiltInRegistries.FLUID)bind.invoke(fluid.builtInRegistryHolder(),memberships.getOrDefault(fluid.builtInRegistryHolder(),List.of()));
    }
    if(!Fluids.WATER.defaultFluidState().is(FluidTags.WATER)||!Fluids.LAVA.defaultFluidState().is(FluidTags.LAVA))throw new AssertionError("Fluid tags unbound");
  }

  public static void main(String[] args)throws Exception{
    MiningToolOracle.initialize();bindFluidTags();
    COUNT=Block.BLOCK_STATE_REGISTRY.size();STATES=new BlockState[COUNT];AIR=Blocks.AIR.defaultBlockState();
    for(int n=0;n<COUNT;n++){STATES[n]=Block.stateById(n);if(Block.getId(STATES[n])!=n)throw new AssertionError("Sparse state id "+n);}
    var probes=ThreadLocal.withInitial(Probe::new);
    if(args[0].equals("worldgen")){WORLDGEN=true;worldgen(Path.of(args[1]),probes);return;}
    var facts=new Facts[COUNT];var excluded=new String[COUNT];var done=new AtomicInteger();
    // Each block's first state runs first and warms the partitions for its other states;
    // many-property blocks (multiface, vines) cost the most and start first in each phase.
    var pool=Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors());
    Comparator<Integer> heavy=Comparator.comparingInt((Integer n)->-STATES[n].getProperties().size()).thenComparingInt(n->n);
    var firsts=IntStream.range(0,COUNT).boxed().filter(n->n==0||STATES[n-1].getBlock()!=STATES[n].getBlock()).sorted(heavy).toList();
    var rest=IntStream.range(0,COUNT).boxed().filter(n->n>0&&STATES[n-1].getBlock()==STATES[n].getBlock()).sorted(heavy).toList();
    for(var phase:List.of(firsts,rest)){
      var tasks=new ArrayList<Future<?>>();
      for(int n:phase)tasks.add(pool.submit(()->{
        var p=probes.get();var s=STATES[n];
        try{if(candidate(p,s))facts[n]=analyze(p,s);}
        catch(Unsupported e){excluded[n]=e.getMessage();}
        catch(RuntimeException e){excluded[n]=e.getClass().getSimpleName();}
        int k=done.incrementAndGet();if(k%5000==0)System.err.println("states "+k+"/"+COUNT);
      }));
      for(var task:tasks)task.get();
      warming=false;
    }
    pool.shutdown();
    // A block with any state that fails validation keeps none: its model is incomplete.
    var failed=new HashSet<Block>();
    for(int n=0;n<COUNT;n++)if(excluded[n]!=null&&excluded[n].startsWith("model "))failed.add(STATES[n].getBlock());
    for(int n=0;n<COUNT;n++)if(facts[n]!=null&&failed.contains(STATES[n].getBlock())){facts[n]=null;excluded[n]="model block";}
    var partitions=new Partitions();var rules=new JsonArray();var ruleIndex=new HashMap<String,Integer>();
    var profiles=new JsonArray();var profileIndex=new HashMap<String,Integer>();var runs=new JsonArray();
    var gson=new Gson();int dependent=0;var lightRules=new TreeSet<Integer>();
    int[] profileOf=new int[COUNT];Arrays.fill(profileOf,-1);
    for(int n=0;n<COUNT;n++){
      var f=facts[n];if(f==null)continue;dependent++;
      JsonElement ruleId=JsonNull.INSTANCE;
      if(f.rule!=null){
        var r=new JsonObject();var offs=new JsonArray();var parts=new JsonArray();
        for(int i=0;i<f.rule.offsets.length;i++){offs.add(json(offset(f.rule.offsets[i])));parts.add(partitions.index(f.rule.classes[i]));}
        r.add("offsets",offs);r.add("partitions",parts);r.addProperty("table",bits(f.rule.table,f.rule.size));
        var key=gson.toJson(r);Integer id=ruleIndex.get(key);
        if(id==null){id=rules.size();ruleIndex.put(key,id);rules.add(r);}
        if(f.light)lightRules.add(id);
        ruleId=new JsonPrimitive(id);
      }
      var profile=new JsonObject();profile.add("rule",ruleId);profile.add("reactions",json(f.reactions));
      var overrides=new JsonArray();
      for(var o:f.overrides){var a=new JsonArray();a.add(o.direction);a.add(partitions.index(o.classes));a.add(json(o.codes));overrides.add(a);}
      profile.add("overrides",overrides);
      var key=gson.toJson(profile);Integer id=profileIndex.get(key);
      if(id==null){id=profiles.size();profileIndex.put(key,id);profiles.add(profile);}
      profileOf[n]=id;
    }
    for(int n=0;n<COUNT;n++){
      if(profileOf[n]<0)continue;
      if(runs.size()>0){var last=runs.get(runs.size()-1).getAsJsonArray();
        if(last.get(1).getAsInt()==n-1&&last.get(2).getAsInt()==profileOf[n]){last.set(1,new JsonPrimitive(n));continue;}}
      var run=new JsonArray();run.add(n);run.add(n);run.add(profileOf[n]);runs.add(run);
    }
    var excludedClasses=new TreeMap<String,Integer>();
    for(int n=0;n<COUNT;n++)if(excluded[n]!=null)excludedClasses.merge(STATES[n].getBlock().getClass().getSimpleName()+": "+excluded[n],1,Integer::sum);
    var excludedJson=new JsonArray();
    for(var e:excludedClasses.entrySet()){var a=new JsonArray();a.add(e.getKey());a.add(e.getValue());excludedJson.add(a);}
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("state_count",COUNT);out.addProperty("dependent_states",dependent);
    out.add("partitions",partitions.json());out.add("rules",rules);out.add("light_rules",gson.toJsonTree(lightRules));
    out.add("profiles",profiles);out.add("states",runs);out.add("excluded",excludedJson);
    Files.writeString(Path.of(args[0]),gson.toJson(out)+"\n");
    var cases=cases(facts,probes.get());
    Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+dependent+" dependent states, "+rules.size()+" survival rules, "+profiles.size()+" profiles, "
      +partitions.list.size()+" partitions, "+cases.get("updates").getAsJsonArray().size()+" differential updates; excluded "+excludedJson);
  }

  /** The worldgen survival facts: every non-air state whose survival reads a cell gets a rule. */
  static void worldgen(Path out,ThreadLocal<Probe> probes)throws Exception{
    var rules=new Rule[COUNT];var excluded=new String[COUNT];
    var pool=Executors.newFixedThreadPool(Runtime.getRuntime().availableProcessors());
    Comparator<Integer> heavy=Comparator.comparingInt((Integer n)->-STATES[n].getProperties().size()).thenComparingInt(n->n);
    var firsts=IntStream.range(0,COUNT).boxed().filter(n->n==0||STATES[n-1].getBlock()!=STATES[n].getBlock()).sorted(heavy).toList();
    var rest=IntStream.range(0,COUNT).boxed().filter(n->n>0&&STATES[n-1].getBlock()==STATES[n].getBlock()).sorted(heavy).toList();
    for(var phase:List.of(firsts,rest)){
      var tasks=new ArrayList<Future<?>>();
      for(int n:phase)tasks.add(pool.submit(()->{
        var p=probes.get();var s=STATES[n];
        try{if(!s.isAir())rules[n]=rule(p,s);}
        catch(Unsupported e){excluded[n]=e.getMessage();}
        catch(RuntimeException e){excluded[n]=e.getClass().getSimpleName();}
      }));
      for(var task:tasks)task.get();
      warming=false;
    }
    // Validation: on random neighbourhoods (seed states and any state at each read cell), the
    // table must give vanilla's answer, and survival must read no other cell; else excluded.
    var seeds=List.of(AIR,Blocks.STONE.defaultBlockState(),Blocks.WATER.defaultBlockState(),Blocks.LAVA.defaultBlockState(),
        Blocks.GRASS_BLOCK.defaultBlockState(),Blocks.DIRT.defaultBlockState(),Blocks.SAND.defaultBlockState());
    var checks=new ArrayList<Future<?>>();var checked=new java.util.concurrent.atomic.AtomicLong();
    for(int n0=0;n0<COUNT;n0++){
      final int n=n0;var rule=rules[n];if(rule==null||rule.offsets.length==0)continue;
      checks.add(pool.submit(()->{
        var p=probes.get();var s=STATES[n];var random=new Random(n);
        for(int k=0;k<128;k++){
          var context=new HashMap<Integer,BlockState>();int index=0;
          for(int i=0;i<rule.offsets.length;i++){
            var state=random.nextBoolean()?seeds.get(random.nextInt(seeds.size())):STATES[random.nextInt(COUNT)];
            context.put(rule.offsets[i],state);index=index*rule.radix[i]+rule.classes[i][Block.getId(state)];
          }
          boolean alive=p.survive(s,context);
          for(int r=0;r<p.readCount;r++){int cell=p.reads[r];boolean known=false;for(int o:rule.offsets)known|=o==cell;
            if(!known){synchronized(excluded){excluded[n]="validation read";rules[n]=null;}return;}}
          if(alive!=rule.table.get(index)){synchronized(excluded){excluded[n]="validation table";rules[n]=null;}return;}
          checked.incrementAndGet();
        }
      }));
    }
    for(var task:checks)task.get();
    pool.shutdown();
    System.out.println("validated "+checked.get()+" worldgen survival neighbourhoods");
    var partitions=new Partitions();var json=new JsonArray();var index=new HashMap<String,Integer>();var runs=new JsonArray();
    var gson=new Gson();int dependent=0;int[] ruleOf=new int[COUNT];Arrays.fill(ruleOf,-1);
    for(int n=0;n<COUNT;n++){
      var rule=rules[n];if(rule==null)continue;dependent++;
      var r=new JsonObject();var offs=new JsonArray();var parts=new JsonArray();
      for(int i=0;i<rule.offsets.length;i++){offs.add(json(offset(rule.offsets[i])));parts.add(partitions.index(rule.classes[i]));}
      r.add("offsets",offs);r.add("partitions",parts);r.addProperty("table",bits(rule.table,rule.size));
      var key=gson.toJson(r);Integer id=index.get(key);
      if(id==null){id=json.size();index.put(key,id);json.add(r);}
      ruleOf[n]=id;
    }
    for(int n=0;n<COUNT;n++){
      if(ruleOf[n]<0)continue;
      if(runs.size()>0){var last=runs.get(runs.size()-1).getAsJsonArray();
        if(last.get(1).getAsInt()==n-1&&last.get(2).getAsInt()==ruleOf[n]){last.set(1,new JsonPrimitive(n));continue;}}
      var run=new JsonArray();run.add(n);run.add(n);run.add(ruleOf[n]);runs.add(run);
    }
    var excludedBlocks=new TreeMap<String,Integer>();
    for(int n=0;n<COUNT;n++)if(excluded[n]!=null)excludedBlocks.merge(BuiltInRegistries.BLOCK.getKey(STATES[n].getBlock())+": "+excluded[n],1,Integer::sum);
    var excludedJson=new JsonArray();
    for(var e:excludedBlocks.entrySet()){var a=new JsonArray();a.add(e.getKey());a.add(e.getValue());excludedJson.add(a);}
    var o=new JsonObject();o.addProperty("version","26.3");o.addProperty("data_version",5023);o.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    o.addProperty("state_count",COUNT);o.addProperty("dependent_states",dependent);
    o.add("partitions",partitions.json());o.add("rules",json);o.add("states",runs);o.add("excluded",excludedJson);
    Files.writeString(out,gson.toJson(o)+"\n");
    System.out.println("PASS: worldgen survival of "+dependent+" states, "+json.size()+" rules, "+partitions.list.size()+" partitions; excluded "+excludedJson);
  }

  /**
   * Differential cases, independent of the oracle's own validation: random neighbourhoods around
   * every dependent state with vanilla's survival and the update outcome from a random direction,
   * plus each state's broken remains (its fluid block).
   */
  static JsonObject cases(Facts[] facts,Probe p){
    var random=new Random(20261020L);var updates=new JsonArray();var remains=new JsonArray();
    for(int n=0;n<COUNT;n++){
      var f=facts[n];if(f==null)continue;var s=STATES[n];
      var remain=new JsonArray();remain.add(n);remain.add(Block.getId(s.getFluidState().createLegacyBlock()));remains.add(remain);
      for(int k=0;k<6;k++){
        var world=neighbourhood(f,random);int d=random.nextInt(6);
        p.world(s,world);boolean alive=p.survive();int outcome=p.update(DIRS[d]);
        var row=new JsonArray();row.add(n);row.add(d);row.add(alive);row.add(outcome);
        var cells=new JsonArray();
        for(var e:world.entrySet()){var c=json(offset(e.getKey()));c.add(Block.getId(e.getValue()));cells.add(c);}
        row.add(cells);updates.add(row);
      }
    }
    var out=new JsonObject();out.add("updates",updates);out.add("remains",remains);return out;
  }
}
