import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.CrashReportCategory;
import net.minecraft.ReportedException;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.storage.*;
import net.minecraft.world.phys.Vec3;

/** Calls native Motion save/load prefixes; deliberately excludes unrelated entity/world state. */
public class PlayerMotionPersistenceOracle {
  private static final RuntimeException STOP=new RuntimeException("Motion prefix complete");
  private static class Probe extends Entity {
    boolean stop;
    private Probe(){super(null,null);}
    protected void defineSynchedData(SynchedEntityData.Builder b){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){return false;}
    public void fillCrashReportCategory(CrashReportCategory category){}
    public void setDeltaMovement(Vec3 value){super.setDeltaMovement(value);if(stop)throw STOP;}
  }
  private static void stopped(Runnable action){
    try{action.run();throw new AssertionError("Motion boundary not reached");}
    catch(ReportedException e){if(e.getCause()!=STOP)throw e;}
  }
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);
    var p=(Probe)unsafe.allocateInstance(Probe.class);
    var position=Entity.class.getDeclaredField("position");position.setAccessible(true);position.set(p,Vec3.ZERO);
    var cases=new JsonArray();
    double[] values={-64,-Math.nextUp(10.0),-10,-Math.nextDown(10.0),-1,-0.0,0.0,1,Math.nextDown(10.0),10,Math.nextUp(10.0),64};
    var inputs=new ArrayList<Vec3>();
    for(double value:values){inputs.add(new Vec3(value,.25,-.5));inputs.add(new Vec3(.25,value,-.5));inputs.add(new Vec3(.25,-.5,value));}
    inputs.add(new Vec3(10,-10,Math.nextUp(10.0)));inputs.add(new Vec3(-64,64,64));inputs.add(Vec3.ZERO);
    for(var initial:inputs){
      p.stop=false;p.setDeltaMovement(initial);
      JsonElement[] saved={null};
      var output=(ValueOutput)Proxy.newProxyInstance(ValueOutput.class.getClassLoader(),new Class<?>[]{ValueOutput.class},(proxy,method,a)->{
        if(method.getName().equals("store")&&a[0].equals("Motion")){
          saved[0]=Vec3.CODEC.encodeStart(JsonOps.INSTANCE,(Vec3)a[2]).getOrThrow();throw STOP;
        }
        return null;
      });
      stopped(()->p.saveWithoutId(output));
      var restored=Vec3.CODEC.parse(JsonOps.INSTANCE,saved[0]).getOrThrow();
      var input=(ValueInput)Proxy.newProxyInstance(ValueInput.class.getClassLoader(),new Class<?>[]{ValueInput.class},(proxy,method,a)->{
        if(method.getName().equals("read"))return a[0].equals("Motion")?Optional.of(restored):Optional.empty();
        throw new AssertionError("Unexpected prefix call "+method);
      });
      p.stop=true;stopped(()->p.load(input));
      var c=new JsonObject();c.add("initial",vector(initial));c.add("saved",saved[0]);c.add("loaded",vector(p.getDeltaMovement()));cases.add(c);
    }
    // A missing Motion field uses native Vec3.ZERO, independent of prior state.
    p.stop=false;p.setDeltaMovement(new Vec3(1,2,3));p.stop=true;
    var missing=(ValueInput)Proxy.newProxyInstance(ValueInput.class.getClassLoader(),new Class<?>[]{ValueInput.class},(proxy,method,a)->Optional.empty());
    stopped(()->p.load(missing));if(!p.getDeltaMovement().equals(Vec3.ZERO))throw new AssertionError("Missing motion default");
    var result=new JsonObject();result.add("cases",cases);result.add("missing",vector(p.getDeltaMovement()));
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native Motion codec/save/load prefixes and missing-field default; unrelated entity/world load excluded.");
  }
}
