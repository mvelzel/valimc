import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.food.FoodData;
import net.minecraft.world.level.GameType;

/** Original native Hunger callback into real player exhaustion, excluding food spending/world ticks. */
public class HungerEffectOracle {
  static class Body extends Player {
    ServerLevel world; GameType mode;
    private Body(){super(null,null);}
    public GameType gameMode(){return mode;}
    public ServerLevel level(){return world;}
  }
  static Field field(Class<?> owner,String name)throws Exception {var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    var abilities=field(Player.class,"abilities");var foodField=field(Player.class,"foodData");var exhaustionField=field(FoodData.class,"exhaustionLevel");
    var rows=new JsonArray();
    for(int amp=0;amp<256;amp++)for(var mode:GameType.values())for(boolean invulnerable:new boolean[]{false,true})
      for(float exhaustion:new float[]{0,3.99f,4,39.99f,40}){
        body.mode=mode;var a=new Abilities();mode.updatePlayerAbilities(a);a.invulnerable=invulnerable;abilities.set(body,a);
        var food=new FoodData();exhaustionField.setFloat(food,exhaustion);foodField.set(body,food);
        boolean applied=MobEffects.HUNGER.value().applyEffectTick(body.world,body,amp);
        var row=new JsonObject();row.addProperty("amplifier",amp);row.addProperty("mode",mode.getName());
        row.addProperty("invulnerable",invulnerable);row.addProperty("before",(double)exhaustion);
        row.addProperty("after",(double)exhaustionField.getFloat(food));row.addProperty("applied",applied);rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    var timing=new JsonArray();body.mode=GameType.SURVIVAL;
    var a=new Abilities();GameType.SURVIVAL.updatePlayerAbilities(a);abilities.set(body,a);
    for(int amp:new int[]{0,1,31,32,255})for(int ticks:new int[]{-1,0,1,2,200})
      for(int age:new int[]{Integer.MIN_VALUE,-1,0,1,99,Integer.MAX_VALUE}){
        var food=new FoodData();foodField.set(body,food);body.tickCount=age;
        var effect=new MobEffectInstance(MobEffects.HUNGER,ticks,amp);
        boolean remains=effect.tickServer(body.world,body,()->{});
        var row=new JsonObject();row.addProperty("amplifier",amp);row.addProperty("ticks",ticks);row.addProperty("age",age);
        row.addProperty("exhaustion",(double)exhaustionField.getFloat(food));row.addProperty("remains",remains);row.addProperty("next_ticks",effect.getDuration());timing.add(row);
      }
    Files.writeString(Path.of(args[1]),new Gson().toJson(timing));
    System.out.println("PASS: "+rows.size()+" actual native Hunger callbacks, all256 amplifiers, modes/ability immunity and food exhaustion boundaries; duration/spending/live owners excluded.");
    System.out.println("PASS: "+timing.size()+" actual native Hunger instance ticks across finite/infinite/zero durations and signed-age boundaries; food spending/live owners excluded.");
  }
}
