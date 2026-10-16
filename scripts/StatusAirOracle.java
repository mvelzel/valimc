import com.google.gson.*;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Original probe: actual effect-map presence and native air predicates, not a copied baseTick. */
public class StatusAirOracle {
  static class Probe extends Player {
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
  }
  static final JsonArray rows=new JsonArray();
  static Field active;
  static void observe(Probe body,List<Holder<MobEffect>> effects,int duration,int amplifier)throws Exception {
    var map=new HashMap<Holder<MobEffect>,MobEffectInstance>();var ids=new JsonArray();
    for(var effect:effects){map.put(effect,new MobEffectInstance(effect,duration,amplifier));ids.add(BuiltInRegistries.MOB_EFFECT.getId(effect.value()));}
    active.set(body,map);var row=new JsonObject();row.add("effects",ids);row.addProperty("ticks",duration);row.addProperty("amplifier",amplifier);
    row.addProperty("breathes",MobEffectUtil.hasWaterBreathing(body));
    row.addProperty("refills",MobEffectUtil.shouldEffectsRefillAirsupply(body));rows.add(row);
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var body=(Probe)((sun.misc.Unsafe)field.get(null)).allocateInstance(Probe.class);
    active=LivingEntity.class.getDeclaredField("activeEffects");active.setAccessible(true);
    observe(body,List.of(),200,0);
    for(var effect:BuiltInRegistries.MOB_EFFECT.listElements().toList())
      for(int ticks:new int[]{-1,0,1,200,Integer.MAX_VALUE})for(int amplifier:new int[]{0,255})
        observe(body,List.of(effect),ticks,amplifier);
    var relevant=List.of(MobEffects.WATER_BREATHING,MobEffects.CONDUIT_POWER,MobEffects.BREATH_OF_THE_NAUTILUS);
    for(int mask=0;mask<8;mask++)for(int ticks:new int[]{-1,0,1,200}){
      var effects=new ArrayList<Holder<MobEffect>>();for(int i=0;i<3;i++)if((mask&(1<<i))!=0)effects.add(relevant.get(i));
      observe(body,effects,ticks,0);
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native breathing/refill predicate contexts over the actual effect map. Base tick, air mutation, attributes and live actions excluded.");
  }
}
