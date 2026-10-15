import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.server.Bootstrap;
import net.minecraft.tags.TagKey;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Actual native fall calculation with supplied attributes/material/immunity; no health or landing side effects. */
public class FallDamageOracle {
  private static class Probe extends Player {
    double safe,multiplier;boolean immune;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public boolean is(TagKey<EntityType<?>> tag){return immune;}
    public double getAttributeValue(Holder<Attribute> type){
      if(type==Attributes.SAFE_FALL_DISTANCE)return safe;
      if(type==Attributes.FALL_DAMAGE_MULTIPLIER)return multiplier;
      throw new AssertionError("Unexpected attribute "+type);
    }
    int calculate(double distance,float material){return calculateFallDamage(distance,material);}
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var u=(sun.misc.Unsafe)field.get(null);var p=(Probe)u.allocateInstance(Probe.class);var cases=new JsonArray();
    for(double safe:new double[]{-1024,0,3,4.5,1024})for(double distance:new double[]{0,2.999998,2.999999,3,3.5,3.999998,3.999999,4,4.000001,5,20,100,60000000})
      for(float material:new float[]{0,.2f,.5f,1,4})for(double multiplier:new double[]{0,.1,1,100})for(boolean immune:new boolean[]{false,true}){
        p.safe=safe;p.multiplier=multiplier;p.immune=immune;var c=new JsonObject();c.addProperty("distance",distance);c.addProperty("safe",safe);c.addProperty("material",(double)material);c.addProperty("multiplier",multiplier);c.addProperty("immune",immune);c.addProperty("damage",p.calculate(distance,material));cases.add(c);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native fall calculation cases with thresholds, factors, immunity and int saturation.");
  }
}
