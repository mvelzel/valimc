import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.material.*;

/** Native ordered block/fluid effect callbacks; controlled body, random steps and damage requests. */
public class FireContactOracle {
  static class World extends ServerLevel {
    DamageSources sources;RandomSource random;
    protected World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public DamageSources damageSources(){return sources;}
    public RandomSource getRandom(){return random;}
  }
  static class Body extends ServerPlayer {
    World world;double factor;int frozen;boolean immune;List<String> damage;
    protected Body(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public boolean fireImmune(){return immune;}
    public boolean isAlive(){return true;}
    public double getAttributeValue(Holder<Attribute> attribute){if(!attribute.equals(Attributes.BURNING_TIME))throw new AssertionError(attribute);return factor;}
    public void setTicksFrozen(int ticks){frozen=ticks;}
    public DamageSources damageSources(){return world.sources;}
    protected boolean shouldPlayLavaHurtSound(){return false;}
    public void playEntityOnFireExtinguishedSound(){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){damage.add(source.typeHolder().unwrapKey().orElseThrow().identifier().getPath()+":"+amount);return true;}
  }
  static class Draws implements InvocationHandler {
    int increment,count;
    Draws(int increment){this.increment=increment;}
    public Object invoke(Object proxy,Method method,Object[] args){
      if(!method.getName().equals("nextInt")||args.length!=2||!args[0].equals(1)||!args[1].equals(3))throw new AssertionError("Unexpected RNG "+method);
      count++;return increment;
    }
    RandomSource source(){return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},this);}
  }
  static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var registry=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    for(var key:original.listElementIds().toList())registry.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);registry.freeze();
    var sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze());
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(World)unsafe.allocateInstance(World.class);world.sources=sources;
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=world;body.damage=new ArrayList<>();field(Entity.class,"level").set(body,world);
    var abilities=new net.minecraft.world.entity.player.Abilities();field(Player.class,"abilities").set(body,abilities);
    var block=BaseFireBlock.class.getDeclaredMethod("entityInside",BlockState.class,Level.class,BlockPos.class,Entity.class,InsideBlockEffectApplier.class,boolean.class);block.setAccessible(true);
    var lava=LavaFluid.class.getDeclaredMethod("entityInside",Level.class,BlockPos.class,Entity.class,InsideBlockEffectApplier.class);lava.setAccessible(true);
    var water=WaterFluid.class.getDeclaredMethod("entityInside",Level.class,BlockPos.class,Entity.class,InsideBlockEffectApplier.class);water.setAccessible(true);
    var rows=new JsonArray();
    for(int current:new int[]{Integer.MIN_VALUE,-20,-2,-1,0,1,20,160,300,Integer.MAX_VALUE})for(double factor:new double[]{0,.3999999761581421,1})for(boolean invulnerable:new boolean[]{false,true})for(boolean immune:new boolean[]{false,true})for(int increment:new int[]{1,2})
      for(String pattern:List.of("fire","soul_fire","lava","water","fire,fire","fire,soul_fire","fire,lava","lava,water","fire,water","fire|water","water|fire","soul_fire,fire","lava,fire","water,lava,fire","fire|fire","fire|lava|water","lava,lava")){
        abilities.invulnerable=false;body.setRemainingFireTicks(current);abilities.invulnerable=invulnerable;body.factor=factor;body.frozen=140;body.immune=immune;body.damage.clear();var draws=new Draws(increment);world.random=draws.source();
        var collector=new InsideBlockEffectApplier.StepBasedCollector();int step=0;
        for(String part:pattern.split("\\|")){
          collector.advanceStep(step++);
          for(String kind:part.split(","))switch(kind){
            case "fire","soul_fire"->{var fire=kind.equals("fire")?Blocks.FIRE:Blocks.SOUL_FIRE;block.invoke(fire,fire.defaultBlockState(),world,BlockPos.ZERO,body,collector,false);}
            case "lava"->lava.invoke(Fluids.LAVA,world,BlockPos.ZERO,body,collector);
            case "water"->water.invoke(Fluids.WATER,world,BlockPos.ZERO,body,collector);
            default->throw new AssertionError(kind);
          }
        }
        collector.applyAndClear(body);
        var row=new JsonObject();row.addProperty("current",current);row.addProperty("factor",factor);row.addProperty("invulnerable",invulnerable);row.addProperty("immune",immune);row.addProperty("increment",increment);row.addProperty("pattern",pattern);
        row.addProperty("next",body.getRemainingFireTicks());row.addProperty("frozen",body.frozen);row.addProperty("draws",draws.count);row.add("damage",new Gson().toJsonTree(body.damage));rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual fire/soul-fire/lava/water callbacks through native StepBasedCollector; negative cooldowns, ServerPlayer random extension, mode caps, overflow, shared-step deduplication and ordered steps. Geometry/health excluded.");
  }
}
