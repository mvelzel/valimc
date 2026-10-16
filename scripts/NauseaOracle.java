import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;

/** Original observations of native Nausea hooks and duration ticks; no rendered-client claim. */
public class NauseaOracle {
  static class Body extends LivingEntity {
    private Body(){super(EntityTypes.ARMOR_STAND,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
  }
  static Field hidden;
  static JsonArray state(MobEffectInstance value)throws Exception {
    var out=new JsonArray();
    while(value!=null){
      var rung=new JsonArray();rung.add(value.getDuration());rung.add(value.getAmplifier());
      rung.add(value.isAmbient());rung.add(value.isVisible());rung.add(value.showIcon());out.add(rung);
      value=(MobEffectInstance)hidden.get(value);
    }
    return out;
  }
  static MobEffectInstance instance(int ticks,int amp,int flags){
    return new MobEffectInstance(MobEffects.NAUSEA,ticks,amp,(flags&1)!=0,(flags&2)!=0,(flags&4)!=0);
  }
  static JsonObject tick(MobEffectInstance value,Body body)throws Exception {
    var row=new JsonObject();row.add("before",state(value));int[] promoted={0};body.tickCount++;
    row.addProperty("remains",value.tickServer(null,body,()->promoted[0]++));
    row.addProperty("promotions",promoted[0]);row.add("after",state(value));return row;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    hidden=MobEffectInstance.class.getDeclaredField("hiddenEffect");hidden.setAccessible(true);
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);
    var body=(Body)((sun.misc.Unsafe)f.get(null)).allocateInstance(Body.class);
    var effect=MobEffects.NAUSEA.value();
    if(effect.getClass()!=MobEffect.class||effect.isInstantaneous()||effect.isBeneficial())throw new AssertionError("Unexpected Nausea implementation");
    var rows=new JsonArray();int hooks=0;
    for(int amp=0;amp<256;amp++){
      int[] attributes={0};effect.createModifiers(amp,(attribute,modifier)->attributes[0]++);
      if(attributes[0]!=0)throw new AssertionError("Nausea modifies server attributes");
      // Null endpoints make unexpected server mutations fail rather than hiding them in a mock.
      effect.onEffectStarted(null,amp);effect.onEffectAdded(null,amp);
      effect.addAttributeModifiers(null,amp);effect.removeAttributeModifiers(null);
      if(!effect.applyEffectTick(null,null,amp))throw new AssertionError("Unexpected terminal action");
      hooks++;
      for(int duration:new int[]{-1,0,1,20,300,Integer.MAX_VALUE}){
        if(effect.shouldApplyEffectTickThisTick(duration,amp))throw new AssertionError("Unexpected periodic request");
        for(int flags:new int[]{0,7}){
          var value=instance(duration,amp,flags);rows.add(tick(value,body));
        }
      }
    }
    for(int stronger:new int[]{1,7,255}){
      var value=instance(300,0,7);value.update(instance(1,stronger,7));rows.add(tick(value,body));
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);
    out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("hook_contexts",hooks);out.addProperty("blend_in",effect.getBlendInDurationTicks());
    out.addProperty("blend_out",effect.getBlendOutDurationTicks());out.addProperty("blend_advance",effect.getBlendOutAdvanceTicks());out.add("ticks",rows);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+hooks+" Nausea no-action/no-attribute hook contexts and "+rows.size()+" actual instance ticks/promotions; graphical distortion excluded.");
  }
}
