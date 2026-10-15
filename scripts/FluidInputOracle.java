import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.phys.*;

/** Actual LivingEntity.aiStep through normalization/jump, stopped at travel; native sink primitive. */
public class FluidInputOracle {
  private static final RuntimeException STOP=new RuntimeException("Stopped at native travel boundary");
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  }
  private static class Probe extends LivingEntity {
    ProbeLevel world;double water,lava,threshold;boolean ground,affected;String action;
    private Probe(){super(EntityTypes.PLAYER,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public ServerLevel level(){return world;}
    protected void applyInput(){}
    public MoveSimulationType getMoveSimulationType(){return MoveSimulationType.SERVER_AND_CLIENT;}
    public boolean isDescending(){return false;}
    public boolean isShiftKeyDown(){return false;}
    public ItemStack getMainHandItem(){return ItemStack.EMPTY;}
    public boolean isImmobile(){return false;}
    public boolean isEffectiveAi(){return true;}
    protected void serverAiStep(){}
    public boolean isInWater(){return water>0;}
    public boolean isInLava(){return lava>0;}
    public boolean isAffectedByFluids(){return affected;}
    public boolean onGround(){return ground;}
    public double getFluidHeight(TagKey<Fluid> tag){return tag==FluidTags.WATER?water:lava;}
    public double getFluidJumpThreshold(){return threshold;}
    public boolean isFallFlying(){return false;}
    public boolean hasEffect(Holder<MobEffect> effect){return false;}
    public LivingEntity getControllingPassenger(){return null;}
    public void travel(Vec3 input){throw STOP;}
    public void jumpFromGround(){action="ground";}
    protected void jumpInLiquid(TagKey<Fluid> tag){action="float";super.jumpInLiquid(tag);}
    public void sink(){goDownInWater();}
  }
  private static Field field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var p=(Probe)u.allocateInstance(Probe.class);p.world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);
    field(Entity.class,"type").set(p,EntityTypes.PLAYER);field(Entity.class,"bb").set(p,new AABB(0,0,0,.6,1.8,.6));
    field(LivingEntity.class,"equipment").set(p,new EntityEquipment());
    field(Entity.class,"interpolationHandler").set(p,Proxy.newProxyInstance(InterpolationHandler.class.getClassLoader(),new Class<?>[]{InterpolationHandler.class},(proxy,m,a)->false));
    var jumping=field(LivingEntity.class,"jumping");var delay=field(LivingEntity.class,"noJumpDelay");var cases=new JsonArray();
    for(double water:new double[]{0,.1,.4,Math.nextUp(.4),1})for(double lava:new double[]{0,.1,.4,Math.nextUp(.4),1})
      for(double threshold:new double[]{0,.4})for(boolean ground:new boolean[]{false,true})for(boolean jump:new boolean[]{false,true})
        for(boolean shift:new boolean[]{false,true})for(boolean flying:new boolean[]{false,true})for(double y:new double[]{-.04,-.003,0,.003,.04}){
          p.water=water;p.lava=lava;p.threshold=threshold;p.ground=ground;p.affected=!flying;p.action="none";jumping.setBoolean(p,jump);delay.setInt(p,0);
          var initial=new Vec3(.002,y,.002);p.setDeltaMovement(initial);
          // LocalPlayer.aiStep calls the native sink primitive before super.aiStep.
          if(water>0&&shift&&!flying)p.sink();
          try{p.aiStep();throw new AssertionError("Native travel boundary not reached");}catch(RuntimeException error){if(error!=STOP)throw error;}
          var c=new JsonObject();c.add("initial",vector(initial));c.addProperty("water",water);c.addProperty("lava",lava);c.addProperty("threshold",threshold);
          c.addProperty("on_ground",ground);c.addProperty("jump",jump);c.addProperty("shift",shift);c.addProperty("flying",flying);c.addProperty("ground_jump",p.action.equals("ground"));
          c.add("velocity",vector(p.getDeltaMovement()));cases.add(c);
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" native normalized fluid jump branches and sink primitives, stopped before travel.");
  }
}
