import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.util.Mth;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.Shapes;

/** Invokes actual native velocity restitution; collision flags and tags are controlled. */
public class CollisionResponseOracle {
  private static Method collide,restitute;
  private static class ProbeLevel extends ServerLevel {
    BlockState floor;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos position){return floor;}
  }
  private static class ProbePlayer extends Player {
    boolean suppress,rejected,ground; double bounce,gravity; float drag; int events; ProbeLevel world;
    AABB body; List<net.minecraft.world.phys.shapes.VoxelShape> shapes; Vec3 moved;
    private ProbePlayer(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public boolean isSuppressingBounce(){return suppress;}
    protected double getEntityBounciness(){return bounce;}
    protected double getEffectiveGravity(){return gravity;}
    protected float getAirDrag(){return drag;}
    public BlockPos getBlockPosBelowThatAffectsMyMovement(){return BlockPos.ZERO;}
    public void gameEvent(Holder<GameEvent> event){events++;}
    public void setDeltaMovement(Vec3 value){if(!value.isFinite())rejected=true;super.setDeltaMovement(value);}
    public ServerLevel level(){return world;}
    public boolean onGround(){return ground;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(attribute==Attributes.FRICTION_MODIFIER||attribute==Attributes.AIR_DRAG_MODIFIER)return 1;
      throw new AssertionError("Unexpected attribute "+attribute);
    }
    public float getSpeed(){return 0f;}
    protected float getFlyingSpeed(){return 0f;}
    public boolean onClimbable(){return false;}
    public void move(MoverType type,Vec3 requested){
      try{
        moved=(Vec3)collide.invoke(null,requested,body,shapes);
        boolean x=!Mth.equal(moved.x,requested.x),z=!Mth.equal(moved.z,requested.z);
        verticalCollision=moved.y!=requested.y;verticalCollisionBelow=verticalCollision&&requested.y<0;
        ground=verticalCollisionBelow;horizontalCollision=x||z;
        restitute.invoke(this,world.floor,x,z,moved);body=body.move(moved);
      }catch(ReflectiveOperationException error){throw new RuntimeException(error);}
    }
    public MobEffectInstance getEffect(Holder<MobEffect> type){return null;}
    public boolean shouldDiscardFriction(){return false;}
    protected boolean omnidirectionalAirMover(){return false;}
  }
  private static JsonArray vector(Vec3 v){
    var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;
  }
  private static JsonArray bits(Vec3 v){
    var a=new JsonArray();
    for(double n:new double[]{v.x,v.y,v.z})a.add(Long.toUnsignedString(Double.doubleToRawLongBits(n),16));
    return a;
  }
  private static JsonArray box(AABB b){
    var a=new JsonArray();for(double n:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})a.add(n);return a;
  }
  public static void main(String[] args)throws Throwable{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)f.get(null);
    var player=(ProbePlayer)unsafe.allocateInstance(ProbePlayer.class);
    player.world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    var method=Entity.class.getDeclaredMethod("restituteMovementAfterCollisions",BlockState.class,boolean.class,boolean.class,Vec3.class);
    method.setAccessible(true);restitute=method;
    var tags=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);tags.setAccessible(true);
    var cases=new JsonArray();int rejected=0;
    for(var block:List.of(Blocks.STONE,Blocks.SLIME_BLOCK))for(boolean tagged:new boolean[]{false,true}){
      tags.invoke(block.builtInRegistryHolder(),tagged?List.of(BlockTags.SUPPRESSES_BOUNCE):List.of());
      for(double y:new double[]{-2,-.08,-.0784,-.0001,-0.0,0.0,.42})for(int flags=0;flags<32;flags++){
        boolean x=(flags&1)!=0,z=(flags&2)!=0,vertical=(flags&4)!=0,below=(flags&8)!=0;
        if(below&&!vertical)continue;
        for(double bounce:new double[]{0,.25,1})for(double gravity:new double[]{-.08,0,.08})
          for(float drag:new float[]{0,.98f,1})for(double fraction:new double[]{0,.25,1}){
            if(!vertical&&fraction!=0)continue;
            var movement=new Vec3(.2,y,-.3);double movedY=y*fraction;
            player.suppress=(flags&16)!=0;player.bounce=bounce;player.gravity=gravity;player.drag=drag;
            player.verticalCollision=vertical;player.verticalCollisionBelow=below;
            player.syncPosition=false;player.events=0;player.rejected=false;player.setDeltaMovement(movement);
            try{method.invoke(player,block.defaultBlockState(),x,z,new Vec3(0,movedY,0));}
            catch(InvocationTargetException error){throw error.getCause();}
            var output=player.getDeltaMovement();
            if(!output.isFinite())throw new AssertionError("Native retained nonfinite velocity");
            if(player.rejected)rejected++;
            if(player.syncPosition!=(player.events==1))throw new AssertionError("Bounce event/sync differs");
            var c=new JsonObject();c.add("movement",vector(movement));c.addProperty("moved_y",movedY);
            c.addProperty("x_collision",x);c.addProperty("z_collision",z);
            c.addProperty("vertical_collision",vertical);c.addProperty("below",below);
            c.addProperty("suppress_bounce",player.suppress);c.addProperty("block_suppresses_bounce",tagged);
            c.addProperty("entity_bounciness",bounce);c.addProperty("block_bounciness",(double)block.getBounceRestitution());
            c.addProperty("gravity",gravity);c.addProperty("air_drag",(double)drag);
            c.add("velocity_bits",bits(output));c.addProperty("bounced",player.syncPosition);
            c.addProperty("nonfinite_candidate_rejected",player.rejected);cases.add(c);
          }
      }
    }
    collide=Entity.class.getDeclaredMethod("collideWithShapes",Vec3.class,AABB.class,List.class);collide.setAccessible(true);
    var travel=LivingEntity.class.getDeclaredMethod("travelInAir",Vec3.class);travel.setAccessible(true);
    var floorBox=new AABB(-10,-1,-10,10,0,10);var ceilingBox=new AABB(-10,4,-10,10,5,10);
    var shapes=List.of(Shapes.create(floorBox),Shapes.create(ceilingBox));var traces=new JsonArray();
    for(var block:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK)){
      tags.invoke(block.builtInRegistryHolder(),List.of());
      var body=new AABB(.2,2,.2,.8,3.8,.8);var movement=new Vec3(.2,.42,-.1);
      player.world.floor=block.defaultBlockState();player.bounce=0;player.gravity=.08;player.drag=.98f;player.suppress=false;
      player.body=body;player.shapes=shapes;player.ground=false;player.horizontalCollision=false;
      player.setDeltaMovement(movement);var steps=new JsonArray();var trace=new JsonObject();
      trace.add("box",box(body));trace.add("initial",vector(movement));trace.addProperty("friction",(double)block.getFriction());
      trace.addProperty("block_bounciness",(double)block.getBounceRestitution());
      var obstacles=new JsonArray();obstacles.add(box(floorBox));obstacles.add(box(ceilingBox));trace.add("obstacles",obstacles);
      for(int i=0;i<200;i++){
        player.syncPosition=false;player.events=0;travel.invoke(player,Vec3.ZERO);
        var step=new JsonObject();step.add("moved_bits",bits(player.moved));step.add("velocity_bits",bits(player.getDeltaMovement()));
        step.add("box",box(player.body));step.addProperty("bounced",player.syncPosition);steps.add(step);
      }
      trace.add("steps",steps);traces.add(trace);
    }
    var result=new JsonObject();result.add("cases",cases);result.addProperty("nonfinite_candidates_rejected",rejected);result.add("traces",traces);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native collision responses; "+rejected+" nonfinite candidates ignored; "+traces.size()+" native 200-step collision/air traces with floor and ceiling.");
  }
}
