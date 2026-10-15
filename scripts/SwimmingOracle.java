import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.tags.FluidTags;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.material.*;
import net.minecraft.world.level.storage.*;

/** Actual Entity shared swimming flag transition, with supplied water/eye/feet/passenger observations. */
public class SwimmingOracle {
  private static class ProbeLevel extends ServerLevel {
    FluidState feet;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getNextEntityId(){return 1;}
    public FluidState getFluidState(BlockPos p){return feet;}
  }
  private static class ProbeEntity extends Entity {
    boolean passenger;
    ProbeEntity(Level world){super(EntityTypes.ITEM,world);}
    protected void defineSynchedData(SynchedEntityData.Builder b){}
    protected void readAdditionalSaveData(ValueInput in){}
    protected void addAdditionalSaveData(ValueOutput out){}
    public boolean hurtServer(ServerLevel w,DamageSource d,float amount){return false;}
    public boolean isPassenger(){return passenger;}
  }
  private static class ProbePlayer extends Player {
    ProbeLevel world; boolean passenger,spectator;
    private ProbePlayer(){super(null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return spectator?GameType.SPECTATOR:GameType.CREATIVE;}
    public boolean isPassenger(){return passenger;}
    void sprintFlag(boolean value){setSharedFlag(3,value);}
    void initializeFlags()throws Exception{
      // Supply ordinary Entity shared-flag storage; Player's unrelated data slots are not read.
      var data=Entity.class.getDeclaredField("entityData");data.setAccessible(true);data.set(this,new ProbeEntity(world).getEntityData());
    }
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var fluid:List.of(Fluids.WATER,Fluids.FLOWING_WATER))bind.invoke(fluid.builtInRegistryHolder(),List.of(FluidTags.WATER));
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);var cases=new JsonArray();
    var wet=Entity.class.getDeclaredField("wasTouchingWater");wet.setAccessible(true);var eyes=Entity.class.getDeclaredField("wasEyeInWater");eyes.setAccessible(true);
    for(boolean previous:new boolean[]{false,true})for(boolean sprint:new boolean[]{false,true})for(boolean water:new boolean[]{false,true})
      for(boolean eye:new boolean[]{false,true})for(boolean feet:new boolean[]{false,true})for(boolean passenger:new boolean[]{false,true}){
        var e=new ProbeEntity(world);e.setSwimming(previous);e.setSprinting(sprint);e.passenger=passenger;
        wet.setBoolean(e,water);eyes.setBoolean(e,eye);world.feet=feet?Fluids.WATER.defaultFluidState():Fluids.EMPTY.defaultFluidState();
        boolean underwater=e.isUnderWater();e.updateSwimming();var c=new JsonObject();c.addProperty("previous",previous);c.addProperty("sprint",sprint);
        c.addProperty("water",water);c.addProperty("underwater",underwater);c.addProperty("feet_water",feet);c.addProperty("passenger",passenger);c.addProperty("swimming",e.isSwimming());cases.add(c);
      }
    var flags=Entity.class.getDeclaredField("blockPosition");flags.setAccessible(true);
    var abilities=Player.class.getDeclaredField("abilities");abilities.setAccessible(true);
    for(boolean previous:new boolean[]{false,true})for(boolean sprint:new boolean[]{false,true})for(boolean water:new boolean[]{false,true})
      for(boolean eye:new boolean[]{false,true})for(boolean feet:new boolean[]{false,true})for(boolean passenger:new boolean[]{false,true})
        for(boolean flying:new boolean[]{false,true})for(boolean spectator:new boolean[]{false,true}){
          var p=(ProbePlayer)u.allocateInstance(ProbePlayer.class);p.world=world;p.passenger=passenger;p.spectator=spectator;p.initializeFlags();flags.set(p,BlockPos.ZERO);
          var a=new Abilities();a.flying=flying;abilities.set(p,a);p.setSwimming(previous);p.sprintFlag(sprint);
          wet.setBoolean(p,water);eyes.setBoolean(p,eye);world.feet=feet?Fluids.WATER.defaultFluidState():Fluids.EMPTY.defaultFluidState();
          boolean underwater=p.isUnderWater();p.updateSwimming();var c=new JsonObject();c.addProperty("previous",previous);c.addProperty("sprint",sprint);
          c.addProperty("water",water);c.addProperty("underwater",underwater);c.addProperty("feet_water",feet);c.addProperty("passenger",passenger);
          c.addProperty("flying",flying);c.addProperty("spectator",spectator);c.addProperty("swimming",p.isSwimming());cases.add(c);
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native entity/player swimming transitions including flight/spectator overrides.");
  }
}
