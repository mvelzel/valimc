import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.Level;

/** Original native resistance path; actual effect map/tags, no armor/gear/health/statistics. */
public class ResistanceOracle {
  static class Body extends LivingEntity {
    private Body(){super(EntityTypes.ARMOR_STAND,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    // Non-server context skips worn-enchantment lookup after resistance; no effect lookup is mocked.
    public Level level(){return null;}
    float reduce(DamageSource source,float amount){return getDamageAfterMagicAbsorb(source,amount);}
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();var damage=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,Registries.DAMAGE_TYPE,(id,required)->damage.get(net.minecraft.resources.ResourceKey.create(Registries.DAMAGE_TYPE,id)));
      var memberships=new HashMap<Holder<DamageType>,List<TagKey<DamageType>>>();tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      for(var holder:damage.listElements().toList())bind.invoke(holder,memberships.getOrDefault(holder,List.of()));
    }
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var body=(Body)((sun.misc.Unsafe)field.get(null)).allocateInstance(Body.class);
    var active=LivingEntity.class.getDeclaredField("activeEffects");active.setAccessible(true);var effects=new HashMap<Holder<MobEffect>,MobEffectInstance>();active.set(body,effects);
    var rows=new JsonArray();int overflow=0;
    for(var key:damage.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())for(int amplifier=-1;amplifier<=255;amplifier++)
      for(int duration:amplifier==0||amplifier==1||amplifier==4||amplifier==255?new int[]{-1,0,1}:new int[]{1})
        for(float amount:new float[]{0,Float.MIN_VALUE,.1f,1,5,20,1000000,Float.MAX_VALUE/20,Math.nextUp(Float.MAX_VALUE/20),Float.MAX_VALUE}){
          effects.clear();if(amplifier>=0)effects.put(MobEffects.RESISTANCE,new MobEffectInstance(MobEffects.RESISTANCE,duration,amplifier));
          var source=new DamageSource(damage.getOrThrow(key));float reduced=body.reduce(source,amount);if(Float.isNaN(reduced)||reduced<0)throw new AssertionError("Unexpected native result");
          var row=new JsonObject();row.addProperty("source",key.identifier().getPath());row.addProperty("amplifier",amplifier);row.addProperty("duration",duration);row.addProperty("amount",(double)amount);
          if(Float.isInfinite(reduced)){overflow++;row.addProperty("reduced","infinity");}else row.addProperty("reduced",(double)reduced);
          rows.add(row);
        }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native resistance/source/float contexts across all51 sources and256 amplifiers; "+overflow+" positive-infinite results explicitly labeled. Armor/worn enchantments/health/statistics excluded.");
  }
}
