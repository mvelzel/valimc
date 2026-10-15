import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.*;

/** Actual native player edge backoff over supplied support geometry, including query order. */
public class SneakEdgesOracle {
  private static class ProbeLevel extends ServerLevel {
    List<AABB> supports;List<AABB> queries;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public boolean noCollision(Entity entity,AABB box){queries.add(box);return supports.stream().noneMatch(box::intersects);}
  }
  private static class Probe extends Player {
    ProbeLevel world;boolean ground,shift;float step;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public ServerLevel level(){return world;}
    public boolean onGround(){return ground;}
    public float maxUpStep(){return step;}
    protected boolean isStayingOnGroundSurface(){return shift;}
    Vec3 run(Vec3 requested,MoverType mover){return maybeBackOffFromEdge(requested,mover);}
  }
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonArray box(AABB b){var a=new JsonArray();for(double v:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})a.add(v);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var p=(Probe)u.allocateInstance(Probe.class);p.world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);var abilities=new Abilities();field(Player.class,"abilities").set(p,abilities);var bounds=field(Entity.class,"bb");var cases=new JsonArray();
    for(double origin:new double[]{0,-17.125,29999900})for(double height:new double[]{1.8f,1.5f,.6f})for(int scene=0;scene<5;scene++){
      var b=new AABB(origin-.3f,64,origin-.3f,origin+.3f,64+height,origin+.3f);bounds.set(p,b);
      p.world.supports=switch(scene){
        case 0 -> List.of();
        case 1 -> List.of(new AABB(origin-2,63,origin-2,origin+.1,64,origin+2));
        case 2 -> List.of(new AABB(origin-2,63,origin-2,origin+.1,64,origin+.1));
        case 3 -> List.of(new AABB(origin-2,62.5,origin-2,origin+.1,63.5,origin+2));
        default -> List.of(new AABB(origin-.2,63,origin-.2,origin+.2,63.5,origin+.2),new AABB(origin+.6,63,origin-.2,origin+.8,64,origin+.2));
      };
      for(var v:List.of(Vec3.ZERO,new Vec3(.03,0,.07),new Vec3(.05,-.1,.05),new Vec3(.1,0,.1),new Vec3(.6,-.08,.4),new Vec3(-.6,0,-.4),new Vec3(.4,.001,.2),new Vec3(2,0,1)))
        for(double fall:new double[]{0,.1,(double).6f,Math.nextUp((double).6f)})for(int flags=0;flags<16;flags++){
          abilities.flying=(flags&1)!=0;p.ground=(flags&2)!=0;p.shift=(flags&4)!=0;p.step=.6f;p.fallDistance=fall;var mover=(flags&8)!=0?MoverType.PISTON:MoverType.PLAYER;p.world.queries=new ArrayList<>();var result=p.run(v,mover);
          var c=new JsonObject();c.add("box",box(b));c.add("requested",vector(v));c.add("result",vector(result));c.addProperty("flying",abilities.flying);c.addProperty("ground",p.ground);c.addProperty("shift",p.shift);c.addProperty("fall",fall);c.addProperty("step",p.step);c.addProperty("mover",mover.toString().toLowerCase(Locale.ROOT));
          var supports=new JsonArray();for(var s:p.world.supports)supports.add(box(s));c.add("supports",supports);var queries=new JsonArray();for(var q:p.world.queries)queries.add(box(q));c.add("queries",queries);cases.add(c);
        }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native player edge cases and ordered support queries.");
  }
}
