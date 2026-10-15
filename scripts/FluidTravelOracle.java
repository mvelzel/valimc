import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;

/** Native Player.travel, with supplied fluid contact and post-collision motion; zero relative input. */
public class FluidTravelOracle {
  private static final Field POSITION=field(Entity.class,"position");
  private static Field field(Class<?> c,String name){try{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}catch(Exception e){throw new RuntimeException(e);}}
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public FluidState getFluidState(BlockPos pos){return Fluids.EMPTY.defaultFluidState();}
  }
  private static class ProbePlayer extends Player {
    ProbeLevel world; Abilities abilities; boolean water,sprint,ground,dolphin,climb,free,shallow;
    double efficiency,gravity,dy; Vec3 resolved,escape;
    private ProbePlayer(){super(null,null);}
    public ServerLevel level(){return world;}
    public Abilities getAbilities(){return abilities;}
    public GameType gameMode(){return GameType.CREATIVE;}
    public boolean isPassenger(){return false;}
    public boolean isSwimming(){return false;}
    public boolean isFallFlying(){return false;}
    public boolean isInLiquid(){return true;}
    public boolean isInWater(){return water;}
    public boolean isSprinting(){return sprint;}
    public boolean onGround(){return ground;}
    public boolean onClimbable(){return climb;}
    public boolean isVehicle(){return false;}
    public double getFluidHeight(TagKey<Fluid> tag){return shallow?.4:1;}
    public double getFluidJumpThreshold(){return .4;}
    public boolean hasEffect(Holder<MobEffect> effect){return effect==MobEffects.DOLPHINS_GRACE&&dolphin;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(attribute==Attributes.WATER_MOVEMENT_EFFICIENCY)return efficiency;
      throw new AssertionError("Unexpected attribute "+attribute);
    }
    public float getSpeed(){return .1f;}
    protected double getEffectiveGravity(){return gravity;}
    public void move(MoverType type,Vec3 requested){
      setDeltaMovement(resolved);
      try{POSITION.set(this,new Vec3(0,getY()+dy,0));}catch(Exception e){throw new RuntimeException(e);}
    }
    public boolean isFree(double x,double y,double z){escape=new Vec3(x,y,z);return free;}
  }
  private static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonObject run(ProbePlayer p,Vec3 initial,Vec3 resolved,double oldY,double dy)throws Exception{
    p.resolved=resolved;p.dy=dy;p.escape=null;POSITION.set(p,new Vec3(0,oldY,0));p.setDeltaMovement(initial);p.travel(Vec3.ZERO);
    var c=new JsonObject();c.addProperty("kind",p.water?"water":"lava");c.add("initial",vec(initial));c.add("resolved",vec(resolved));
    c.addProperty("on_ground",p.ground);c.addProperty("sprint",p.sprint);c.addProperty("dolphins_grace",p.dolphin);
    c.addProperty("water_efficiency",p.efficiency);c.addProperty("gravity",p.gravity);c.addProperty("horizontal_collision",p.horizontalCollision);
    c.addProperty("climbable",p.climb);c.addProperty("shallow",p.shallow);c.addProperty("old_y",oldY);c.addProperty("new_y",p.getY());c.addProperty("free",p.free);
    c.add("escape_query",p.escape==null?JsonNull.INSTANCE:vec(p.escape));c.add("velocity",vec(p.getDeltaMovement()));return c;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var p=(ProbePlayer)u.allocateInstance(ProbePlayer.class);p.world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);p.abilities=new Abilities();
    field(Player.class,"abilities").set(p,p.abilities);
    var cases=new JsonArray();
    for(boolean water:new boolean[]{false,true})for(boolean sprint:new boolean[]{false,true})for(boolean shallow:new boolean[]{false,true})
      for(double gravity:new double[]{0,.08,-.08})for(double efficiency:new double[]{0,.3,1})for(boolean ground:new boolean[]{false,true})
        for(boolean dolphin:new boolean[]{false,true})for(double y:new double[]{-1,-.003,0,.002,.00375,.00625,.01,.3,1}){
          p.water=water;p.sprint=sprint;p.shallow=shallow;p.gravity=gravity;p.efficiency=efficiency;p.ground=ground;p.dolphin=dolphin;
          p.horizontalCollision=false;p.climb=false;p.free=false;var v=new Vec3(.2,y,-.3);cases.add(run(p,v,v,64,y));
        }
    for(boolean water:new boolean[]{false,true})for(boolean climb:new boolean[]{false,true})for(boolean free:new boolean[]{false,true})
      for(boolean shallow:new boolean[]{false,true})for(double y:new double[]{-1,0,.3})for(double oldY:new double[]{0,64,30000000}){
        p.water=water;p.sprint=false;p.shallow=shallow;p.gravity=.08;p.efficiency=0;p.ground=false;p.dolphin=false;
        p.horizontalCollision=true;p.climb=climb;p.free=free;
        cases.add(run(p,new Vec3(.2,y,-.3),new Vec3(0,y,-.3),oldY,y*.5));
      }
    // Repeated transitions invoke native Player.travel each tick, retaining its result.
    var traces=new JsonArray();
    for(int mode=0;mode<3;mode++){
      var steps=new JsonArray();Vec3 v=new Vec3(.2,.3,-.1);
      for(int tick=0;tick<200;tick++){
        p.water=mode==0||(mode==2&&tick%40<20);p.shallow=mode==1||tick%20<10;p.sprint=tick%30<10;
        p.gravity=.08;p.efficiency=0;p.ground=false;p.dolphin=false;p.horizontalCollision=false;p.climb=false;p.free=false;
        var c=run(p,v,v,64,v.y);steps.add(c);v=p.getDeltaMovement();
      }
      traces.add(steps);
    }
    var result=new JsonObject();result.add("cases",cases);result.add("traces",traces);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native fluid travel branches and 3x200 transition traces; supplied contact/collision, zero relative input.");
  }
}
