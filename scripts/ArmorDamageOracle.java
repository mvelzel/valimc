import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.ai.attributes.RangedAttribute;

/** Actual armor arithmetic with a non-weapon damage source; equipment/wear/health excluded. */
public class ArmorDamageOracle {
  static void observe(JsonArray rows,DamageSource source,float amount,float armor,float toughness){
    var row=new JsonObject();row.addProperty("amount",(double)amount);row.addProperty("armor",(double)armor);
    row.addProperty("toughness",(double)toughness);
    row.addProperty("damage",(double)CombatRules.getDamageAfterAbsorb(null,amount,source,armor,toughness));rows.add(row);
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var source=new DamageSource(lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(DamageTypes.LAVA));
    if(source.getWeaponItem()!=null)throw new AssertionError("Weapon effects would invalidate scalar fixture");
    var armorAttribute=(RangedAttribute)Attributes.ARMOR.value();
    var toughnessAttribute=(RangedAttribute)Attributes.ARMOR_TOUGHNESS.value();
    if(armorAttribute.getMinValue()!=0||armorAttribute.getMaxValue()!=30||toughnessAttribute.getMinValue()!=0||toughnessAttribute.getMaxValue()!=20)
      throw new AssertionError("Pinned armor attribute domains changed");
    var rows=new JsonArray();
    for(float armor:new float[]{0,1,4,8,16,20,24,30,Math.nextDown(30f)})
      for(float toughness:new float[]{0,2,8,12,20}){
        for(float amount:new float[]{0,Float.MIN_VALUE,.1f,.5f,1,4,10,20,100,Float.MAX_VALUE})observe(rows,source,amount,armor,toughness);
        float edge=(armor-armor*.2f)*(2+toughness/4);
        for(float amount:new float[]{Math.nextDown(edge),edge,Math.nextUp(edge)})if(amount>=0)observe(rows,source,amount,armor,toughness);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual CombatRules armor/toughness cases, native attribute domains and float32 clamp boundaries; weapon effects/equipment/wear excluded.");
  }
}
