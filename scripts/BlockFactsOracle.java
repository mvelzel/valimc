import com.google.gson.*;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.Direction.Axis;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.damagesource.DamageSources;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.item.context.BlockPlaceContext;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.piston.MovingPistonBlock;
import net.minecraft.world.level.block.piston.PistonBaseBlock;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.lighting.ChunkSkyLightSources;
import net.minecraft.world.level.lighting.LightEngine;
import net.minecraft.world.level.material.FlowingFluid;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.level.material.Fluids;
import net.minecraft.world.level.storage.ValueInput;
import net.minecraft.world.level.storage.ValueOutput;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.shapes.*;

/**
 * The per-state block fact table (VMC-077d): every fact ValiMC and its Rust core read about a
 * block state, from vanilla's own methods with the jar's block tags bound, in one file of
 * columns. A column holds one value per state in id order, as hex of one byte per state, or of
 * two big-endian bytes when a value needs them. A column with a `palette` holds indexes into it;
 * a column with `classes` holds equivalence classes and a bit table over class pairs.
 *
 * - flags (palette of bit sets, named by `flag_bits`): whole-state predicates. Bits 0..31 are
 *   decoration's (VMC-025): `isAir`, `canBeReplaced()`, legacy `isSolid`, `hasBlockEntity`, a
 *   post-processing position at the block, sturdy full faces (`isFaceSturdy`) down, up, north,
 *   south, west, east, a liquid block, legacy `liquid()`, a double plant, a mossy carpet, a
 *   post-processing position above the block (bubble columns), `isSolidRender`, full collision
 *   faces (`Block.isFaceFull`), `isCollisionShapeFullBlock`, full face occlusion shapes (neither
 *   empty nor partial), a `LiquidBlockContainer`, a `SimpleWaterloggedBlock`. Bits 32..48: a full
 *   outline shape, a sturdy centre on the bottom face (`SupportType.CENTER`), a `FallingBlock`,
 *   `isRedstoneConductor`, `isSignalSource`, whether the bottom face of the collision shape
 *   covers a wall's post and north, east, south and west sides (`WallBlock.isCovered`),
 *   `isExceptionForConnection`, and the classes of bars and panes, stairs, fence gates, walls,
 *   fences and doors. Bit 49: fire can burn it (`FireBlock.canBurn`). Bit 50: a collision shape
 *   larger than its cell (`hasLargeCollisionShape`). Every predicate runs against a level that
 *   fails on any read, so none depends on the neighbourhood; the states whose answers read the
 *   level (moving pistons, shulker boxes) are listed in `level_dependent` and have no sturdy
 *   face or full collision face.
 * - shape: the cached collision shape (`geometry`), or the block whose shape needs context
 *   (`context`); position-offset blocks (bamboo, dripstone) also carry their unshifted shape and
 *   maximum horizontal offset. `contextual_shapes` holds the fixed shapes those contexts pick.
 * - motion: friction, speed, jump and bounce factors, bounce suppression (tag), whether a
 *   support at the block keeps the legacy support height (walls, fence gates; fences are a
 *   flag), and water and bubble columns' own speed rule.
 * - fluid: the contained fluid's kind, amount, own height, source and falling, and the state
 *   base block removal leaves (`FluidState.createLegacyBlock`, confirmed through `removeBlock`).
 * - boundary: whether the block stops fluid flow (tag), is ice, and which block entity decides
 *   its sturdy faces (moving piston, shulker box) when the flags cannot.
 * - climb: climbable and glide-through tags, scaffolding, ladder and trapdoor facing and open.
 * - inside: what standing inside does (fire, soul fire, powder snow, cobweb, berry bush) and
 *   the inside collision shape when it is not the full block (`context` for powder snow).
 * - hazard: the immediate damage request kind and value (magma, lit campfires' damage, cactus,
 *   berry bush age). landing: the affine `fallOn` damage call without and with sneaking.
 * - mining: hardness and whether drops need the correct tool. explosion: the resistance an
 *   explosion's ray meets (`ExplosionDamageCalculator.getBlockExplosionResistance`: the larger of
 *   the block's and its fluid's, null for air without fluid). replaceability: how placement
 *   treats a click on the state (0 another rule, 1 never replaced, 2 replaced, 3 a slab).
 * - heightmap: the six heightmap predicates (`heightmap_types`) as a bit mask.
 * - sky: vertical sky-source edge classes; bit (above, below) says `isEdgeOccluded`.
 * - light: emission << 4 | dampening. light_down..light_east: per face the class of its light
 *   occlusion shape; bit (a, b) of a face's table says light leaving a block of class a through
 *   the face is stopped by a neighbour whose opposite face has class b (`faceShapeOccludes`).
 * - signal: `getSignal` and `getDirectSignal` toward down, up, north, south, west and east, or
 *   the block whose signal reads the level (`context`: powered wire, comparators, trapped chests,
 *   test blocks).
 *
 * `block_entity_types` maps each block with a block entity to the type it creates. Every class
 * table is checked state by state against its representatives.
 * Usage: BlockFactsOracle FACTS.json
 */
public class BlockFactsOracle {
  static final BlockPos ORIGIN=new BlockPos(0,64,0);
  static final List<String> FLAG_BITS=List.of("air","replaceable","solid","block_entity","post_process",
      "sturdy_down","sturdy_up","sturdy_north","sturdy_south","sturdy_west","sturdy_east","liquid_block","liquid",
      "double_plant","mossy_carpet","post_process_above","solid_render","collision_down","collision_up",
      "collision_north","collision_south","collision_west","collision_east","full_collision","occludes_down",
      "occludes_up","occludes_north","occludes_south","occludes_west","occludes_east","liquid_container",
      "simple_waterlogged","full_shape","center_support_down","falling","redstone_conductor","signal_source",
      "covers_wall_post","covers_wall_north","covers_wall_east","covers_wall_south","covers_wall_west",
      "connection_exception","iron_bars","stairs","fence_gate","wall","fence","door","flammable","large_collision");
  static final Gson GSON=new Gson();

  /** One value per state: an index into a palette of distinct JSON values, or a small integer. */
  static final class Column {
    final JsonArray palette;final Map<String,Integer> indexes=new HashMap<>();final int[] values;int max;
    Column(int count,boolean palette){values=new int[count];this.palette=palette?new JsonArray():null;}
    void set(int id,JsonElement value){
      var key=GSON.toJson(value);Integer index=indexes.get(key);
      if(index==null){index=palette.size();indexes.put(key,index);palette.add(value);}
      set(id,index);
    }
    void set(int id,int value){if(value<0||value>0xffff)throw new AssertionError("column value "+value);values[id]=value;max=Math.max(max,value);}
    JsonObject json(){
      var hex=new StringBuilder();
      for(int value:values)hex.append(String.format(Locale.ROOT,max>255?"%04x":"%02x",value));
      var out=new JsonObject();if(palette!=null)out.add("palette",palette);out.addProperty("states",hex.toString());return out;
    }
  }

  // -- Shared with the case oracles ------------------------------------------------------------

  private static final Field GRID;
  static {
    try{GRID=VoxelShape.class.getDeclaredField("shape");GRID.setAccessible(true);}
    catch(Exception e){throw new RuntimeException(e);}
  }

  /** A voxel shape as the table writes it: grid axes, sizes, filled cells, boxes, full block. */
  public static JsonObject geometry(VoxelShape shape)throws Exception{
    var result=new JsonObject();var coords=new JsonArray();var sizes=new JsonArray();var boxes=new JsonArray();
    var grid=(DiscreteVoxelShape)GRID.get(shape);
    int nx=grid.getXSize(),ny=grid.getYSize(),nz=grid.getZSize();
    if(shape.isEmpty()){nx=ny=nz=0;for(int i=0;i<3;i++){var axis=new JsonArray();axis.add(0.0);coords.add(axis);}}
    else for(var axis:Axis.values()){var values=new JsonArray();for(double v:shape.getCoords(axis))values.add(v);coords.add(values);}
    sizes.add(nx);sizes.add(ny);sizes.add(nz);byte[] bits=new byte[(nx*ny*nz+7)/8];
    for(int x=0;x<nx;x++)for(int y=0;y<ny;y++)for(int z=0;z<nz;z++)if(grid.isFull(x,y,z)){
      int index=(x*ny+y)*nz+z;bits[index/8]|=(byte)(1<<(index%8));
    }
    for(var box:shape.toAabbs()){
      var values=new JsonArray();for(double v:new double[]{box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ})values.add(v);
      boxes.add(values);
    }
    result.add("axes",coords);result.add("sizes",sizes);result.addProperty("bits",HexFormat.of().formatHex(bits));
    result.add("boxes",boxes);result.addProperty("full_block",shape==Shapes.block());return result;
  }

  public static VoxelShape scaffoldingField(String name)throws Exception{
    var field=ScaffoldingBlock.class.getDeclaredField(name);field.setAccessible(true);return (VoxelShape)field.get(null);
  }

  /**
   * Binds exactly `keep` of the jar's block tags and unbinds every other, for case oracles whose
   * observations must not see the rest; the table itself binds them all.
   */
  @SafeVarargs
  public static void bindOnly(TagKey<Block>... keep)throws Exception{
    var wanted=Set.of(keep);var memberships=new HashMap<Holder<Block>,List<TagKey<Block>>>();
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.BLOCK.key(),(id,required)->BuiltInRegistries.BLOCK.get(id));
      tags.forEach((tag,holders)->{if(wanted.contains(tag))holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag));});
    }
    if(!memberships.values().stream().flatMap(List::stream).distinct().toList().containsAll(wanted))throw new AssertionError("Missing pinned tag "+wanted);
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var block:BuiltInRegistries.BLOCK)bind.invoke(block.builtInRegistryHolder(),memberships.getOrDefault(block.builtInRegistryHolder(),List.of()));
  }

  public static JsonObject climb(BlockState state){
    var block=state.getBlock();var f=new JsonObject();
    f.addProperty("climbable",state.is(BlockTags.CLIMBABLE));f.addProperty("glide_through",state.is(BlockTags.CAN_GLIDE_THROUGH));
    f.addProperty("scaffolding",block==Blocks.SCAFFOLDING);
    f.addProperty("ladder_facing",block==Blocks.LADDER?state.getValue(LadderBlock.FACING).ordinal():-1);
    f.addProperty("trapdoor_facing",block instanceof TrapDoorBlock?state.getValue(TrapDoorBlock.FACING).ordinal():-1);
    f.addProperty("trapdoor_open",block instanceof TrapDoorBlock&&state.getValue(TrapDoorBlock.OPEN));return f;
  }

  /** How placement treats a click on `state` (see the class comment), from a stone item clicking up. */
  public static int replaceability(BlockState state)throws Exception{
    var method=owner(state.getBlock().getClass(),"canBeReplaced",BlockState.class,BlockPlaceContext.class);
    if(method==SlabBlock.class)return 3;
    if(method!=BlockBehaviour.class&&method!=SnowLayerBlock.class)return 0;
    var level=probe(Probe.class);level.block=state;
    var context=new BlockPlaceContext(level,null,InteractionHand.MAIN_HAND,new ItemStack(Items.STONE),
        new BlockHitResult(new Vec3(.5,.5,.5),Direction.UP,BlockPos.ZERO,false)){};
    int flag=context.replacingClickedOnBlock()?2:1;
    if(method==BlockBehaviour.class&&(flag==2)!=state.canBeReplaced())throw new AssertionError("Plain same-item replacement needs admission");
    return flag;
  }

  static Class<?> owner(Class<?> type,String name,Class<?>... params)throws Exception{
    for(var c=type;c!=null;c=c.getSuperclass())try{return c.getDeclaredMethod(name,params).getDeclaringClass();}catch(NoSuchMethodException ignored){}
    throw new NoSuchMethodException(name);
  }

  static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}

  @SuppressWarnings("unchecked")
  static <T> T probe(Class<T> type)throws Exception{
    return (T)((sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null)).allocateInstance(type);
  }

  /** A level that holds one block at every position and records base block removal. */
  static class Probe extends ServerLevel {
    BlockState block,replacement;FluidState fluid;int flags,calls;DamageSources sources;RandomSource random;
    private Probe(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos position){return block;}
    public FluidState getFluidState(BlockPos position){return fluid;}
    public boolean setBlock(BlockPos position,BlockState state,int flags){replacement=state;this.flags=flags;calls++;return true;}
    public DamageSources damageSources(){return sources;}
    public RandomSource getRandom(){return random;}
    public void broadcastEntityEvent(Entity entity,byte event){}
  }

  /** Observes `fallOn` damage calls of a block under a non-living probe entity. */
  public static final class Landing extends Entity {
    Probe world;boolean shift;JsonObject call;DamageSource fall,stalagmite;
    private Landing(){super(null,null);}
    public static Landing create()throws Exception{
      var landing=probe(Landing.class);landing.world=probe(Probe.class);landing.world.random=RandomSource.create(1);
      landing.world.sources=probe(DamageSources.class);landing.fall=probe(DamageSource.class);landing.stalagmite=probe(DamageSource.class);
      field(DamageSources.class,"fall").set(landing.world.sources,landing.fall);field(DamageSources.class,"stalagmite").set(landing.world.sources,landing.stalagmite);
      field(Entity.class,"position").set(landing,new Vec3(.5,65.5,.5));landing.mainSupportingBlockPos=Optional.of(new BlockPos(0,63,0));
      return landing;
    }
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    public Level level(){return world;}
    public boolean isSuppressingBounce(){return shift;}
    public void playSound(SoundEvent sound,float volume,float pitch){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){throw new AssertionError("Unexpected direct damage");}
    public boolean causeFallDamage(double distance,float multiplier,DamageSource source){
      if(call!=null)throw new AssertionError("Multiple fall damage calls");
      call=new JsonObject();call.addProperty("distance",distance);call.addProperty("multiplier",(double)multiplier);
      if(source!=fall&&source!=stalagmite)throw new AssertionError("Unexpected source");
      call.addProperty("source",source==fall?"fall":"stalagmite");return false;
    }
    /** The damage call landing on `state` from `distance` makes, or null. */
    public JsonObject observe(BlockState state,double distance,boolean shift){
      this.shift=shift;call=null;world.block=state;state.getBlock().fallOn(world,state,BlockPos.ZERO,this,distance);return call;
    }
    /** Whether the legacy supporting position stays at the block's height (`getOnPosLegacy`). */
    public boolean holdsY(BlockState state){world.block=state;return getOnPosLegacy().getY()==63;}
    /** The call as an affine rule of the distance, checked at three distances. */
    JsonElement rule(BlockState state,boolean shift){
      var zero=observe(state,0,shift);var eight=observe(state,8,shift);var far=observe(state,64,shift);
      if(zero==null||eight==null||far==null){
        if(zero!=null||eight!=null||far!=null)throw new AssertionError("Distance-dependent callback "+state);
        return JsonNull.INSTANCE;
      }
      double offset=zero.get("distance").getAsDouble(),scale=(eight.get("distance").getAsDouble()-offset)/8;
      if(far.get("distance").getAsDouble()!=64*scale+offset||!zero.get("source").equals(eight.get("source"))||!eight.get("source").equals(far.get("source"))
          ||!zero.get("multiplier").equals(eight.get("multiplier"))||!eight.get("multiplier").equals(far.get("multiplier")))
        throw new AssertionError("Non-affine landing rule "+state);
      var result=new JsonObject();result.addProperty("distance_scale",scale);result.addProperty("distance_offset",offset);
      result.add("multiplier",eight.get("multiplier"));result.add("source",eight.get("source"));return result;
    }
  }

  /** A canonical key of a shape's boxes, for equivalence classes. */
  static String boxes(VoxelShape shape){
    var boxes=new ArrayList<String>();for(var box:shape.toAabbs())boxes.add(box.toString());
    Collections.sort(boxes);return boxes.toString();
  }

  // -- Columns ---------------------------------------------------------------------------------

  static BlockState[] STATES;static int COUNT;

  public static void main(String[] args)throws Exception{
    MiningToolOracle.initialize();
    COUNT=Block.BLOCK_STATE_REGISTRY.size();STATES=new BlockState[COUNT];
    for(int id=0;id<COUNT;id++){STATES[id]=Block.BLOCK_STATE_REGISTRY.byId(id);if(Block.getId(STATES[id])!=id)throw new AssertionError("Non-contiguous states");}
    var columns=new JsonObject();var levelDependent=new TreeSet<String>();
    var flags=flags(levelDependent);
    columns.add("flags",flags.json());
    var contextual=new JsonObject();columns.add("shape",shape(contextual).json());
    columns.add("motion",motion().json());
    columns.add("fluid",fluid().json());
    columns.add("boundary",boundary(flags).json());
    var climb=new Column(COUNT,true);for(int id=0;id<COUNT;id++)climb.set(id,climb(STATES[id]));columns.add("climb",climb.json());
    columns.add("inside",inside().json());
    columns.add("hazard",hazard().json());
    columns.add("landing",landing(flags).json());
    columns.add("mining",mining().json());
    columns.add("explosion",explosion().json());
    var replace=new Column(COUNT,false);for(int id=0;id<COUNT;id++)replace.set(id,replaceability(STATES[id]));columns.add("replaceability",replace.json());
    var heightmapTypes=new JsonArray();columns.add("heightmap",heightmap(heightmapTypes).json());
    columns.add("sky",sky());
    var light=new Column(COUNT,false);
    for(int id=0;id<COUNT;id++){
      int emission=STATES[id].getLightEmission(),dampening=STATES[id].getLightDampening();
      if(emission<0||emission>15||dampening<0||dampening>15)throw new AssertionError("light value range");
      light.set(id,emission<<4|dampening);
    }
    columns.add("light",light.json());
    lightFaces(columns);
    columns.add("signal",signal().json());

    var out=new JsonObject();var version=SharedConstants.getCurrentVersion();
    out.addProperty("version",version.id());out.addProperty("data_version",version.dataVersion().version());
    out.addProperty("server_sha1",VersionMetadata.serverSha1());out.addProperty("state_count",COUNT);
    var bits=new JsonArray();FLAG_BITS.forEach(bits::add);out.add("flag_bits",bits);
    out.add("heightmap_types",heightmapTypes);out.add("columns",columns);out.add("contextual_shapes",contextual);
    var excluded=new JsonArray();levelDependent.forEach(excluded::add);out.add("level_dependent",excluded);
    out.add("block_entity_types",blockEntityTypes());
    Files.writeString(Path.of(args[0]),GSON.toJson(out)+"\n");
    var sizes=new StringBuilder();
    for(var e:columns.entrySet()){var c=e.getValue().getAsJsonObject();sizes.append(' ').append(e.getKey()).append('=').append(c.has("palette")?c.getAsJsonArray("palette").size():c.has("classes")?c.get("classes").getAsInt():0);}
    System.out.println("PASS: block facts of "+COUNT+" states; palettes/classes"+sizes+"; level-dependent "+levelDependent);
  }

  /** A `WallBlock` test shape. */
  static Object wallField(String name)throws Exception{return field(WallBlock.class,name).get(null);}
  static boolean covers(VoxelShape face,VoxelShape test){return !Shapes.joinIsNotEmpty(test,face,BooleanOp.ONLY_FIRST);}

  /** A level that fails on any read, so a fact read through it depends on the state alone. */
  static final BlockGetter PROBE=(BlockGetter)Proxy.newProxyInstance(BlockFactsOracle.class.getClassLoader(),new Class<?>[]{BlockGetter.class},(proxy,method,a)->switch(method.getName()){
    case "getMinY"->-64;
    case "getHeight"->a==null?384:null;
    case "hashCode"->System.identityHashCode(proxy);
    case "equals"->proxy==a[0];
    case "toString"->"BlockFactsProbe";
    default->throw new IllegalStateException("level read: "+method.getName());
  });

  @SuppressWarnings("unchecked")
  static Column flags(Set<String> levelDependent)throws Exception{
    var level=PROBE;
    var canBurn=FireBlock.class.getDeclaredMethod("canBurn",BlockState.class);canBurn.setAccessible(true);
    var post=(VoxelShape)wallField("TEST_SHAPE_POST");var sides=(Map<Direction,VoxelShape>)wallField("TEST_SHAPES_WALL");
    var directions=Direction.values();var column=new Column(COUNT,true);
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var block=state.getBlock();var name=BuiltInRegistries.BLOCK.getKey(block).toString();long flags=0;
      if(state.isAir())flags|=1;
      if(state.canBeReplaced())flags|=2;
      if(state.isSolid())flags|=4;
      if(state.hasBlockEntity())flags|=8;
      var processed=state.getPostProcessPos(level,ORIGIN);
      if(processed!=null){
        if(processed.equals(ORIGIN))flags|=16;
        else if(processed.equals(ORIGIN.above()))flags|=1L<<15;
        else throw new IllegalStateException("post-processing elsewhere: "+state);
      }
      try{for(int d=0;d<6;d++)if(state.isFaceSturdy(level,ORIGIN,directions[d]))flags|=32L<<d;}
      catch(IllegalStateException e){flags&=~(63L<<5);levelDependent.add(name);}
      try{
        var collision=state.getCollisionShape(level,ORIGIN);
        for(int d=0;d<6;d++)if(Block.isFaceFull(collision,directions[d]))flags|=1L<<(17+d);
      }catch(IllegalStateException e){levelDependent.add(name);}
      if(block instanceof LiquidBlock)flags|=1L<<11;
      if(state.liquid())flags|=1L<<12;
      if(block instanceof DoublePlantBlock)flags|=1L<<13;
      if(block instanceof MossyCarpetBlock)flags|=1L<<14;
      if(state.isSolidRender())flags|=1L<<16;
      try{if(state.isCollisionShapeFullBlock(level,ORIGIN))flags|=1L<<23;}
      catch(IllegalStateException e){levelDependent.add(name);}
      for(int d=0;d<6;d++){
        var occlusion=state.getFaceOcclusionShape(directions[d]);
        if(occlusion!=Shapes.empty()&&Block.isShapeFullBlock(occlusion))flags|=1L<<(24+d);
      }
      if(block instanceof LiquidBlockContainer)flags|=1L<<30;
      if(block instanceof SimpleWaterloggedBlock)flags|=1L<<31;
      try{
        if(Block.isShapeFullBlock(state.getShape(level,ORIGIN)))flags|=1L<<32;
        if(state.isFaceSturdy(level,ORIGIN,Direction.DOWN,SupportType.CENTER))flags|=1L<<33;
      }catch(IllegalStateException e){levelDependent.add(name);}
      if(block instanceof FallingBlock)flags|=1L<<34;
      try{if(state.isRedstoneConductor(level,ORIGIN))flags|=1L<<35;}
      catch(IllegalStateException e){levelDependent.add(name);}
      if(state.isSignalSource())flags|=1L<<36;
      try{
        var bottom=state.getCollisionShape(level,ORIGIN).getFaceShape(Direction.DOWN);
        if(covers(bottom,post))flags|=1L<<37;
        int bit=38;for(var d:List.of(Direction.NORTH,Direction.EAST,Direction.SOUTH,Direction.WEST))if(covers(bottom,sides.get(d)))flags|=1L<<bit++;else bit++;
      }catch(IllegalStateException e){levelDependent.add(name);}
      if(Block.isExceptionForConnection(state))flags|=1L<<42;
      if(block instanceof IronBarsBlock)flags|=1L<<43;
      if(block instanceof StairBlock)flags|=1L<<44;
      if(block instanceof FenceGateBlock)flags|=1L<<45;
      if(block instanceof WallBlock)flags|=1L<<46;
      if(block instanceof FenceBlock)flags|=1L<<47;
      if(block instanceof DoorBlock)flags|=1L<<48;
      if((boolean)canBurn.invoke(Blocks.FIRE,state))flags|=1L<<49;
      if(state.hasLargeCollisionShape())flags|=1L<<50;
      if(state.is(BlockTags.FENCES)!=(block instanceof FenceBlock))throw new AssertionError("Fence tag differs from the fence class "+state);
      column.set(id,new JsonPrimitive(flags));
    }
    if(FLAG_BITS.size()!=51)throw new AssertionError("flag names");
    return column;
  }

  /**
   * `getSignal` and `getDirectSignal` toward each direction, read through the failing level: a
   * state whose signal reads its neighbourhood (powered wire, comparators, trapped chests, test
   * blocks) names its block as `context` instead.
   */
  static Column signal(){
    var column=new Column(COUNT,true);var directions=Direction.values();int sources=0;
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var value=new JsonObject();
      try{
        var signal=new JsonArray();var direct=new JsonArray();boolean any=false;
        for(var d:directions){
          int s=state.getSignal(PROBE,ORIGIN,d),t=state.getDirectSignal(PROBE,ORIGIN,d);
          if(s<0||s>15||t<0||t>15)throw new AssertionError("signal range "+state);
          signal.add(s);direct.add(t);any|=s>0||t>0;
        }
        if(any&&!state.isSignalSource())throw new AssertionError("A signal from a state that is no source "+state);
        if(any)sources++;
        value.add("signal",signal);value.add("direct",direct);
      }catch(IllegalStateException e){
        value.addProperty("context",BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString());
      }
      column.set(id,value);
    }
    if(sources==0||column.palette.size()>255)throw new AssertionError("signal palette "+column.palette.size());
    return column;
  }

  static Column shape(JsonObject contextual)throws Exception{
    var cache=field(BlockBehaviour.BlockStateBase.class,"cache");
    var maxOffset=BlockBehaviour.class.getDeclaredMethod("getMaxHorizontalOffset");maxOffset.setAccessible(true);
    var offsetBlocks=Set.of(Blocks.BAMBOO,Blocks.POINTED_DRIPSTONE,Blocks.SULFUR_SPIKE);
    var column=new Column(COUNT,true);int offsets=0;
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var cached=cache.get(state);
      if(cached!=null){column.set(id,geometry((VoxelShape)field(cached.getClass(),"collisionShape").get(cached)));continue;}
      var block=state.getBlock();var value=new JsonObject();value.addProperty("context",BuiltInRegistries.BLOCK.getKey(block).toString());
      if(offsetBlocks.contains(block)){
        var offset=state.getOffset(BlockPos.ZERO);if(offset.y!=0.0)throw new AssertionError("Unexpected vertical offset");
        value.add("shape",geometry(state.getCollisionShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO).move(-offset.x,-offset.y,-offset.z)));
        value.addProperty("max_offset",((Float)maxOffset.invoke(block)).doubleValue());offsets++;
      }else if(!(block instanceof ScaffoldingBlock||block instanceof PowderSnowBlock||block instanceof ShulkerBoxBlock||block instanceof MovingPistonBlock))
        throw new AssertionError("Unclassified contextual shape "+state);
      column.set(id,value);
    }
    if(offsets!=52)throw new AssertionError("Wrong position-offset state coverage");
    contextual.add("scaffolding_stable",geometry(scaffoldingField("SHAPE_STABLE")));
    contextual.add("scaffolding_unstable_bottom",geometry(scaffoldingField("SHAPE_UNSTABLE_BOTTOM")));
    contextual.addProperty("scaffolding_below_height",scaffoldingField("SHAPE_BELOW_BLOCK").max(Axis.Y));
    contextual.add("powder_snow_falling",geometry((VoxelShape)field(PowderSnowBlock.class,"FALLING_COLLISION_SHAPE").get(null)));
    contextual.add("full",geometry(Shapes.block()));
    return column;
  }

  static Column motion(){
    var column=new Column(COUNT,true);
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var block=state.getBlock();var f=new JsonObject();
      f.addProperty("friction",(double)block.getFriction());f.addProperty("speed_factor",(double)block.getSpeedFactor());
      f.addProperty("jump_factor",(double)block.getJumpFactor());f.addProperty("bounciness",(double)block.getBounceRestitution());
      f.addProperty("suppresses_bounce",state.is(BlockTags.SUPPRESSES_BOUNCE));
      // Movement's 0.500001 offset is above the native fence-only <= 0.5 branch.
      f.addProperty("support_holds_y",block instanceof FenceGateBlock||state.is(BlockTags.WALLS));
      f.addProperty("speed_override",block==Blocks.WATER||block==Blocks.BUBBLE_COLUMN);
      column.set(id,f);
    }
    return column;
  }

  static Column fluid()throws Exception{
    var probe=probe(Probe.class);var column=new Column(COUNT,true);
    for(int id=0;id<COUNT;id++){
      var fluid=STATES[id].getFluidState();var type=fluid.getType();
      int kind=fluid.isEmpty()?0:(type==Fluids.WATER||type==Fluids.FLOWING_WATER)?1:(type==Fluids.LAVA||type==Fluids.FLOWING_LAVA)?2:-1;
      if(kind<0)throw new AssertionError("Unknown native fluid "+type);
      int replacement=Block.getId(fluid.createLegacyBlock());
      for(boolean moving:new boolean[]{false,true}){
        probe.fluid=fluid;probe.calls=0;
        if(!probe.removeBlock(BlockPos.ZERO,moving)||probe.calls!=1||Block.getId(probe.replacement)!=replacement||probe.flags!=(moving?67:3))
          throw new AssertionError("Native base removal "+STATES[id]);
      }
      var f=new JsonObject();f.addProperty("kind",kind);f.addProperty("amount",fluid.getAmount());f.addProperty("height",(double)fluid.getOwnHeight());
      f.addProperty("source",fluid.isSource());f.addProperty("falling",fluid.hasProperty(FlowingFluid.FALLING)&&fluid.getValue(FlowingFluid.FALLING));
      f.addProperty("replacement",replacement);column.set(id,f);
    }
    return column;
  }

  static long flagsOf(Column flags,int id){return flags.palette.get(flags.values[id]).getAsLong();}

  static Column boundary(Column flags)throws Exception{
    var cache=field(BlockBehaviour.BlockStateBase.class,"cache");var column=new Column(COUNT,true);int contextual=0;
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var block=state.getBlock();String context="none";
      if(block instanceof MovingPistonBlock)context="piston";
      else if(block instanceof ShulkerBoxBlock)context="shulker";
      // The sturdy faces are the flags': confirm them under an empty level at other positions.
      int faces=(int)(flagsOf(flags,id)>>5&63);
      if(context.equals("none"))for(var p:List.of(BlockPos.ZERO,new BlockPos(-17,-384,19),new BlockPos(1000000,1000000,-1000000))){
        int mask=0;for(var d:Direction.values())if(state.isFaceSturdy(EmptyBlockGetter.INSTANCE,p,d))mask|=1<<d.ordinal();
        if(mask!=faces)throw new AssertionError("Position-dependent or level-dependent support "+state);
        if(p.equals(BlockPos.ZERO)&&cache.get(state)!=null)break;
      }
      else{contextual++;if(faces!=0)throw new AssertionError("Contextual state with sturdy flags "+state);}
      var f=new JsonObject();f.addProperty("blocks_flow",state.is(BlockTags.BLOCKS_FLUID_FLOW));f.addProperty("ice",block instanceof IceBlock);
      f.addProperty("context",context);column.set(id,f);
    }
    if(contextual!=114)throw new AssertionError("Incomplete contextual support classification");
    return column;
  }

  static Column inside(){
    var column=new Column(COUNT,true);int custom=0;
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var block=state.getBlock();String kind="none";
      if(block==Blocks.FIRE)kind="fire";
      else if(block==Blocks.SOUL_FIRE)kind="soul_fire";
      else if(block instanceof BaseFireBlock)throw new AssertionError("Unknown fire block");
      else if(block instanceof PowderSnowBlock)kind="powder_snow";
      else if(block instanceof WebBlock)kind="cobweb";
      else if(block instanceof SweetBerryBushBlock)kind="berry_bush";
      var f=new JsonObject();f.addProperty("kind",kind);
      if(block==Blocks.POWDER_SNOW)f.addProperty("shape","context"); // Needs the entity's collision context.
      else{
        var shape=state.getEntityInsideCollisionShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO,null);
        if(shape!=Shapes.block()){
          var boxes=new JsonArray();
          for(var b:shape.toAabbs()){var box=new JsonArray();for(double n:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})box.add(n);boxes.add(box);}
          if(!shape.toAabbs().equals(state.getEntityInsideCollisionShape(EmptyBlockGetter.INSTANCE,new BlockPos(31,-7,19),null).toAabbs()))
            throw new AssertionError("Position-dependent inside shape");
          f.add("shape",boxes);custom++;
        }
      }
      column.set(id,f);
    }
    if(custom!=136)throw new AssertionError("Changed inside-shape exceptions: "+custom);
    return column;
  }

  static Column hazard()throws Exception{
    var damage=field(CampfireBlock.class,"fireDamage");var column=new Column(COUNT,true);
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];String kind;int value;
      if(state.is(Blocks.MAGMA_BLOCK)){kind="magma";value=1;}
      else if(state.is(Blocks.CAMPFIRE)||state.is(Blocks.SOUL_CAMPFIRE)){kind="campfire";value=state.getValue(BlockStateProperties.LIT)?damage.getInt(state.getBlock()):0;}
      else if(state.is(Blocks.CACTUS)){kind="cactus";value=1;}
      else if(state.is(Blocks.SWEET_BERRY_BUSH)){kind="berry";value=state.getValue(BlockStateProperties.AGE_3);}
      else{column.set(id,JsonNull.INSTANCE);continue;}
      var f=new JsonObject();f.addProperty("kind",kind);f.addProperty("value",value);column.set(id,f);
    }
    return column;
  }

  static Column landing(Column flags)throws Exception{
    var landing=Landing.create();var column=new Column(COUNT,true);
    int fence=FLAG_BITS.indexOf("fence");
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var rules=new JsonArray();rules.add(landing.rule(state,false));rules.add(landing.rule(state,true));column.set(id,rules);
      // The legacy support height is the motion fact or a fence; nothing else keeps it.
      boolean holds=state.getBlock() instanceof FenceGateBlock||state.is(BlockTags.WALLS)||(flagsOf(flags,id)>>fence&1)!=0;
      if(landing.holdsY(state)!=holds)throw new AssertionError("Legacy support height differs "+state);
    }
    return column;
  }

  static Column mining(){
    var column=new Column(COUNT,true);
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];var f=new JsonObject();
      f.addProperty("hardness",(double)state.getDestroySpeed(EmptyBlockGetter.INSTANCE,BlockPos.ZERO));
      f.addProperty("requires_correct_tool",state.requiresCorrectToolForDrops());column.set(id,f);
    }
    return column;
  }

  static Column explosion(){
    var column=new Column(COUNT,true);var calculator=new net.minecraft.world.level.ExplosionDamageCalculator();
    for(int id=0;id<COUNT;id++){
      var state=STATES[id];
      var resistance=calculator.getBlockExplosionResistance(null,EmptyBlockGetter.INSTANCE,ORIGIN,state,state.getFluidState());
      column.set(id,resistance.isPresent()?new JsonPrimitive((double)resistance.get()):JsonNull.INSTANCE);
    }
    return column;
  }

  static Column heightmap(JsonArray names){
    var types=Heightmap.Types.values();for(var type:types)names.add(type.getSerializedName());
    if(!Heightmap.Types.MOTION_BLOCKING.isOpaque().test(Blocks.STONE.defaultBlockState()))throw new AssertionError("Missing native heightmap tags");
    var column=new Column(COUNT,false);
    for(int id=0;id<COUNT;id++){int mask=0;for(int i=0;i<types.length;i++)if(types[i].isOpaque().test(STATES[id]))mask|=1<<i;column.set(id,mask);}
    return column;
  }

  /** Bits over class pairs, checked for every state against every representative. */
  interface Pair{boolean test(BlockState a,BlockState b)throws Exception;}
  static String table(Column from,List<BlockState> fromReps,Column to,List<BlockState> toReps,Pair pair)throws Exception{
    int size=toReps.size();var bits=new byte[(fromReps.size()*size+7)/8];
    for(int a=0;a<fromReps.size();a++)for(int b=0;b<size;b++)if(pair.test(fromReps.get(a),toReps.get(b))){int o=a*size+b;bits[o/8]|=(byte)(1<<(o%8));}
    for(int id=0;id<COUNT;id++){
      int a=from.values[id],b=to.values[id];
      for(int k=0;k<size;k++){int o=a*size+k;if(pair.test(STATES[id],toReps.get(k))!=((bits[o/8]&(1<<(o%8)))!=0))throw new AssertionError("from-class mismatch "+STATES[id]);}
      for(int k=0;k<fromReps.size();k++){int o=k*size+b;if(pair.test(fromReps.get(k),STATES[id])!=((bits[o/8]&(1<<(o%8)))!=0))throw new AssertionError("to-class mismatch "+STATES[id]);}
    }
    return HexFormat.of().formatHex(bits);
  }

  /** Classes of states by a key, with the first state of each class as its representative. */
  static Column classes(List<BlockState> representatives,java.util.function.Function<BlockState,String> key){
    var column=new Column(COUNT,false);var ids=new LinkedHashMap<String,Integer>();
    for(int id=0;id<COUNT;id++){
      var k=key.apply(STATES[id]);Integer index=ids.get(k);
      if(index==null){index=ids.size();ids.put(k,index);representatives.add(STATES[id]);}
      if(index>255)throw new AssertionError("Too many classes");
      column.set(id,index);
    }
    return column;
  }

  static JsonObject sky()throws Exception{
    var edge=ChunkSkyLightSources.class.getDeclaredMethod("isEdgeOccluded",BlockState.class,BlockState.class);edge.setAccessible(true);
    var reps=new ArrayList<BlockState>();
    var column=classes(reps,s->(s.getLightDampening()>0)+":"+boxes(LightEngine.getOcclusionShape(s,Direction.DOWN))+":"+boxes(LightEngine.getOcclusionShape(s,Direction.UP)));
    var out=column.json();out.addProperty("classes",reps.size());
    out.addProperty("pairs",table(column,reps,column,reps,(above,below)->(boolean)edge.invoke(null,above,below)));
    return out;
  }

  static void lightFaces(JsonObject columns)throws Exception{
    var directions=Direction.values();var faces=new Column[6];var reps=new ArrayList<List<BlockState>>();
    for(var d:directions){var r=new ArrayList<BlockState>();faces[d.ordinal()]=classes(r,s->boxes(LightEngine.getOcclusionShape(s,d)));reps.add(r);}
    for(var d:directions){
      int from=d.ordinal(),to=d.getOpposite().ordinal();var out=faces[from].json();out.addProperty("classes",reps.get(from).size());
      out.addProperty("occludes",table(faces[from],reps.get(from),faces[to],reps.get(to),
          (a,b)->Shapes.faceShapeOccludes(LightEngine.getOcclusionShape(a,d),LightEngine.getOcclusionShape(b,d.getOpposite()))));
      columns.add("light_"+d.getSerializedName(),out);
    }
  }

  /** The block entity type each block with one creates (the type that lists the block as valid). */
  static JsonObject blockEntityTypes(){
    var byBlock=new TreeMap<String,String>();
    for(var type:BuiltInRegistries.BLOCK_ENTITY_TYPE)for(var block:BuiltInRegistries.BLOCK)
      if(block instanceof EntityBlock&&type.isValid(block.defaultBlockState())){
        var previous=byBlock.put(BuiltInRegistries.BLOCK.getKey(block).toString(),BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(type).toString());
        if(previous!=null)throw new IllegalStateException("two block entity types for "+block);
      }
    var out=new JsonObject();byBlock.forEach(out::addProperty);return out;
  }
}
