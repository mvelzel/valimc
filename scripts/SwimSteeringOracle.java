import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;

/** Actual Player.travel pitch branch, stopped at fluid/air travel entry before acceleration/collision/drag. */
public class SwimSteeringOracle {
  private static final RuntimeException STOP=new RuntimeException("Native travel entry reached");
  private static class ProbeLevel extends ServerLevel {
    boolean above;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public FluidState getFluidState(BlockPos p){return above?Fluids.WATER.defaultFluidState():Fluids.EMPTY.defaultFluidState();}
  }
  private static class ProbePlayer extends Player {
    ProbeLevel world;Abilities abilities;boolean swimming,passenger;float pitch;
    private ProbePlayer(){super(null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return GameType.CREATIVE;}
    public Abilities getAbilities(){return abilities;}
    public boolean isPassenger(){return passenger;}
    public boolean isSwimming(){return swimming&&!abilities.flying;}
    public float getXRot(){return pitch;}
    public float getYRot(){return 0;}
    public boolean isFallFlying(){return false;}
    public boolean isInLiquid(){return true;}
    // Supply routing so every case stops at the same pre-travel boundary, including flight.
    @Override protected boolean shouldTravelInFluid(FluidState state){return true;}
    @Override protected void travelInFluid(Vec3 input){throw STOP;}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonObject run(ProbePlayer p,Vec3 initial){
    p.setDeltaMovement(initial);double look=p.getLookAngle().y;
    try{p.travel(Vec3.ZERO);throw new AssertionError("Native travel boundary missed");}catch(RuntimeException e){if(e!=STOP)throw e;}
    var c=new JsonObject();c.add("initial",vector(initial));c.addProperty("pitch",(double)p.pitch);c.addProperty("look_y",look);
    c.addProperty("swimming",p.isSwimming());c.addProperty("passenger",p.passenger);c.addProperty("jump",p.isJumping());c.addProperty("above_fluid",p.world.above);
    c.addProperty("flying",p.abilities.flying);c.add("velocity",vector(p.getDeltaMovement()));return c;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var p=(ProbePlayer)u.allocateInstance(ProbePlayer.class);p.world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);p.abilities=new Abilities();field(Player.class,"abilities").set(p,p.abilities);
    field(Entity.class,"position").set(p,new Vec3(.5,64,.5));var jumping=field(LivingEntity.class,"jumping");var cases=new JsonArray();
    for(boolean swim:new boolean[]{false,true})for(boolean passenger:new boolean[]{false,true})for(boolean flying:new boolean[]{false,true})
      for(boolean jump:new boolean[]{false,true})for(boolean above:new boolean[]{false,true})
        for(float pitch:new float[]{-1000000,-180,-90,-45,-11.54f,-.001f,0,.001f,11.53f,11.54f,11.55f,45,90,180,1000000})
          for(double y:new double[]{-10,-1,-.2,0,.2,1,10}){
            p.swimming=swim;p.passenger=passenger;p.abilities.flying=flying;p.world.above=above;p.pitch=pitch;jumping.setBoolean(p,jump);
            cases.add(run(p,new Vec3(.1,y,-.2)));
          }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native swim-pitch travel entries and camera look vectors.");
  }
}
