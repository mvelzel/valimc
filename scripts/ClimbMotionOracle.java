import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.*;

/** Actual private dry climb pipeline; zero relative input, supplied contact and collision response. */
public class ClimbMotionOracle {
  private static class Probe extends Player {
    boolean climbing,shift,scaffolding,clip;Vec3 requested,resolved;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public boolean onClimbable(){return climbing;}
    public boolean isSuppressingSlidingDownLadder(){return shift;}
    public BlockState getInBlockState(){return scaffolding?Blocks.SCAFFOLDING.defaultBlockState():Blocks.LADDER.defaultBlockState();}
    public boolean onGround(){return false;}
    protected float getFlyingSpeed(){return 0;}
    public float getYRot(){return 0;}
    public void move(MoverType type,Vec3 v){requested=v;resolved=clip?new Vec3(0,0,v.z):v;setDeltaMovement(resolved);}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var p=(Probe)u.allocateInstance(Probe.class);var jumpField=field(LivingEntity.class,"jumping");
    var step=LivingEntity.class.getDeclaredMethod("handleRelativeFrictionAndCalculateMovement",Vec3.class,float.class);step.setAccessible(true);var cases=new JsonArray();
    for(boolean climbing:new boolean[]{false,true})for(boolean shift:new boolean[]{false,true})for(boolean scaffold:new boolean[]{false,true})
      for(boolean horizontal:new boolean[]{false,true})for(boolean jump:new boolean[]{false,true})for(boolean clip:new boolean[]{false,true})
        for(double x:new double[]{-2,-.15000000596046448,.0001,.15000000596046448,2})for(double y:new double[]{-2,-.15000000596046448,-.01,0,.2,2}){
          p.climbing=climbing;p.shift=shift;p.scaffolding=scaffold;p.horizontalCollision=horizontal;p.clip=clip;jumpField.setBoolean(p,jump);p.fallDistance=5;
          var initial=new Vec3(x,y,-.3);p.setDeltaMovement(initial);var result=(Vec3)step.invoke(p,Vec3.ZERO,.6f);
          var c=new JsonObject();c.add("initial",vector(initial));c.addProperty("climbing",climbing);c.addProperty("shift",shift);c.addProperty("scaffolding",scaffold);
          c.addProperty("horizontal_collision",horizontal);c.addProperty("jump",jump);c.add("requested",vector(p.requested));c.add("resolved",vector(p.resolved));
          c.add("velocity",vector(result));c.addProperty("fall_distance",p.fallDistance);cases.add(c);
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native dry player climb clamps, supplied collisions and fall resets.");
  }
}
