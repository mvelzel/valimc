import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.syncher.*;
import net.minecraft.resources.Identifier;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.food.FoodData;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.gameevent.GameEvent;

/** Actual Player damage/absorption/food path; controlled defense/stat/combat endpoints, no outer hurt/death. */
public class AbsorptionDamageOracle {
  static class Recorder extends CombatTracker {
    float damage;
    Recorder(LivingEntity body){super(body);}
    public void recordDamage(DamageSource source,float amount){damage=amount;}
  }
  static class Body extends Player {
    ServerLevel world; Recorder recorder; float armorFactor,magicFactor,armorInput,magicInput;
    int events; Map<String,Integer> stats;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public boolean isInvulnerableTo(ServerLevel world,DamageSource source){return false;}
    protected float getDamageAfterArmorAbsorb(DamageSource source,float amount){armorInput=amount;return amount*armorFactor;}
    protected float getDamageAfterMagicAbsorb(DamageSource source,float amount){magicInput=amount;return amount*magicFactor;}
    public CombatTracker getCombatTracker(){return recorder;}
    public void awardStat(Identifier stat,int amount){stats.put(stat.toString(),amount);}
    public void gameEvent(Holder<GameEvent> event){events++;}
    public void onSyncedDataUpdated(EntityDataAccessor<?> accessor){}
    void damage(DamageSource source,float amount){actuallyHurt(world,source,amount);}
  }
  static Field field(Class<?> owner,String name)throws Exception {
    var result=owner.getDeclaredField(name);result.setAccessible(true);return result;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    field(LivingEntity.class,"attributes").set(body,new AttributeMap(Player.createAttributes().build()));
    body.getAttribute(Attributes.MAX_ABSORPTION).setBaseValue(2048);
    field(Player.class,"abilities").set(body,new Abilities());
    @SuppressWarnings("unchecked") var pool=(EntityDataAccessor<Float>)field(Player.class,"DATA_PLAYER_ABSORPTION_ID").get(null);
    @SuppressWarnings("unchecked") var health=(EntityDataAccessor<Float>)field(LivingEntity.class,"DATA_HEALTH_ID").get(null);
    var items=new SynchedEntityData.DataItem<?>[Math.max(pool.id(),health.id())+1];
    items[pool.id()]=new SynchedEntityData.DataItem<>(pool,0f);items[health.id()]=new SynchedEntityData.DataItem<>(health,20f);
    var constructor=SynchedEntityData.class.getDeclaredConstructor(SyncedDataHolder.class,SynchedEntityData.DataItem[].class);constructor.setAccessible(true);
    field(Entity.class,"entityData").set(body,constructor.newInstance(body,items));body.recorder=new Recorder(body);
    var damage=VanillaRegistries.createWorldLookup().lookupOrThrow(Registries.DAMAGE_TYPE);var rows=new JsonArray();
    for(var key:damage.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())
      for(float hp:new float[]{1,18,20})for(float before:new float[]{0,.1f,.5f,4,8,1024})
        for(float amount:new float[]{0,Float.MIN_VALUE,.1f,.5f,1,6,20,100,16777216,33554432,Float.MAX_VALUE})
          for(float[] factors:new float[][]{{1,1},{.5f,1},{1,.8f},{.5f,.8f}}){
            body.setHealth(hp);body.setAbsorptionAmount(before);body.stats=new TreeMap<>();body.events=0;body.recorder.damage=0;body.armorFactor=factors[0];body.magicFactor=factors[1];
            var food=new FoodData();field(Player.class,"foodData").set(body,food);var source=new DamageSource(damage.getOrThrow(key));body.damage(source,amount);
            var row=new JsonObject();row.addProperty("source",key.identifier().getPath());row.addProperty("health",(double)hp);row.addProperty("pool",(double)before);row.addProperty("amount",(double)amount);
            row.addProperty("armor_factor",(double)factors[0]);row.addProperty("magic_factor",(double)factors[1]);row.addProperty("armor_input",(double)body.armorInput);row.addProperty("magic_input",(double)body.magicInput);
            row.addProperty("after_pool",(double)body.getAbsorptionAmount());row.addProperty("after_health",(double)body.getHealth());row.addProperty("recorded_damage",(double)body.recorder.damage);
            row.addProperty("food_cost",(double)source.getFoodExhaustion());row.addProperty("exhaustion",(double)field(FoodData.class,"exhaustionLevel").getFloat(food));row.addProperty("events",body.events);row.add("stats",new Gson().toJsonTree(body.stats));rows.add(row);
          }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual Player absorption/health/food damage contexts, all native source kinds, fractional/large rounding and controlled defense order; armor rules/outer hurt/death/stats storage/live owner excluded.");
  }
}
