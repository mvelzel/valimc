import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.level.block.state.properties.SlabType;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;

/** Complete controlled worlds compose actual native occupancy and player selection. */
public class PlayerFitOracle {
  private static class ProbePlayer extends Player {
    int intent;Pose pose;CollisionGetter world;List<Pose> queries;Map<Pose,Boolean> fits;
    private ProbePlayer(){super(null,null);}
    public GameType gameMode(){return (intent&64)!=0?GameType.SPECTATOR:GameType.CREATIVE;}
    public boolean isSleeping(){return (intent&1)!=0;}
    public boolean isSwimming(){return (intent&2)!=0;}
    public boolean isFallFlying(){return (intent&4)!=0;}
    public boolean isAutoSpinAttack(){return (intent&8)!=0;}
    public boolean isShiftKeyDown(){return (intent&16)!=0;}
    public boolean isPassenger(){return (intent&128)!=0;}
    public boolean isPassengerOfSameVehicle(Entity other){return ((ProbeItem)other).sameVehicle;}
    public Pose getPose(){return pose;}
    public void setPose(Pose value){pose=value;}
    protected boolean canPlayerFitWithinBlocksAndEntitiesWhen(Pose value) {
      queries.add(value);
      // Explicit default dimensions: scaling/effects are outside this slice.
      boolean clear=world.noCollision(this,getDefaultDimensions(value).makeBoundingBox(position()).deflate(1e-7));
      fits.put(value,clear);return clear;
    }
    void update(){updatePlayerPose();}
  }
  private static class ProbeItem extends ItemEntity {
    boolean solid,spectator,sameVehicle;
    private ProbeItem(){super(null,null);}
    public boolean canBeCollidedWith(Entity subject){return solid;}
    public boolean isSpectator(){return spectator;}
  }
  private static Field field(Class<?> owner,String name) throws Exception {
    var f=owner.getDeclaredField(name);f.setAccessible(true);return f;
  }
  private static JsonArray vector(double... values){var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static JsonArray box(AABB b){return vector(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ);}
  @SuppressWarnings("unchecked")
  public static void main(String[] args) throws Throwable {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var p=(ProbePlayer)unsafe.allocateInstance(ProbePlayer.class);var abilities=new Abilities();field(Player.class,"abilities").set(p,abilities);
    var cases=new JsonArray();
    for(double x:new double[]{.5,3.8})for(double diameter:new double[]{8,59999968})for(int layout=0;layout<4;layout++)
      for(int kind=0;kind<8;kind++) {
        var position=new Vec3(x,64,.5);field(Entity.class,"position").set(p,position);
        var states=new HashMap<BlockPos,BlockState>();var at=new BlockPos((int)Math.floor(x),65,0);
        if(layout!=0)states.put(layout==3?at.below():at,layout==1?
          Blocks.OAK_SLAB.defaultBlockState().setValue(SlabBlock.TYPE,SlabType.TOP):Blocks.STONE.defaultBlockState());
        var border=new WorldBorder();border.setSize(diameter);
        var entity=(ProbeItem)unsafe.allocateInstance(ProbeItem.class);entity.solid=kind!=1;entity.spectator=kind==5;entity.sameVehicle=kind==6;
        double bottom=kind==3?65.6:kind==4?64.9:64.2;
        var eb=kind==7?new AABB(x,64.3,.5,x,64.4,.5):new AABB(x-.2,bottom,.3,x+.2,65.8,.7);
        field(Entity.class,"bb").set(entity,eb);var entities=kind==0?List.<ProbeItem>of():List.of(entity);
        var chunk=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},
          (proxy,m,a)->m.getName().equals("getBlockState")?states.getOrDefault((BlockPos)a[0],Blocks.AIR.defaultBlockState()):null);
        var entityMethod=EntityGetter.class.getMethod("getEntityCollisions",Entity.class,AABB.class);
        p.world=(CollisionGetter)Proxy.newProxyInstance(CollisionGetter.class.getClassLoader(),new Class<?>[]{CollisionGetter.class,EntityGetter.class},
          (proxy,m,a)-> {
            switch(m.getName()) {
              case "getChunkForCollisions":return chunk;
              case "getWorldBorder":return border;
              case "getBlockCollisions":return (Iterable<VoxelShape>)()->new BlockCollisions<VoxelShape>((CollisionGetter)proxy,
                CollisionContext.empty(),(AABB)a[1],false,(pos,shape)->shape);
              case "getEntityCollisions":return InvocationHandler.invokeDefault(proxy,entityMethod,a);
              case "getEntities": {
                var result=new ArrayList<Entity>();var predicate=(Predicate<Entity>)a[2];
                for(var e:entities)if(e.getBoundingBox().intersects((AABB)a[1])&&predicate.test(e))result.add(e);
                return result;
              }
              default:if(m.isDefault())return InvocationHandler.invokeDefault(proxy,m,a);throw new AssertionError(m);
            }
          });
        for(int intent:new int[]{0,16,48,2,4,8,64,128})for(var initial:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING)) {
          p.intent=intent;p.pose=initial;p.queries=new ArrayList<>();p.fits=new LinkedHashMap<>();abilities.flying=(intent&32)!=0;
          p.update();var c=new JsonObject();c.addProperty("intent",intent);c.addProperty("current",initial.getSerializedName());
          c.add("position",vector(x,64,.5));c.addProperty("diameter",diameter);var blocks=new JsonArray();
          for(var e:states.entrySet()){var b=new JsonObject();b.add("position",vector(e.getKey().getX(),e.getKey().getY(),e.getKey().getZ()));b.addProperty("state",Block.getId(e.getValue()));blocks.add(b);}
          c.add("blocks",blocks);var es=new JsonArray();for(var e:entities){var f=new JsonObject();f.addProperty("id",2);f.add("box",box(eb));
            f.addProperty("collidable",e.solid);f.addProperty("spectator",e.spectator);f.addProperty("same_vehicle",e.sameVehicle);es.add(f);}
          c.add("entities",es);c.addProperty("selected",p.pose.getSerializedName());
          var queries=new JsonArray();for(var q:p.queries)queries.add(q.getSerializedName());c.add("queries",queries);
          var fits=new JsonObject();for(var f:p.fits.entrySet())fits.addProperty(f.getKey().getSerializedName(),f.getValue());c.add("fits",fits);cases.add(c);
        }
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native composed occupancy/pose cases.");
  }
}
