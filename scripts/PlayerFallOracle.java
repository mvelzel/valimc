import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.level.gameevent.GameEvent;
import net.minecraft.world.level.storage.*;
import net.minecraft.world.phys.Vec3;

/** Original fixtures call native accumulation/reset, with landing effects observed. */
public class PlayerFallOracle {
  private static class ProbeLevel extends ServerLevel {
    DamageSources sources;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public void gameEvent(Holder<GameEvent> event,Vec3 position,GameEvent.Context context){}
    public DamageSources damageSources(){return sources;}
  }
  private static class ProbeEntity extends Entity {
    boolean water; ProbeLevel world; Double landed;
    private ProbeEntity(){super(null,null);}
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){return false;}
    public boolean causeFallDamage(double distance,float multiplier,DamageSource source){landed=distance;return false;}
    public boolean isInWater(){return water;}
    public Level level(){return world;}
    void check(double dy,boolean ground,BlockState state){checkFallDamage(dy,ground,state,BlockPos.ZERO);}
  }
  private static Field field(Class<?> type,String name)throws Exception{
    var f=type.getDeclaredField(name);f.setAccessible(true);return f;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    world.sources=(DamageSources)unsafe.allocateInstance(DamageSources.class);
    var position=field(Entity.class,"position");var support=field(Entity.class,"mainSupportingBlockPos");
    var block=Blocks.STONE.defaultBlockState();
    var cases=new JsonArray();
    for(double initial:new double[]{0,.1,2.5,Math.nextUp(2.5),1000})
      for(double dy:new double[]{-64,-2.50000001,-.0784,-.0000000001,-0.0,0,.1,64})
        for(boolean water:new boolean[]{false,true})for(boolean ground:new boolean[]{false,true}){
          var entity=(ProbeEntity)unsafe.allocateInstance(ProbeEntity.class);
          entity.world=world;entity.water=water;entity.fallDistance=initial;
          position.set(entity,Vec3.ZERO);support.set(entity,Optional.empty());
          entity.check(dy,ground,block);
          var c=new JsonObject();c.addProperty("initial",initial);c.addProperty("dy",dy);
          c.addProperty("water",water);c.addProperty("ground",ground);
          c.addProperty("distance",entity.fallDistance);
          if(entity.landed==null)c.add("landed",JsonNull.INSTANCE);else c.addProperty("landed",entity.landed);
          cases.add(c);
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native fall accumulation/landing/reset cases; controlled water and landing effects.");
  }
}
