import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.phys.*;

/** Original native gravity selection and aiStep fall reset, stopped before travel/world mutation. */
public class GravityEffectOracle {
  static final RuntimeException TRAVEL=new RuntimeException("pre-travel boundary");
  static class Body extends LivingEntity {
    boolean slow,levitation; double gravity;
    private Body(){super(EntityTypes.PLAYER,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public boolean isNoGravity(){return false;}
    public boolean hasEffect(Holder<MobEffect> type){
      if(type==MobEffects.SLOW_FALLING)return slow;
      if(type==MobEffects.LEVITATION)return levitation;
      throw new AssertionError("Unexpected status lookup "+type);
    }
    public double getAttributeValue(Holder<Attribute> type){
      if(type==Attributes.GRAVITY)return gravity;
      throw new AssertionError("Unexpected attribute lookup "+type);
    }
    protected void applyInput(){}
    public boolean isImmobile(){return true;}
    public boolean isFallFlying(){return false;}
    public LivingEntity getControllingPassenger(){throw TRAVEL;}
    public MoveSimulationType getMoveSimulationType(){return MoveSimulationType.SERVER_AND_CLIENT;}
    double effective(){return getEffectiveGravity();}
  }
  static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var body=(Body)u.allocateInstance(Body.class);
    var gravity=new JsonArray();var reset=new JsonArray();
    int hooks=0;
    for(var type:new MobEffect[]{MobEffects.SLOW_FALLING.value(),MobEffects.LEVITATION.value()}){
      if(type.getClass()!=MobEffect.class||type.isInstantaneous())throw new AssertionError("Unexpected travel effect implementation");
      for(int amp=0;amp<256;amp++){
        int[] attributes={0};type.createModifiers(amp,(attribute,modifier)->attributes[0]++);
        if(attributes[0]!=0)throw new AssertionError("Unexpected travel effect attribute");
        type.onEffectStarted(null,amp);type.onEffectAdded(null,amp);
        type.addAttributeModifiers(null,amp);type.removeAttributeModifiers(null);
        if(!type.applyEffectTick(null,null,amp))throw new AssertionError("Unexpected terminal request");
        for(int duration:new int[]{-1,0,1,20,300,Integer.MAX_VALUE})
          if(type.shouldApplyEffectTickThisTick(duration,amp))throw new AssertionError("Unexpected periodic request");
        hooks++;
      }
    }
    for(boolean slow:new boolean[]{false,true})
      for(double base:new double[]{-.08,0,.005,.01,.08,1})
        for(double y:new double[]{-64,-1,-Double.MIN_VALUE,-0.0,0.0,Double.MIN_VALUE,1,64}){
          body.slow=slow;body.gravity=base;body.setDeltaMovement(new Vec3(0,y,0));
          var row=new JsonObject();row.addProperty("slow_falling",slow);row.addProperty("base",base);
          row.addProperty("velocity_y",y);row.addProperty("gravity",body.effective());gravity.add(row);
        }
    field(Entity.class,"type").set(body,EntityTypes.PLAYER);
    field(Entity.class,"bb").set(body,new AABB(0,64,0,.6,65.8,.6));
    field(LivingEntity.class,"equipment").set(body,new EntityEquipment());
    field(Entity.class,"interpolationHandler").set(body,Proxy.newProxyInstance(InterpolationHandler.class.getClassLoader(),new Class<?>[]{InterpolationHandler.class},(proxy,method,a)->false));
    for(boolean slow:new boolean[]{false,true})for(boolean levitation:new boolean[]{false,true})
      for(double distance:new double[]{0,12.5})for(double y:new double[]{-1,0,1}){
        body.slow=slow;body.levitation=levitation;body.fallDistance=distance;body.setDeltaMovement(new Vec3(0,y,0));
        try{body.aiStep();throw new AssertionError("No pre-travel boundary");}catch(RuntimeException error){if(error!=TRAVEL)throw error;}
        var row=new JsonObject();row.addProperty("slow_falling",slow);row.addProperty("levitation",levitation);
        row.addProperty("initial",distance);row.addProperty("velocity_y",y);row.addProperty("distance",body.fallDistance);reset.add(row);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);
    out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("hook_contexts",hooks);out.add("gravity",gravity);out.add("reset",reset);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+hooks+" native no-action/no-attribute hooks, "+gravity.size()+" actual gravity selections and "+reset.size()+" actual aiStep pre-travel fall resets; input/immobility controlled, travel/world/client excluded.");
  }
}
