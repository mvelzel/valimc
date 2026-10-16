import com.google.gson.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.network.syncher.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Original native heal/setHealth probe with real synchronized health data; no death callbacks. */
public class HealingOracle {
  static class Body extends Player {
    float maximum;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(!attribute.equals(Attributes.MAX_HEALTH))throw new AssertionError("Unexpected healing attribute");
      return maximum;
    }
    public void onSyncedDataUpdated(EntityDataAccessor<?> accessor){}
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var body=(Body)((sun.misc.Unsafe)field.get(null)).allocateInstance(Body.class);
    var healthField=LivingEntity.class.getDeclaredField("DATA_HEALTH_ID");healthField.setAccessible(true);
    @SuppressWarnings("unchecked") var healthAccessor=(EntityDataAccessor<Float>)healthField.get(null);
    var items=new SynchedEntityData.DataItem<?>[healthAccessor.id()+1];
    items[healthAccessor.id()]=new SynchedEntityData.DataItem<>(healthAccessor,20f);
    var constructor=SynchedEntityData.class.getDeclaredConstructor(SyncedDataHolder.class,SynchedEntityData.DataItem[].class);
    constructor.setAccessible(true);
    var data=Entity.class.getDeclaredField("entityData");data.setAccessible(true);data.set(body,constructor.newInstance(body,items));
    var rows=new JsonArray();
    for(float maximum:new float[]{1,20,1024})for(float health:new float[]{0,.5f,1,maximum-.5f,maximum})
      for(float amount:new float[]{-Float.MAX_VALUE,-2147483648f,-1,-Float.MIN_VALUE,-0f,0f,Float.MIN_VALUE,.1f,1,4,8,128,Float.MAX_VALUE}){
        body.maximum=maximum;body.setHealth(health);body.heal(amount);
        var row=new JsonObject();row.addProperty("maximum",(double)maximum);row.addProperty("health",(double)health);
        row.addProperty("amount",(double)amount);row.addProperty("next",(double)body.getHealth());rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native heal/setHealth transitions with real synchronized health, signed amounts, bounds and dead non-revival; owner death/consumption excluded.");
  }
}
