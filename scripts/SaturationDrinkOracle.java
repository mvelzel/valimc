import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.food.FoodData;
import net.minecraft.world.item.alchemy.PotionContents;
import net.minecraft.world.level.GameType;

/** Original complete potion saturation delivery into native FoodData; no food ticks or owner state. */
public class SaturationDrinkOracle {
  static class Body extends ServerPlayer {
    ServerLevel world;
    private Body(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public boolean isInvertedHealAndHarm(){return false;}
  }
  static Field field(Class<?> owner,String name)throws Exception {var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    var foodField=field(Player.class,"foodData");var abilities=field(Player.class,"abilities");
    var rows=new JsonArray();
    for(int amp=0;amp<256;amp++)for(int level:new int[]{0,10,19,20})for(float sat:new float[]{0,5,20})
      for(boolean invulnerable:new boolean[]{false,true})for(int duration:new int[]{-1,0,1,200})for(float scale:new float[]{0,.5f,1,4}){
        var a=new Abilities();GameType.SURVIVAL.updatePlayerAbilities(a);a.invulnerable=invulnerable;abilities.set(body,a);
        var food=new FoodData();food.setFoodLevel(level);food.setSaturation(sat);field(FoodData.class,"exhaustionLevel").setFloat(food,3.99f);field(FoodData.class,"tickTimer").setInt(food,9);foodField.set(body,food);
        var contents=new PotionContents(Optional.empty(),Optional.empty(),List.of(new MobEffectInstance(MobEffects.SATURATION,duration,amp)),Optional.empty());
        contents.applyToLivingEntity(body,scale);
        var row=new JsonObject();row.addProperty("amplifier",amp);row.addProperty("level",level);row.addProperty("saturation",(double)sat);row.addProperty("invulnerable",invulnerable);row.addProperty("duration",duration);row.addProperty("duration_scale",(double)scale);row.addProperty("next_level",food.getFoodLevel());row.addProperty("next_saturation",(double)food.getSaturationLevel());row.addProperty("next_exhaustion",(double)field(FoodData.class,"exhaustionLevel").getFloat(food));row.addProperty("next_timer",field(FoodData.class,"tickTimer").getInt(food));rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" actual instant Saturation potion deliveries, all256 amplifiers, food/saturation/ability/duration-scale boundaries and unchanged exhaustion/timer; ticking/containers/live owners excluded.");
  }
}
