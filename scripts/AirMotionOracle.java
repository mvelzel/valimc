import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;

/** Native travelInAir with zero input and controlled collision/effect observations. */
public class AirMotionOracle {
  private static class ProbeLevel extends ServerLevel {
    BlockState floor;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos position){return floor;}
  }
  private static class ProbePlayer extends Player {
    ProbeLevel world; boolean ground,discard,omni,slow; double friction,drag,gravity;
    MobEffectInstance levitation;
    Vec3 clipped;
    private ProbePlayer(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public ServerLevel level(){return world;}
    public BlockPos getBlockPosBelowThatAffectsMyMovement(){return BlockPos.ZERO;}
    public boolean onGround(){return ground;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(attribute==Attributes.FRICTION_MODIFIER)return friction;
      if(attribute==Attributes.AIR_DRAG_MODIFIER)return drag;
      if(attribute==Attributes.GRAVITY)return gravity;
      throw new AssertionError("Unexpected attribute "+attribute);
    }
    public float getSpeed(){return 0f;}
    protected float getFlyingSpeed(){return 0f;}
    public boolean onClimbable(){return false;}
    public void move(MoverType type,Vec3 requested){if(clipped!=null)setDeltaMovement(clipped);}
    public boolean isNoGravity(){return false;}
    public boolean hasEffect(Holder<MobEffect> type){return type==MobEffects.SLOW_FALLING&&slow;}
    public MobEffectInstance getEffect(Holder<MobEffect> type){return levitation;}
    public boolean shouldDiscardFriction(){return discard;}
    protected boolean omnidirectionalAirMover(){return omni;}
  }
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Throwable{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    var player=(ProbePlayer)unsafe.allocateInstance(ProbePlayer.class);player.world=world;
    var travel=LivingEntity.class.getDeclaredMethod("travelInAir",Vec3.class);travel.setAccessible(true);
    var cases=new JsonArray();
    for(var movement:List.of(Vec3.ZERO,new Vec3(.2,-.0784,-.3),new Vec3(-2,.42,1),new Vec3(3,-3,4)))
      for(var floor:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK))
        for(boolean ground:new boolean[]{false,true})for(double friction:new double[]{0,1,2})
          for(double drag:new double[]{.25,1,2048})for(double gravity:new double[]{-.08,0,.08})
            for(int amplifier:new int[]{-1,0,1,3,255})for(boolean slow:new boolean[]{false,true})for(int flags=0;flags<4;flags++){
              world.floor=floor.defaultBlockState();player.ground=ground;player.friction=friction;
              player.drag=drag;player.gravity=gravity;player.slow=slow;player.discard=(flags&1)!=0;player.omni=(flags&2)!=0;
              player.levitation=amplifier<0?null:new MobEffectInstance(MobEffects.LEVITATION,100,amplifier);
              player.setDeltaMovement(movement);
              try{travel.invoke(player,Vec3.ZERO);}catch(InvocationTargetException error){throw error.getCause();}
              var c=new JsonObject();c.add("movement",vector(movement));c.addProperty("ground",ground);
              c.addProperty("friction",(double)floor.getFriction());c.addProperty("friction_modifier",friction);
              c.addProperty("air_drag_modifier",drag);c.addProperty("gravity",gravity);
              c.addProperty("slow_falling",slow);
              c.addProperty("levitation",amplifier);c.addProperty("discard_friction",player.discard);
              c.addProperty("omnidirectional",player.omni);c.add("velocity",vector(player.getDeltaMovement()));cases.add(c);
            }
    // A bounce/ceiling can reverse the sign before air gravity is selected.
    for(double initialY:new double[]{-1,.3})for(double resolvedY:new double[]{-.2,0,.2}){
      var initial=new Vec3(.2,initialY,-.3);var resolved=new Vec3(.2,resolvedY,-.3);
      world.floor=Blocks.STONE.defaultBlockState();player.ground=false;player.friction=1;
      player.drag=1;player.gravity=.08;player.slow=true;player.discard=false;player.omni=false;
      player.levitation=null;player.clipped=resolved;player.setDeltaMovement(initial);
      try{travel.invoke(player,Vec3.ZERO);}catch(InvocationTargetException error){throw error.getCause();}
      var c=new JsonObject();c.add("initial",vector(initial));c.add("movement",vector(resolved));
      c.addProperty("ground",false);c.addProperty("friction",(double)Blocks.STONE.getFriction());
      c.addProperty("friction_modifier",1);c.addProperty("air_drag_modifier",1);c.addProperty("gravity",.08);
      c.addProperty("slow_falling",true);c.addProperty("levitation",-1);c.addProperty("discard_friction",false);
      c.addProperty("omnidirectional",false);c.add("velocity",vector(player.getDeltaMovement()));cases.add(c);
    }
    player.clipped=null;
    var traces=new JsonArray();
    for(var initial:List.of(new Vec3(.2,.42,-.3),new Vec3(2,-.2,1))){
      player.setDeltaMovement(initial);var steps=new JsonArray();
      for(int i=0;i<200;i++){
        player.ground=i<3;world.floor=Blocks.ICE.defaultBlockState();player.friction=1;player.drag=1;
        player.gravity=.08;player.slow=i>=20&&i<80;player.discard=false;player.omni=false;
        player.levitation=i>=80&&i<100?new MobEffectInstance(MobEffects.LEVITATION,100,1):null;
        try{travel.invoke(player,Vec3.ZERO);}catch(InvocationTargetException error){throw error.getCause();}
        var step=new JsonObject();step.addProperty("ground",player.ground);step.addProperty("gravity",player.gravity);
        step.addProperty("slow_falling",player.slow);
        step.addProperty("levitation",player.levitation==null?-1:1);step.add("velocity",vector(player.getDeltaMovement()));steps.add(step);
      }
      var trace=new JsonObject();trace.add("initial",vector(initial));trace.addProperty("friction",(double)Blocks.ICE.getFriction());
      trace.add("steps",steps);traces.add(trace);
    }
    var output=new JsonObject();output.add("cases",cases);output.add("traces",traces);
    Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: "+cases.size()+" native air updates and "+traces.size()+" 200-step velocity traces; controlled collision/effects.");
  }
}
