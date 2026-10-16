import com.google.gson.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Original native Jump Boost power/attribute/fall fixtures with controlled material/effect heads. */
public class JumpBoostOracle {
  static class Body extends Player {
    AttributeMap attributes; MobEffectInstance boost; float factor;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public boolean hasEffect(Holder<MobEffect> type){if(type!=MobEffects.JUMP_BOOST)throw new AssertionError(type);return boost!=null;}
    public MobEffectInstance getEffect(Holder<MobEffect> type){if(type!=MobEffects.JUMP_BOOST)throw new AssertionError(type);return boost;}
    public double getAttributeValue(Holder<Attribute> type){return attributes.getValue(type);}
    protected float getBlockJumpFactor(){return factor;}
    float power(){return getJumpPower();}
    int fall(double distance,float material){return calculateFallDamage(distance,material);}
    public boolean is(net.minecraft.tags.TagKey<EntityType<?>> tag){return false;}
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);
    var body=(Body)((sun.misc.Unsafe)f.get(null)).allocateInstance(Body.class);
    var supplier=Player.createAttributes().build();var rows=new JsonArray();
    for(int amp=-1;amp<256;amp++){
      body.attributes=new AttributeMap(supplier);
      body.boost=amp<0?null:new MobEffectInstance(MobEffects.JUMP_BOOST,200,amp);
      if(amp>=0)MobEffects.JUMP_BOOST.value().addAttributeModifiers(body.attributes,amp);
      var row=new JsonObject();row.addProperty("amplifier",amp);
      var safe=body.attributes.getInstance(Attributes.SAFE_FALL_DISTANCE);
      row.addProperty("attribute_id",BuiltInRegistries.ATTRIBUTE.getId(Attributes.SAFE_FALL_DISTANCE.value()));
      row.addProperty("safe_base",safe.getBaseValue());row.addProperty("safe_distance",safe.getValue());
      row.addProperty("jump_strength",body.getAttributeValue(Attributes.JUMP_STRENGTH));
      row.addProperty("jump_bonus",(double)body.getJumpBoostPower());
      var modifiers=new JsonArray();
      for(var modifier:safe.getModifiers()){
        var m=new JsonArray();m.add(modifier.id().toString());m.add(modifier.amount());m.add(modifier.operation().ordinal());modifiers.add(m);
      }
      row.add("modifiers",modifiers);var powers=new JsonArray();
      for(float factor:new float[]{0,.00001f,.5f,1,4}){
        body.factor=factor;var power=new JsonArray();power.add((double)factor);power.add((double)body.power());powers.add(power);
      }
      row.add("powers",powers);var falls=new JsonArray();double threshold=safe.getValue();
      for(double distance:new double[]{0,3,4,5,threshold-1e-6,threshold,threshold+1,threshold+8})
        for(float material:new float[]{0,.2f,.5f,1,4}){
          var fall=new JsonArray();fall.add(distance);fall.add((double)material);fall.add(body.fall(distance,material));falls.add(fall);
        }
      row.add("falls",falls);
      MobEffects.JUMP_BOOST.value().removeAttributeModifiers(body.attributes);
      row.addProperty("removed_safe",safe.getValue());rows.add(row);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);
    out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",rows);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+rows.size()+" native Jump Boost attributes/removal, "+rows.size()*5+" material powers and "+rows.size()*40+" fall calculations; live motion/packets excluded.");
  }
}
