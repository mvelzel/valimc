import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.effect.MobEffect;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/** Native relative math and rate selection; stops fluid travel at its acceleration boundary. */
public class RelativeMotionOracle {
  private static final RuntimeException STOP=new RuntimeException("acceleration boundary");
  private static class Probe extends Player {
    float yaw,speed,rate; boolean ground,sprint,capture; double efficiency;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public float getYRot(){return yaw;}
    public float getSpeed(){return speed;}
    public boolean onGround(){return ground;}
    public boolean isSprinting(){return sprint;}
    public boolean isPassenger(){return false;}
    public boolean hasEffect(Holder<MobEffect> type){return false;}
    public double getAttributeValue(Holder<Attribute> type){
      if(type==Attributes.WATER_MOVEMENT_EFFICIENCY)return efficiency;
      throw new AssertionError("Unexpected attribute "+type);
    }
    public void moveRelative(float acceleration,Vec3 input){
      if(capture){rate=acceleration;throw STOP;}
      super.moveRelative(acceleration,input);
    }
  }
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var f=field(sun.misc.Unsafe.class,"theUnsafe");var u=(sun.misc.Unsafe)f.get(null);
    var p=(Probe)u.allocateInstance(Probe.class);var a=new Abilities();field(Player.class,"abilities").set(p,a);
    var server=(ServerPlayer)u.allocateInstance(ServerPlayer.class);
    var vector=Entity.class.getDeclaredMethod("getInputVector",Vec3.class,float.class,float.class);vector.setAccessible(true);
    var air=LivingEntity.class.getDeclaredMethod("getFrictionInfluencedSpeed",float.class);air.setAccessible(true);
    var water=LivingEntity.class.getDeclaredMethod("travelInWater",Vec3.class,double.class,boolean.class,double.class);water.setAccessible(true);
    var lava=LivingEntity.class.getDeclaredMethod("travelInLava",Vec3.class,double.class,boolean.class,double.class);lava.setAccessible(true);
    var vectors=new JsonArray();var intents=new JsonArray();var rates=new JsonArray();
    float[] yaws={0,12.345f,45,90,-90,180,-180,359,-359,1000000,-1000000};
    var inputs=List.of(Vec3.ZERO,new Vec3(.00031622,0,0),new Vec3(.00031623,0,0),new Vec3(1,0,0),new Vec3(0,0,1),new Vec3(1,0,1),new Vec3(.1,.2,.3),new Vec3(64,-64,64));
    for(var input:inputs)for(float speed:new float[]{0,.02f,.025999999f,.1f,1,64})for(float yaw:yaws){
      var c=new JsonObject();var initial=new Vec3(.2,-.3,.4);p.capture=false;p.yaw=yaw;p.setDeltaMovement(initial);p.moveRelative(speed,input);
      c.add("input",vec(input));c.addProperty("speed",(double)speed);c.addProperty("yaw",(double)yaw);
      c.add("vector",vec((Vec3)vector.invoke(null,input,speed,yaw)));c.add("initial",vec(initial));c.add("velocity",vec(p.getDeltaMovement()));vectors.add(c);
    }
    for(int buttons=0;buttons<128;buttons++)for(float yaw:yaws){
      server.setYRot(yaw);server.setLastClientInput(new Input((buttons&1)!=0,(buttons&2)!=0,(buttons&4)!=0,(buttons&8)!=0,(buttons&16)!=0,(buttons&32)!=0,(buttons&64)!=0));
      var c=new JsonObject();c.addProperty("buttons",buttons);c.addProperty("yaw",(double)yaw);c.add("intent",vec(server.getLastClientMoveIntent()));intents.add(c);
    }
    for(boolean ground:new boolean[]{false,true})for(boolean flying:new boolean[]{false,true})for(boolean sprint:new boolean[]{false,true})
      for(float speed:new float[]{0,.1f,.13f,1})for(float friction:new float[]{0,.3f,.59999996f,.6f,.98f,1})
        for(float flySpeed:new float[]{.05f,.1f})for(double efficiency:new double[]{0,.3,1}){
          p.ground=ground;p.sprint=sprint;p.speed=speed;p.efficiency=efficiency;a.flying=flying;a.setFlyingSpeed(flySpeed);
          var c=new JsonObject();c.addProperty("on_ground",ground);c.addProperty("flying",flying);c.addProperty("sprint",sprint);
          c.addProperty("movement_speed",(double)speed);c.addProperty("friction",(double)friction);c.addProperty("flying_speed",(double)flySpeed);c.addProperty("water_efficiency",efficiency);
          c.addProperty("air",(double)(Float)air.invoke(p,friction));p.capture=true;
          for(var pair:List.of(Map.entry("water",water),Map.entry("lava",lava))){
            try{pair.getValue().invoke(p,Vec3.ZERO,.08,false,0.0);throw new AssertionError("Missing boundary");}
            catch(InvocationTargetException e){if(e.getCause()!=STOP)throw e;}
            c.addProperty(pair.getKey(),(double)p.rate);
          }
          rates.add(c);
        }
    var result=new JsonObject();result.add("vectors",vectors);result.add("intents",intents);result.add("rates",rates);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+vectors.size()+" native vector/acceleration cases, "+intents.size()+" actual server input intents and "+rates.size()+" dry/water/lava rate contexts.");
  }
}
