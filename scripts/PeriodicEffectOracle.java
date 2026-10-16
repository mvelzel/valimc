import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Original probe: native instance timing and intercepted health requests, before downstream defenses. */
public class PeriodicEffectOracle {
  static class Body extends Player {
    float health, maximum; DamageSources sources; JsonArray actions;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public float getHealth(){return health;}
    public double getAttributeValue(Holder<Attribute> attribute){if(!attribute.equals(Attributes.MAX_HEALTH))throw new AssertionError(attribute);return maximum;}
    public void heal(float amount){var action=new JsonArray();action.add("heal");action.add(amount);actions.add(action);}
    public DamageSources damageSources(){return sources;}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){
      var action=new JsonArray();action.add("hurt");action.add(source.typeHolder().unwrapKey().orElseThrow().identifier().getPath());action.add(amount);actions.add(action);return true;
    }
  }
  static Field hidden;
  static JsonArray state(MobEffectInstance effect)throws Exception {
    var result=new JsonArray();
    for(int count=0;effect!=null;effect=(MobEffectInstance)hidden.get(effect)){
      if(++count>256)throw new AssertionError("Unbounded instance chain");
      var rung=new JsonArray();rung.add(effect.getDuration());rung.add(effect.getAmplifier());rung.add(effect.isAmbient());rung.add(effect.isVisible());rung.add(effect.showIcon());result.add(rung);
    }
    return result;
  }
  static JsonObject observe(Body body,MobEffectInstance effect,int age,float health,float maximum)throws Exception {
    body.tickCount=age;body.health=health;body.maximum=maximum;body.actions=new JsonArray();
    var row=new JsonObject();row.addProperty("id",BuiltInRegistries.MOB_EFFECT.getId(effect.getEffect().value()));row.add("initial",state(effect));
    row.addProperty("age",age);row.addProperty("health",health);row.addProperty("maximum",maximum);
    int[] promotions={0};boolean remains=effect.tickServer(null,body,()->promotions[0]++);
    row.add("actions",body.actions);row.addProperty("remains",remains);row.addProperty("promotions",promotions[0]);row.add("next",state(effect));return row;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var registry=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var key:original.listElementIds().toList())registry.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);
    registry.freeze();var sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze());
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var body=(Body)((sun.misc.Unsafe)field.get(null)).allocateInstance(Body.class);body.sources=sources;
    hidden=MobEffectInstance.class.getDeclaredField("hiddenEffect");hidden.setAccessible(true);
    var rows=new JsonArray();
    for(var kind:List.of(MobEffects.REGENERATION,MobEffects.POISON,MobEffects.WITHER))for(int amplifier=0;amplifier<=255;amplifier++)
      for(int duration:new int[]{-1,0,1,2,24,25,26,39,40,49,50,51,600,Integer.MAX_VALUE})
        for(int age:duration==-1?new int[]{Integer.MIN_VALUE,-50,-1,0,1,25,40,50,600,Integer.MAX_VALUE}:new int[]{19})
          for(float health:new float[]{0,.5f,1,Math.nextUp(1f),5,19.5f,20})
            rows.add(observe(body,new MobEffectInstance(kind,duration,amplifier),age,health,20));
    for(var kind:List.of(MobEffects.REGENERATION,MobEffects.POISON,MobEffects.WITHER))for(int amplifier:new int[]{0,1,31,32,255})
      for(float maximum:new float[]{1,128,1024})for(float health:new float[]{0,1,maximum-.5f,maximum})
        rows.add(observe(body,new MobEffectInstance(kind,-1,amplifier),600,health,maximum));
    // Continuous native instances exercise action-before-expiry and hidden promotion.
    for(var kind:List.of(MobEffects.REGENERATION,MobEffects.POISON,MobEffects.WITHER))for(int stronger:new int[]{1,31,32,255}){
      var effect=new MobEffectInstance(kind,-1,0);effect.update(new MobEffectInstance(kind,1,stronger));
      for(int age=1;age<=64;age++)rows.add(observe(body,effect,age,5,20));
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native regeneration/poison/wither instance ticks, intercepted heal/damage requests, all256 amplifiers, finite/infinite phases, thresholds and hidden promotion. Downstream defenses/health application and live ownership excluded.");
  }
}
