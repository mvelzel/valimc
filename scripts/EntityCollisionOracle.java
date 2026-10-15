import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.level.EntityGetter;
import net.minecraft.world.phys.AABB;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.Predicate;

/** Original controlled observations exercise native collection and player predicates. */
public class EntityCollisionOracle {
  private static sun.misc.Unsafe unsafe;
  private static Field bounds;
  private static class Probe extends ItemEntity {
    int fixtureId; boolean spectator,solid,anonymousSolid,sameVehicle;
    private Probe(){super(null,null);}
    public boolean isSpectator(){return spectator;}
    public boolean canBeCollidedWith(Entity subject){return subject==null?anonymousSolid:solid;}
    public boolean isPassengerOfSameVehicle(Entity candidate){return ((Probe)candidate).sameVehicle;}
  }
  private static JsonArray bits(AABB box) {
    var a=new JsonArray();for(double v:new double[]{box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ})
      a.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(v)));return a;
  }
  private static Probe entity(int id,AABB box,int mask) throws Exception {
    var e=(Probe)unsafe.allocateInstance(Probe.class);e.fixtureId=id;
    e.spectator=(mask&1)!=0;e.solid=(mask&2)!=0;e.anonymousSolid=(mask&4)!=0;e.sameVehicle=(mask&8)!=0;
    bounds.set(e,box);return e;
  }
  @SuppressWarnings("unchecked")
  private static JsonObject probe(AABB box,Probe subject,List<Probe> candidates) throws Throwable {
    var c=new JsonObject();c.add("box",bits(box));
    if(subject==null)c.add("subject",JsonNull.INSTANCE);else c.addProperty("subject",subject.fixtureId);
    var supplied=new JsonArray();for(var e:candidates) {
      var f=new JsonObject();f.addProperty("id",e.fixtureId);f.add("box",bits(e.getBoundingBox()));
      f.addProperty("spectator",e.isSpectator());f.addProperty("collidable",e.canBeCollidedWith(subject));
      f.addProperty("same_vehicle",e.sameVehicle);supplied.add(f);
    }
    c.add("candidates",supplied);var selected=new ArrayList<Probe>();
    var getter=(EntityGetter)Proxy.newProxyInstance(EntityGetter.class.getClassLoader(),new Class<?>[]{EntityGetter.class},
      (p,m,a)-> {
        if(m.isDefault())return InvocationHandler.invokeDefault(p,m,a);
        if(!m.getName().equals("getEntities")||a.length!=3)throw new AssertionError(m);
        var query=(AABB)a[1];var predicate=(Predicate<Entity>)a[2];c.add("query_box",bits(query));
        for(var e:candidates)if(e!=a[0]&&e.getBoundingBox().intersects(query)&&predicate.test(e))selected.add(e);
        return selected;
      });
    var shapes=getter.getEntityCollisions(subject,box);var result=new JsonArray();
    for(int i=0;i<shapes.size();i++) {
      var e=selected.get(i);var f=new JsonObject();f.addProperty("id",e.fixtureId);f.add("box",bits(e.getBoundingBox()));
      f.add("geometry",CollisionMetadata.geometry(shapes.get(i)));result.add(f);
    }
    if(!c.has("query_box"))c.add("query_box",JsonNull.INSTANCE);
    c.add("colliders",result);return c;
  }
  public static void main(String[] args) throws Throwable {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var u=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");u.setAccessible(true);unsafe=(sun.misc.Unsafe)u.get(null);
    bounds=Entity.class.getDeclaredField("bb");bounds.setAccessible(true);
    if(Probe.class.getMethod("canCollideWith",Entity.class).getDeclaringClass()!=Entity.class)throw new AssertionError("Non-default predicate");
    if(net.minecraft.world.entity.player.Player.class.getMethod("canCollideWith",Entity.class).getDeclaringClass()!=Entity.class)
      throw new AssertionError("Player overrides default predicate");
    var cases=new JsonArray();
    for(double offset:new double[]{0,-17.125,29999900}) {
      var queries=new ArrayList<AABB>();queries.add(new AABB(0,0,0,.6,1.8,.6));
      for(double n:new double[]{0,1e-8,Math.nextDown(1e-7),1e-7,Math.nextUp(1e-7),2e-7})queries.add(new AABB(0,0,0,n,n,n));
      queries.add(new AABB(0,0,0,0,1.8,.6));queries.add(new AABB(0,0,0,.6,0,.6));
      for(var origin:queries) {
        var box=origin.move(offset,64,-offset);
        for(boolean anonymous:new boolean[]{false,true})for(int mask=0;mask<16;mask++) {
          var subject=entity(1,box,6);var candidates=new ArrayList<Probe>();
          var boxes=List.of(box,box.move(2,0,0),new AABB(box.maxX+5e-8,64,box.minZ,box.maxX+.5,65,box.maxZ),
            new AABB(box.maxX+1e-7,64,box.minZ,box.maxX+.5,65,box.maxZ),
            new AABB(box.maxX+2e-7,64,box.minZ,box.maxX+.5,65,box.maxZ),
            new AABB(box.minX,64,box.minZ,box.minX,65,box.minZ));
          for(int i=0;i<boxes.size();i++) {
            var e=entity(i+2,boxes.get(i),mask);
            cases.add(probe(box,anonymous?null:subject,List.of(e)));
            candidates.add(e);
          }
          candidates.add(2,subject);Collections.reverse(candidates);
          cases.add(probe(box,anonymous?null:subject,candidates));
        }
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native ordered entity-collision queries.");
  }
}
