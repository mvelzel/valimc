import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.world.Difficulty;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.food.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.storage.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.world.entity.ai.attributes.*;
import com.mojang.serialization.Lifecycle;

/** Actual FoodData and peaceful transitions; player health/damage callbacks are controlled. */
public class PlayerFoodOracle {
  private static class ProbeLevel extends ServerLevel {
    Difficulty difficulty; GameRules rules;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0,null,false);}
    public Difficulty getDifficulty(){return difficulty;}
    public GameRules getGameRules(){return rules;}
  }
  private static class Probe extends ServerPlayer {
    ProbeLevel world; float health, healed, damage; DamageSources sources;
    private Probe(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public float getHealth(){return health;}
    public double getAttributeValue(Holder<Attribute> attribute){if(attribute!=Attributes.MAX_HEALTH)throw new AssertionError(attribute);return 20;}
    public void heal(float amount){healed+=amount;}
    public DamageSources damageSources(){return sources;}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){
      if(!source.is(net.minecraft.world.damagesource.DamageTypes.STARVE))throw new AssertionError(source);
      damage+=amount;return true;
    }
    void food(FoodData food)throws Exception{field(Player.class,"foodData").set(this,food);}
    void peaceful(){tickRegeneration();}
  }
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  private static FoodData food(int level,float saturation,float exhaustion,int timer)throws Exception{
    var food=new FoodData();food.setFoodLevel(level);food.setSaturation(saturation);
    field(FoodData.class,"exhaustionLevel").set(food,exhaustion);field(FoodData.class,"tickTimer").set(food,timer);return food;
  }
  private static JsonObject state(FoodData food)throws Exception{
    var state=new JsonObject();state.addProperty("level",food.getFoodLevel());state.addProperty("saturation",(double)food.getSaturationLevel());
    state.addProperty("exhaustion",(double)field(FoodData.class,"exhaustionLevel").getFloat(food));state.addProperty("timer",field(FoodData.class,"tickTimer").getInt(food));return state;
  }
  private static JsonObject input(FoodData food,Probe player,boolean regen)throws Exception{
    var c=state(food);c.addProperty("health",(double)player.health);c.addProperty("difficulty",player.world.difficulty.getId());c.addProperty("regeneration",regen);return c;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var p=(Probe)unsafe.allocateInstance(Probe.class);p.world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    p.world.rules=new GameRules(FeatureFlagSet.of());boolean defaultRegeneration=p.world.rules.get(GameRules.NATURAL_HEALTH_REGENERATION);
    var lookup=VanillaRegistries.createWorldLookup();var source=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var damage=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var id:source.listElementIds().toList())damage.register(id,source.getOrThrow(id).value(),RegistrationInfo.BUILT_IN);
    damage.freeze();p.sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(damage)).freeze());
    var ticks=new JsonArray();
    for(var difficulty:Difficulty.values())for(boolean regen:new boolean[]{false,true}){
      p.world.difficulty=difficulty;p.world.rules.set(GameRules.NATURAL_HEALTH_REGENERATION,regen,null);
      for(int level:new int[]{0,17,18,20})for(float saturation:new float[]{0,.1f,5,20})
      for(float exhaustion:new float[]{0,4,Math.nextUp(4.0f),40})for(int timer:new int[]{0,9,79,80})
      for(float health:new float[]{0,1,10,19.5f,20}){
        var food=food(level,saturation,exhaustion,timer);p.health=health;p.healed=0;p.damage=0;
        var c=input(food,p,regen);food.tick(p);c.add("next",state(food));c.addProperty("heal",(double)p.healed);c.addProperty("damage",(double)p.damage);ticks.add(c);
      }
    }
    var peaceful=new JsonArray();
    for(var difficulty:Difficulty.values())for(boolean regen:new boolean[]{false,true}){
      p.world.difficulty=difficulty;p.world.rules.set(GameRules.NATURAL_HEALTH_REGENERATION,regen,null);
      for(int tick:new int[]{1,9,10,19,20,40})for(int level:new int[]{0,19,20})for(float saturation:new float[]{0,19.5f,20})for(float health:new float[]{0,10,20}){
        var food=food(level,saturation,0,0);p.food(food);p.health=health;p.healed=0;p.damage=0;p.tickCount=tick;
        var c=input(food,p,regen);c.addProperty("tick",tick);p.peaceful();c.add("next",state(food));c.addProperty("heal",(double)p.healed);peaceful.add(c);
      }
    }
    var additions=new JsonArray();
    for(float initial:new float[]{0,.1f,4,39,40})for(float amount:new float[]{0,.1f,4,6,40,Float.MAX_VALUE}){
      var food=food(20,5,initial,0);food.addExhaustion(amount);var c=new JsonObject();c.addProperty("initial",(double)initial);c.addProperty("amount",(double)amount);c.add("next",state(food));additions.add(c);
    }
    var meals=new JsonArray();
    for(int level:new int[]{0,17,20})for(float saturation:new float[]{0,.1f,20})for(int nutrition:new int[]{0,1,4,20})for(float increase:new float[]{0,.1f,6,20}){
      var food=food(level,saturation,0,0);var c=state(food);c.addProperty("nutrition",nutrition);c.addProperty("increase",(double)increase);food.eat(new FoodProperties(nutrition,increase,false));c.add("next",state(food));meals.add(c);
    }
    var defaults=new JsonObject();new FoodData().addAdditionalSaveData((ValueOutput)Proxy.newProxyInstance(ValueOutput.class.getClassLoader(),new Class<?>[]{ValueOutput.class},(proxy,method,a)->{
      if(!Set.of("putInt","putFloat").contains(method.getName()))throw new AssertionError(method);
      defaults.addProperty((String)a[0],(Number)a[1]);return null;
    }));
    var empty=(ValueInput)Proxy.newProxyInstance(ValueInput.class.getClassLoader(),new Class<?>[]{ValueInput.class},(proxy,method,a)->{
      if(!Set.of("getIntOr","getFloatOr").contains(method.getName()))throw new AssertionError(method);return a[1];
    });
    var missing=food(0,0,40,79);missing.readAdditionalSaveData(empty);
    var result=new JsonObject();result.addProperty("default_regeneration",defaultRegeneration);result.add("defaults",defaults);result.add("missing",state(missing));result.add("ticks",ticks);result.add("peaceful",peaceful);result.add("exhaustion",additions);result.add("meals",meals);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+ticks.size()+" native food ticks, "+peaceful.size()+" peaceful prefixes, "+additions.size()+" exhaustion and "+meals.size()+" meal transitions plus save/load defaults; health/damage callbacks controlled.");
  }
}
