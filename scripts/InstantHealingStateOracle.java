import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.network.syncher.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.alchemy.PotionContents;
import net.minecraft.world.level.GameType;

/** Original complete instant-healing callback observation, including native data notifications. */
public class InstantHealingStateOracle {
  static class Body extends Player {
    ServerLevel world; int deaths;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public boolean isInvertedHealAndHarm(){return false;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(!attribute.equals(Attributes.MAX_HEALTH))throw new AssertionError(attribute);
      return 20;
    }
    public void die(DamageSource source){deaths++;}
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");unsafeField.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)unsafeField.get(null);var body=(Body)unsafe.allocateInstance(Body.class);
    body.world=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    var accessorField=LivingEntity.class.getDeclaredField("DATA_HEALTH_ID");accessorField.setAccessible(true);
    @SuppressWarnings("unchecked")var health=(EntityDataAccessor<Float>)accessorField.get(null);
    var items=new SynchedEntityData.DataItem<?>[health.id()+1];items[health.id()]=new SynchedEntityData.DataItem<>(health,20f);
    var constructor=SynchedEntityData.class.getDeclaredConstructor(SyncedDataHolder.class,SynchedEntityData.DataItem[].class);constructor.setAccessible(true);
    var entityData=Entity.class.getDeclaredField("entityData");entityData.setAccessible(true);entityData.set(body,constructor.newInstance(body,items));
    var dead=LivingEntity.class.getDeclaredField("dead");dead.setAccessible(true);
    var rows=new JsonArray();
    for(int amp=0;amp<256;amp++)for(float before:new float[]{0,5,20}){
      dead.setBoolean(body,false);body.deathTime=0;body.deaths=0;body.setHealth(before);
      var contents=new PotionContents(Optional.empty(),Optional.empty(),List.of(new MobEffectInstance(MobEffects.INSTANT_HEALTH,1,amp)),Optional.empty());
      contents.applyToLivingEntity(body,1f);
      var row=new JsonObject();row.addProperty("amplifier",amp);row.addProperty("before",(double)before);row.addProperty("after",(double)body.getHealth());
      row.addProperty("dead_or_dying",body.isDeadOrDying());row.addProperty("dead_flag",dead.getBoolean(body));
      row.addProperty("die_calls",body.deaths);row.addProperty("death_ticks",body.deathTime);rows.add(row);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual instant-healing callbacks with native health notifications/dead predicates and observed die calls; subsequent world ticks/respawn/statistics excluded.");
  }
}
