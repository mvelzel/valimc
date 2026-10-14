import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.tags.EntityTypeTags;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.*;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.piston.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import sun.misc.Unsafe;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;

/** Original fixtures query the actual ordered iterator over a complete virtual air world. */
public class BlockCollisionOracle {
  private static final JsonArray cases=new JsonArray();
  private static Field shulkerOld,shulkerCurrent,pistonOld,pistonCurrent;
  private static ThreadLocal<Direction> noclip;
  private static class Context extends EntityCollisionContext {
    Context(double bottom,boolean descending,boolean placement,Entity entity) {
      super(descending,placement,bottom,ItemStack.EMPTY,false,entity);
    }
  }
  private static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static JsonArray position(BlockPos p){return vector(p.getX(),p.getY(),p.getZ());}
  private static JsonObject empty(){var c=new JsonObject();c.addProperty("kind","empty");return c;}
  private static Field field(Class<?> c,String name) throws Exception {
    var f=c.getDeclaredField(name);f.setAccessible(true);return f;
  }
  private static JsonObject entityFacts(double bottom,boolean descending,boolean placement,Entity e) {
    var c=new JsonObject();c.addProperty("kind","entity");c.addProperty("bottom",bottom);
    c.addProperty("descending",descending);c.addProperty("placement",placement);c.addProperty("entity_present",e!=null);
    c.addProperty("fall_distance",e==null?0:e.fallDistance);c.addProperty("falling_block",e instanceof FallingBlockEntity);
    c.addProperty("walkable",e!=null&&PowderSnowBlock.canEntityWalkOnPowderSnow(e));return c;
  }
  private static void probe(Map<BlockPos,BlockState> states,Map<BlockPos,BlockEntity> entities,JsonArray beFacts,
      AABB box,CollisionContext context,JsonObject ctx,Direction exclusion) throws Exception {
    InvocationHandler getter=(p,m,a)->switch(m.getName()) {
      case "getBlockState" -> states.getOrDefault((BlockPos)a[0],Blocks.AIR.defaultBlockState());
      case "getBlockEntity" -> entities.get((BlockPos)a[0]);
      default -> throw new AssertionError("Unexpected block lookup: "+m);
    };
    var chunk=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},getter);
    var world=(CollisionGetter)Proxy.newProxyInstance(CollisionGetter.class.getClassLoader(),new Class<?>[]{CollisionGetter.class},
      (p,m,a)->m.getName().equals("getChunkForCollisions")?chunk:getter.invoke(p,m,a));
    var result=new JsonArray();noclip.set(exclusion);
    try {
      var iterator=new BlockCollisions<JsonObject>(world,context,box,false,(pos,shape)->{
        var c=new JsonObject();c.add("position",position(pos));c.addProperty("state",Block.getId(states.get(pos)));
        try {c.add("geometry",CollisionMetadata.geometry(shape));}catch(Exception e){throw new RuntimeException(e);}
        return c;
      });
      while(iterator.hasNext())result.add(iterator.next());
    } finally {noclip.remove();}
    if(result.size()>128)throw new AssertionError("Fixture exceeds runtime collider cap");
    var c=new JsonObject();var entries=new JsonArray();
    for(var e:states.entrySet()) {var s=new JsonObject();s.add("position",position(e.getKey()));s.addProperty("state",Block.getId(e.getValue()));entries.add(s);}
    c.addProperty("default_state",0);c.add("states",entries);c.add("entities",beFacts);c.add("context",ctx);
    c.addProperty("exclusion",exclusion==null?"none":exclusion.getName());
    c.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));c.add("colliders",result);cases.add(c);
  }
  private static void single(BlockState state,BlockPos pos,BlockEntity entity,JsonObject facts,
      CollisionContext context,JsonObject ctx,Direction exclusion) throws Exception {
    var entities=new HashMap<BlockPos,BlockEntity>();if(entity!=null)entities.put(pos,entity);
    var fs=new JsonArray();if(facts!=null){var f=facts.deepCopy();f.add("position",position(pos));fs.add(f);}
    for(var b:List.of(new AABB(.2,.2,.2,.8,.8,.8),new AABB(.2,1.1,.2,.8,1.4,.8),
        new AABB(.4,.6,.8,.6,.9,.95),new AABB(1,.2,.2,1.6,.8,.8),
        new AABB(.5,.2,.2,.5,.8,.8),new AABB(.5,.2,.2,.5+1e-8,.8,.8),
        new AABB(1-1e-8,.2,.2,1.6,.8,.8)))
      probe(Map.of(pos,state),entities,fs,b.move(pos.getX(),pos.getY(),pos.getZ()),context,ctx,exclusion);
  }
  @SuppressWarnings("unchecked")
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    shulkerOld=field(ShulkerBoxBlockEntity.class,"progressOld");shulkerCurrent=field(ShulkerBoxBlockEntity.class,"progress");
    pistonOld=field(PistonMovingBlockEntity.class,"progressO");pistonCurrent=field(PistonMovingBlockEntity.class,"progress");
    noclip=(ThreadLocal<Direction>)field(PistonMovingBlockEntity.class,"NOCLIP").get(null);
    var cache=field(BlockBehaviour.BlockStateBase.class,"cache");var grids=new HashSet<String>();int dynamic=0;
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      var cached=cache.get(state);
      if(cached!=null) {
        var shape=(VoxelShape)field(cached.getClass(),"collisionShape").get(cached);
        if(!grids.add(new Gson().toJson(CollisionMetadata.geometry(shape))))continue;
        for(var pos:List.of(BlockPos.ZERO,new BlockPos(-17,64,17),new BlockPos(29999990,-384,-29999990)))
          single(state,pos,null,null,CollisionContext.empty(),empty(),null);
      } else {
        dynamic++;var pos=new BlockPos(-17,64,17);var be=new JsonObject();
        be.addProperty("kind","absent");single(state,pos,null,be,CollisionContext.empty(),empty(),null);
        if(state.getBlock() instanceof ShulkerBoxBlock) {
          for(float progress:new float[]{0,.5f,1}) {
            var e=new ShulkerBoxBlockEntity(pos,state);shulkerOld.setFloat(e,0);shulkerCurrent.setFloat(e,progress);
            be.addProperty("kind","shulker");be.addProperty("old",0);be.addProperty("current",progress);
            single(state,pos,e,be,CollisionContext.empty(),empty(),null);
          }
        } else if(state.getBlock() instanceof MovingPistonBlock) {
          for(var dir:Direction.values())for(boolean extending:new boolean[]{false,true})for(boolean source:new boolean[]{false,true})
            for(float progress:new float[]{0,.5f,1})for(var exclusion:new Direction[]{null,dir}) {
              var e=new PistonMovingBlockEntity(pos,state,Blocks.STONE.defaultBlockState(),dir,extending,source);
              pistonOld.setFloat(e,progress);pistonCurrent.setFloat(e,progress);
              be.addProperty("kind","piston");be.addProperty("moved",Block.getId(Blocks.STONE.defaultBlockState()));
              be.addProperty("direction",dir.getName());be.addProperty("extending",extending);be.addProperty("source",source);be.addProperty("progress",progress);
              single(state,pos,e,be,CollisionContext.empty(),empty(),exclusion);
            }
        } else if(state.getBlock() instanceof ScaffoldingBlock) {
          for(double bottom:new double[]{64,65,66})for(boolean descending:new boolean[]{false,true})for(boolean placement:new boolean[]{false,true})
            single(state,pos,null,null,new Context(bottom,descending,placement,null),entityFacts(bottom,descending,placement,null),null);
        }
      }
    }
    if(grids.size()!=330||dynamic!=199)throw new AssertionError("State coverage differs");
    // Native entity-presence/fall-distance/tag branches, with controlled fixture tags.
    var unsafe=(Unsafe)field(Unsafe.class,"theUnsafe").get(null);var type=field(Entity.class,"type");
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var kind:List.of("item","falling","walkable")) {
      var e=(Entity)unsafe.allocateInstance(kind.equals("falling")?FallingBlockEntity.class:ItemEntity.class);
      var entityType=kind.equals("falling")?EntityTypes.FALLING_BLOCK:kind.equals("walkable")?EntityTypes.FOX:EntityTypes.ITEM;
      type.set(e,entityType);bind.invoke(entityType.builtInRegistryHolder(),kind.equals("walkable")?List.of(EntityTypeTags.POWDER_SNOW_WALKABLE_MOBS):List.of());
      for(double fall:new double[]{0,2.5,2.5000001})for(double bottom:new double[]{64,65,66})for(boolean down:new boolean[]{false,true}) {
        e.fallDistance=fall;var pos=new BlockPos(-17,64,17);
        single(Blocks.POWDER_SNOW.defaultBlockState(),pos,null,null,new Context(bottom,down,false,e),entityFacts(bottom,down,false,e),null);
      }
    }
    // A mixed layout crosses both region boundaries and retains iterator ordering.
    var states=new HashMap<BlockPos,BlockState>();
    for(int x=-1;x<=1;x++)for(int z=-1;z<=1;z++)states.put(new BlockPos(x,63,z),Blocks.STONE.defaultBlockState());
    states.put(new BlockPos(0,64,0),Blocks.OAK_STAIRS.defaultBlockState());
    states.put(new BlockPos(-1,64,0),Blocks.OAK_FENCE.defaultBlockState());
    states.put(new BlockPos(1,64,1),Blocks.OAK_SLAB.defaultBlockState());
    for(double y:new double[]{63.9,64.5,65,65.5})
      probe(states,Map.of(),new JsonArray(),new AABB(-.8,y,-.2,1.8,y+1.8,1.8),CollisionContext.empty(),empty(),null);
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native ordered collider cases; 330 cached grids / all 199 contextual states.");
  }
}
