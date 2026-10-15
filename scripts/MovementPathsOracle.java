import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.storage.*;
import net.minecraft.world.phys.Vec3;

/** Actual native bounded movement queue and final-position gap collection, without block callbacks. */
public class MovementPathsOracle {
  private static class Probe extends Entity {
    private Probe(){super(null,null);}
    protected void defineSynchedData(SynchedEntityData.Builder b){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){return false;}
    protected boolean isAffectedByBlocks(){return false;}
    void collect(){applyEffectsFromBlocks();}
  }
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var movement=Class.forName("net.minecraft.world.entity.Entity$Movement");var constructor=movement.getDeclaredConstructor(Vec3.class,Vec3.class,Vec3.class);constructor.setAccessible(true);
    var add=Entity.class.getDeclaredMethod("addMovementThisTick",movement);add.setAccessible(true);
    var from=movement.getDeclaredMethod("from");from.setAccessible(true);var to=movement.getDeclaredMethod("to");to.setAccessible(true);var axis=movement.getDeclaredMethod("axisDependentOriginalMovement");axis.setAccessible(true);
    var out=new JsonArray();
    for(int count:new int[]{0,1,2,99,100,101,102,150,301})for(double gap:new double[]{0,Math.nextDown(1e-5f),(double)1e-5f,Math.nextUp(1e-5f),.001}){
      var p=(Probe)u.allocateInstance(Probe.class);var queue=new ArrayDeque<Object>();var collected=new ArrayList<Object>();field(Entity.class,"movementThisTick").set(p,queue);field(Entity.class,"finalMovementsThisTick").set(p,collected);
      var origin=new Vec3(.5,64,.5);Vec3 current=origin;var inputs=new JsonArray();
      for(int i=0;i<count;i++){
        var next=current.add(.01,(i%3-1)*.001,(i%2==0?.002:-.002));var requested=next.subtract(current);add.invoke(p,constructor.newInstance(current,next,requested));
        var path=new JsonObject();path.add("from",vector(current));path.add("actual",vector(requested));path.add("axis",vector(requested));inputs.add(path);current=next;
      }
      var endpoint=current.add(gap,0,0);field(Entity.class,"position").set(p,endpoint);p.xOld=origin.x;p.yOld=origin.y;p.zOld=origin.z;p.collect();
      if(!queue.isEmpty())throw new AssertionError("Native collection did not clear history");
      var paths=new JsonArray();for(var path:collected){var c=new JsonObject();c.add("from",vector((Vec3)from.invoke(path)));c.add("to",vector((Vec3)to.invoke(path)));var v=(Optional<Vec3>)axis.invoke(path);c.add("axis",v.isPresent()?vector(v.get()):JsonNull.INSTANCE);paths.add(c);}
      var c=new JsonObject();c.add("inputs",inputs);c.add("old",vector(origin));c.add("current",vector(endpoint));c.add("paths",paths);out.add(c);
    }
    Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out));System.out.println("PASS: "+out.size()+" actual native history coalescing and final-gap cases.");
  }
}
