import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;

/** Native player block callbacks and actual Entity.move prefix, stopping before edge/collision work. */
public class StuckMotionOracle {
  private static final RuntimeException STOP=new RuntimeException("pre-collision boundary");
  private static class Probe extends Player {
    boolean weaving,powder; Vec3 requested;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public boolean hasEffect(Holder<MobEffect> type){return type==MobEffects.WEAVING&&weaving;}
    public BlockState getInBlockState(){return (powder?Blocks.POWDER_SNOW:Blocks.AIR).defaultBlockState();}
    protected Vec3 maybeBackOffFromEdge(Vec3 v,MoverType type){requested=v;throw STOP;}
    void multiplier(Vec3 v){stuckSpeedMultiplier=v;}
    Vec3 multiplier(){return stuckSpeedMultiplier;}
  }
  private static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var p=(Probe)u.allocateInstance(Probe.class);var abilities=new Abilities();var af=Player.class.getDeclaredField("abilities");af.setAccessible(true);af.set(p,abilities);var contacts=new JsonArray();var moves=new JsonArray();
    var tf=Entity.class.getDeclaredField("type");tf.setAccessible(true);tf.set(p,EntityTypes.PLAYER);
    var effects=(InsideBlockEffectApplier)Proxy.newProxyInstance(InsideBlockEffectApplier.class.getClassLoader(),new Class<?>[]{InsideBlockEffectApplier.class},(proxy,method,arguments)->null);
    for(var block:List.of(Blocks.AIR,Blocks.COBWEB,Blocks.SWEET_BERRY_BUSH,Blocks.POWDER_SNOW))for(var state:block.getStateDefinition().getPossibleStates())
      for(boolean weaving:new boolean[]{false,true})for(boolean powder:new boolean[]{false,true})for(boolean flying:new boolean[]{false,true}){
        p.weaving=weaving;p.powder=powder;abilities.flying=flying;p.fallDistance=5;p.multiplier(null);
        state.entityInside(null,BlockPos.ZERO,p,effects,false);
        var c=new JsonObject();c.addProperty("kind",block==Blocks.AIR?"none":block==Blocks.COBWEB?"cobweb":block==Blocks.SWEET_BERRY_BUSH?"berry_bush":"powder_snow");
        c.addProperty("state",Block.getId(state));
        c.addProperty("weaving",weaving);c.addProperty("powder_feet",powder);c.addProperty("flying",flying);c.add("multiplier",p.multiplier()==null?JsonNull.INSTANCE:vec(p.multiplier()));c.addProperty("fall_distance",p.fallDistance);contacts.add(c);
      }
    for(var multiplier:List.of(Vec3.ZERO,new Vec3(.00031622,0,0),new Vec3(.00031623,0,0),new Vec3(.25,.05000000074505806,.25),new Vec3(.8,.75,.8),new Vec3(.8999999761581421,1.5,.8999999761581421)))
      for(var requested:List.of(Vec3.ZERO,new Vec3(.4,-2,.1),new Vec3(-2,.42,1),new Vec3(64,-64,64)))
        for(var velocity:List.of(Vec3.ZERO,new Vec3(.2,-.3,.4)))for(var type:List.of(MoverType.SELF,MoverType.PLAYER)){
          p.multiplier(multiplier);p.setDeltaMovement(velocity);
          try{p.move(type,requested);throw new AssertionError("Missing boundary");}catch(RuntimeException e){if(e!=STOP)throw e;}
          var c=new JsonObject();c.add("multiplier",vec(multiplier));c.add("initial",vec(velocity));c.add("requested",vec(requested));c.add("scaled",vec(p.requested));c.add("velocity",vec(p.getDeltaMovement()));c.add("remaining",vec(p.multiplier()));moves.add(c);
        }
    var out=new JsonObject();out.add("contacts",contacts);out.add("moves",moves);Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+contacts.size()+" native player slowing callbacks and "+moves.size()+" actual non-piston move prefixes, before edge/collision.");
  }
}
