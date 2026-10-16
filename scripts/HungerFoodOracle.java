import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.lang.reflect.*;
import java.nio.file.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.world.Difficulty;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.MobEffects;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.flag.FeatureFlagSet;
import net.minecraft.world.food.FoodData;
import net.minecraft.world.level.gamerules.GameRules;

/** Original native Hunger callback followed by actual FoodData processing; health endpoints observed. */
public class HungerFoodOracle {
  static class World extends ServerLevel {
    Difficulty difficulty; GameRules rules;
    private World(){super(null,null,null,null,null,null,false,0,null,false);}
    public Difficulty getDifficulty(){return difficulty;}
    public GameRules getGameRules(){return rules;}
  }
  static class Body extends ServerPlayer {
    World world; float health,heal,damage; DamageSources sources;
    private Body(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public float getHealth(){return health;}
    public double getAttributeValue(Holder<Attribute> type){if(!type.equals(Attributes.MAX_HEALTH))throw new AssertionError(type);return 20;}
    public void heal(float amount){heal+=amount;}
    public DamageSources damageSources(){return sources;}
    public boolean hurtServer(ServerLevel world,DamageSource source,float amount){if(!source.is(DamageTypes.STARVE))throw new AssertionError(source);damage+=amount;return true;}
  }
  static Field field(Class<?> type,String name)throws Exception {var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  static JsonObject state(FoodData food)throws Exception {
    var row=new JsonObject();row.addProperty("level",food.getFoodLevel());row.addProperty("saturation",(double)food.getSaturationLevel());row.addProperty("exhaustion",(double)field(FoodData.class,"exhaustionLevel").getFloat(food));row.addProperty("timer",field(FoodData.class,"tickTimer").getInt(food));return row;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=(World)unsafe.allocateInstance(World.class);body.world.rules=new GameRules(FeatureFlagSet.of());field(Player.class,"abilities").set(body,new Abilities());
    var source=VanillaRegistries.createWorldLookup().lookupOrThrow(Registries.DAMAGE_TYPE);var damage=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var key:source.listElementIds().toList())damage.register(key,source.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);
    damage.freeze();body.sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(java.util.List.of(damage)).freeze());
    var rows=new JsonArray();
    for(var difficulty:Difficulty.values())for(boolean regen:new boolean[]{false,true}){
      body.world.difficulty=difficulty;body.world.rules.set(GameRules.NATURAL_HEALTH_REGENERATION,regen,null);
      for(int amp:new int[]{0,1,19,255})for(int level:new int[]{0,17,18,20})for(float sat:new float[]{0,5})
        for(float exhaustion:new float[]{0,3.99f,4,39.99f,40})for(int timer:new int[]{0,9,79})for(float health:new float[]{1,10,20}){
          var food=new FoodData();food.setFoodLevel(level);food.setSaturation(sat);field(FoodData.class,"exhaustionLevel").setFloat(food,exhaustion);field(FoodData.class,"tickTimer").setInt(food,timer);field(Player.class,"foodData").set(body,food);body.health=health;body.heal=0;body.damage=0;
          var row=new JsonObject();row.add("before",state(food));row.addProperty("health",(double)health);row.addProperty("difficulty",difficulty.getId());row.addProperty("regeneration",regen);row.addProperty("amplifier",amp);
          MobEffects.HUNGER.value().applyEffectTick(body.world,body,amp);food.tick(body);
          row.add("after",state(food));row.addProperty("heal",(double)body.heal);row.addProperty("damage",(double)body.damage);rows.add(row);
        }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));System.out.println("PASS: "+rows.size()+" native Hunger-before-food compositions, thresholds/caps, difficulties/regen/starvation requests; owner death/replication excluded.");
  }
}
