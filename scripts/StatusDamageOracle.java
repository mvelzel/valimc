import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;

/** Actual LivingEntity fire-resistance rejection before downstream hurt work; other immunity disabled. */
public class StatusDamageOracle {
  static final class PassedGate extends RuntimeException {public synchronized Throwable fillInStackTrace(){return this;}}
  static final PassedGate PASSED=new PassedGate();
  static class Body extends LivingEntity {
    private Body(){super(EntityTypes.ARMOR_STAND,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public boolean isInvulnerableTo(ServerLevel level,DamageSource source){return false;}
    public boolean isDeadOrDying(){return false;}
    public boolean isSleeping(){throw PASSED;}
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();var damage=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,Registries.DAMAGE_TYPE,(id,required)->damage.get(net.minecraft.resources.ResourceKey.create(Registries.DAMAGE_TYPE,id)));
      var memberships=new HashMap<Holder<DamageType>,List<TagKey<DamageType>>>();tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      for(var holder:damage.listElements().toList())bind.invoke(holder,memberships.getOrDefault(holder,List.of()));
    }
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var u=(sun.misc.Unsafe)field.get(null);var body=(Body)u.allocateInstance(Body.class);
    var active=LivingEntity.class.getDeclaredField("activeEffects");active.setAccessible(true);var effects=new HashMap<Holder<MobEffect>,MobEffectInstance>();active.set(body,effects);
    var fire=new JsonArray();var rows=new JsonArray();
    for(var key:damage.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())for(int fixture=0;fixture<6;fixture++){
      effects.clear();int ticks=switch(fixture){case 1->0;case 3->-1;default->1;};int amplifier=fixture==4?255:0;
      var effect=fixture==5?MobEffects.WATER_BREATHING:MobEffects.FIRE_RESISTANCE;
      if(fixture!=0)effects.put(effect,new MobEffectInstance(effect,ticks,amplifier));
      var source=new DamageSource(damage.getOrThrow(key));boolean rejected;
      try{if(body.hurtServer(null,source,1))throw new AssertionError("Unexpected successful downstream damage");rejected=true;}
      catch(PassedGate passed){rejected=false;}
      if((fixture==0||fixture==5)&&rejected)throw new AssertionError("Unexpected baseline immunity");
      if(rejected&&fixture==1)fire.add(key.identifier().getPath());var row=new JsonObject();row.addProperty("source",key.identifier().getPath());row.addProperty("effect",fixture==0?-1:BuiltInRegistries.MOB_EFFECT.getId(effect.value()));row.addProperty("ticks",ticks);row.addProperty("amplifier",amplifier);row.addProperty("rejected",rejected);rows.add(row);
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.add("fire_resistance_sources",fire);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native map-presence/status rejection gates across all51 stock sources before downstream hurt work. Zero/finite/infinite durations, amplifier255 and unrelated effect included. Mode/base/enchantment immunity, health/wear and status clock excluded.");
  }
}
