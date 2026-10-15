import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.storage.*;

/** Original fixture invokes native freeze effects and real synchronized accessors. */
public class PlayerFreezeOracle {
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getNextEntityId(){return 1;}
  }
  private static class ProbeEntity extends Entity {
    boolean allowed;
    ProbeEntity(Level level){super(EntityTypes.ITEM,level);}
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){return false;}
    public boolean canFreeze(){return allowed;}
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)f.get(null);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);var cases=new JsonArray();
    for(int initial=0;initial<=140;initial++)for(boolean allowed:new boolean[]{false,true}){
      var entity=new ProbeEntity(world);entity.allowed=allowed;entity.setTicksFrozen(initial);
      InsideBlockEffectType.FREEZE.effect().accept(entity);
      var c=new JsonObject();c.addProperty("initial",initial);c.addProperty("allowed",allowed);
      c.addProperty("frozen",entity.getTicksFrozen());c.addProperty("inside",entity.isInPowderSnow);
      c.addProperty("percent",(double)entity.getPercentFrozen());c.addProperty("fully",entity.isFullyFrozen());
      cases.add(c);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native freeze effects and synchronized freeze accessors; controlled immunity.");
  }
}
