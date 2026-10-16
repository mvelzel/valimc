import com.google.gson.*;
import com.google.common.collect.ImmutableList;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.network.syncher.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Original observations of real absorption setters, effect ownership hooks and instance ticks. */
public class AbsorptionOracle {
  static class Body extends Player {
    ServerLevel world;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public boolean canBeAffected(MobEffectInstance effect){return true;}
    public void sendEffectToPassengers(MobEffectInstance effect){}
    public void onSyncedDataUpdated(EntityDataAccessor<?> accessor){}
    void refreshMaximum(){onAttributeUpdated(Attributes.MAX_ABSORPTION);}
  }
  static Field field(Class<?> owner,String name)throws Exception {
    var result=owner.getDeclaredField(name);result.setAccessible(true);return result;
  }
  static void reset(Body body,double base)throws Exception {
    field(LivingEntity.class,"attributes").set(body,new AttributeMap(Player.createAttributes().build()));
    body.getAttribute(Attributes.MAX_ABSORPTION).setBaseValue(base);
    field(LivingEntity.class,"activeEffects").set(body,new HashMap<>());
    body.setAbsorptionAmount(0);
  }
  static JsonObject state(Body body)throws Exception {
    var result=new JsonObject();result.addProperty("maximum",(double)body.getMaxAbsorption());
    result.addProperty("pool",(double)body.getAbsorptionAmount());
    var effect=body.getEffect(MobEffects.ABSORPTION);var rungs=new JsonArray();
    while(effect!=null){var rung=new JsonArray();rung.add(effect.getDuration());rung.add(effect.getAmplifier());rungs.add(rung);effect=(MobEffectInstance)field(MobEffectInstance.class,"hiddenEffect").get(effect);}
    result.add("rungs",rungs);return result;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    field(Entity.class,"passengers").set(body,ImmutableList.of());
    @SuppressWarnings("unchecked") var pool=(EntityDataAccessor<Float>)field(Player.class,"DATA_PLAYER_ABSORPTION_ID").get(null);
    @SuppressWarnings("unchecked") var health=(EntityDataAccessor<Float>)field(LivingEntity.class,"DATA_HEALTH_ID").get(null);
    var items=new SynchedEntityData.DataItem<?>[Math.max(pool.id(),health.id())+1];
    items[pool.id()]=new SynchedEntityData.DataItem<>(pool,0f);items[health.id()]=new SynchedEntityData.DataItem<>(health,20f);
    var constructor=SynchedEntityData.class.getDeclaredConstructor(SyncedDataHolder.class,SynchedEntityData.DataItem[].class);constructor.setAccessible(true);
    field(Entity.class,"entityData").set(body,constructor.newInstance(body,items));
    var setters=new JsonArray();
    for(int amp=0;amp<256;amp++)for(double base:new double[]{0,8,2048})for(float requested:new float[]{-1,0,.5f,3.99f,4,7.5f,1024,2048,Float.MAX_VALUE}){
      reset(body,base);MobEffects.ABSORPTION.value().addAttributeModifiers(body.getAttributes(),amp);
      body.setAbsorptionAmount(requested);var row=new JsonObject();row.addProperty("amplifier",amp);row.addProperty("base",base);row.addProperty("requested",(double)requested);row.add("set",state(body));
      var modifiers=new JsonArray();for(var modifier:body.getAttribute(Attributes.MAX_ABSORPTION).getModifiers()){var item=new JsonArray();item.add(modifier.id().toString());item.add(modifier.amount());item.add(modifier.operation().ordinal());modifiers.add(item);}row.add("modifiers",modifiers);
      MobEffects.ABSORPTION.value().onEffectStarted(body,amp);row.add("started",state(body));
      MobEffects.ABSORPTION.value().removeAttributeModifiers(body.getAttributes());body.refreshMaximum();row.add("removed",state(body));setters.add(row);
    }
    var additions=new JsonArray();
    for(int before:new int[]{0,1,31,255})for(int incoming:new int[]{0,1,31,255})for(float remaining:new float[]{0,1,3.5f,7.5f,1024})for(int ticks:new int[]{-1,1,200}){
      reset(body,0);body.addEffect(new MobEffectInstance(MobEffects.ABSORPTION,200,before));body.setAbsorptionAmount(remaining);
      var row=new JsonObject();row.add("before",state(body));row.addProperty("incoming_amplifier",incoming);row.addProperty("incoming_ticks",ticks);
      row.addProperty("changed",body.addEffect(new MobEffectInstance(MobEffects.ABSORPTION,ticks,incoming)));row.add("after",state(body));additions.add(row);
    }
    var ticking=new JsonArray();
    for(int amp:new int[]{0,1,31,255})for(int ticks:new int[]{-1,0,1,2,200})for(float remaining:new float[]{0,.5f,4,1024}){
      reset(body,0);body.addEffect(new MobEffectInstance(MobEffects.ABSORPTION,ticks,amp));body.setAbsorptionAmount(remaining);
      var effect=body.getEffect(MobEffects.ABSORPTION);var row=new JsonObject();row.add("before",state(body));int[] promoted={0};
      row.addProperty("remains",effect.tickServer(body.world,body,()->promoted[0]++));row.addProperty("next_ticks",effect.getDuration());row.addProperty("promotions",promoted[0]);row.add("after",state(body));ticking.add(row);
    }
    var promotions=new JsonArray();
    for(float remaining:new float[]{0,.5f,3.5f,7.5f}){
      reset(body,0);body.addEffect(new MobEffectInstance(MobEffects.ABSORPTION,10,0));body.addEffect(new MobEffectInstance(MobEffects.ABSORPTION,1,1));body.setAbsorptionAmount(remaining);
      var effect=body.getEffect(MobEffects.ABSORPTION);var row=new JsonObject();row.add("before",state(body));
      row.addProperty("remains",effect.tickServer(body.world,body,()->{MobEffects.ABSORPTION.value().removeAttributeModifiers(body.getAttributes());MobEffects.ABSORPTION.value().addAttributeModifiers(body.getAttributes(),effect.getAmplifier());body.refreshMaximum();}));row.add("after",state(body));promotions.add(row);
    }
    var removals=new JsonArray();
    for(int amp:new int[]{0,1,31,255})for(double base:new double[]{0,8,2048})for(float remaining:new float[]{0,.5f,4,1024}){
      reset(body,base);body.addEffect(new MobEffectInstance(MobEffects.ABSORPTION,200,amp));body.setAbsorptionAmount(remaining);
      var row=new JsonObject();row.addProperty("base",base);row.add("before",state(body));row.addProperty("removed",body.removeEffect(MobEffects.ABSORPTION));row.add("after",state(body));removals.add(row);
    }
    var out=new JsonObject();out.addProperty("player_metadata_id",pool.id());out.add("setters",setters);out.add("additions",additions);out.add("ticks",ticking);out.add("promotions",promotions);out.add("removals",removals);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+setters.size()+" native Absorption setter/start/remove contexts, "+additions.size()+" actual addEffect refreshes, "+ticking.size()+" instance ticks, "+promotions.size()+" hidden promotions and "+removals.size()+" actual removals; damage, persistence and live client excluded.");
  }
}
