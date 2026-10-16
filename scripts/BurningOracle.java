import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.TagKey;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.level.storage.*;

/** Native ignition and complete Entity.baseTick burn callbacks with fluid/world effects controlled. */
public class BurningOracle {
  static class World extends ServerLevel {
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getNextEntityId(){return 1;}
    public int getMinY(){return -64;}
  }
  static class Body extends Entity {
    boolean immune,lava;int calls;float amount;String source;DamageSources sources;
    Body(World world){super(EntityTypes.ITEM,world);setPos(.5,64,.5);}
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    protected boolean updateFluidInteraction(){return false;}
    public void updateSwimming(){}
    public boolean isEyeInFluid(TagKey<Fluid> tag){return false;}
    public boolean isInLava(){return lava;}
    public boolean fireImmune(){return immune;}
    protected boolean shouldPlayLavaHurtSound(){return false;}
    public DamageSources damageSources(){return sources;}
    public boolean hurtServer(ServerLevel level,DamageSource damage,float value){calls++;amount=value;source=damage.typeHolder().unwrapKey().orElseThrow().identifier().getPath();return true;}
    boolean flag(){return getSharedFlag(0);}
  }
  static class Ignition extends Player {
    double factor;int frozen;
    private Ignition(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public double getAttributeValue(Holder<Attribute> attribute){if(!attribute.equals(Attributes.BURNING_TIME))throw new AssertionError(attribute);return factor;}
    public void setTicksFrozen(int ticks){frozen=ticks;}
  }
  static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var damage=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    for(var key:original.listElementIds().toList())damage.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);damage.freeze();
    var sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(damage)).freeze());
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);var world=(World)unsafe.allocateInstance(World.class);
    var ignition=(Ignition)unsafe.allocateInstance(Ignition.class);var ignitions=new JsonArray();var ticks=new JsonArray();var clears=new JsonArray();var lava=new JsonArray();var setters=new JsonArray();
    field(Player.class,"abilities").set(ignition,new net.minecraft.world.entity.player.Abilities());
    for(int current:new int[]{-20,0,1,20,300,Integer.MAX_VALUE})for(double factor:new double[]{0,.1,.3999999761581421,1,1024}){
      for(int duration:new int[]{0,1,20,160,300,20400,Integer.MAX_VALUE}){
        ignition.factor=factor;ignition.frozen=140;ignition.setRemainingFireTicks(current);ignition.igniteForTicks(duration);
        var row=new JsonObject();row.addProperty("current",current);row.addProperty("factor",factor);row.addProperty("ticks",duration);row.addProperty("next",ignition.getRemainingFireTicks());row.addProperty("frozen",ignition.frozen);ignitions.add(row);
      }
      for(float seconds:new float[]{0,Math.nextDown(.05f),.05f,8,15,1020,Float.MAX_VALUE}){
        ignition.factor=factor;ignition.frozen=140;ignition.setRemainingFireTicks(current);ignition.igniteForSeconds(seconds);
        var row=new JsonObject();row.addProperty("current",current);row.addProperty("factor",factor);row.addProperty("seconds",(double)seconds);row.addProperty("next",ignition.getRemainingFireTicks());row.addProperty("frozen",ignition.frozen);ignitions.add(row);
      }
    }
    for(int current:new int[]{Integer.MIN_VALUE,-20,0,1,19,20,21,299,300,Integer.MAX_VALUE}){
      ignition.setRemainingFireTicks(current);ignition.clearFire();var clear=new JsonObject();clear.addProperty("current",current);clear.addProperty("next",ignition.getRemainingFireTicks());clears.add(clear);
      for(boolean immune:new boolean[]{false,true})for(boolean inLava:new boolean[]{false,true}){
        var body=new Body(world);body.sources=sources;body.immune=immune;body.lava=inLava;body.setRemainingFireTicks(current);body.baseTick();
        var row=new JsonObject();row.addProperty("current",current);row.addProperty("immune",immune);row.addProperty("lava",inLava);row.addProperty("next",body.getRemainingFireTicks());row.addProperty("calls",body.calls);row.addProperty("amount",(double)body.amount);row.addProperty("source",body.source);row.addProperty("flag",body.flag());ticks.add(row);
      }
      for(boolean immune:new boolean[]{false,true}){
        var body=new Body(world);body.sources=sources;body.immune=immune;body.setRemainingFireTicks(current);body.lavaIgnite();body.lavaHurt();
        var row=new JsonObject();row.addProperty("current",current);row.addProperty("immune",immune);row.addProperty("next",body.getRemainingFireTicks());row.addProperty("amount",(double)body.amount);row.addProperty("calls",body.calls);row.addProperty("source",body.source);lava.add(row);
      }
    }
    for(var mode:GameType.values()){
      var abilities=new net.minecraft.world.entity.player.Abilities();mode.updatePlayerAbilities(abilities);field(Player.class,"abilities").set(ignition,abilities);
      for(int requested:new int[]{Integer.MIN_VALUE,-20,0,1,20,300,Integer.MAX_VALUE}){
        ignition.setRemainingFireTicks(requested);var row=new JsonObject();row.addProperty("requested",requested);row.addProperty("invulnerable",abilities.invulnerable);row.addProperty("next",ignition.getRemainingFireTicks());setters.add(row);
      }
      for(int current:new int[]{-20,0,1,300})for(int duration:new int[]{0,160,300,Integer.MAX_VALUE}){
        abilities.invulnerable=false;ignition.setRemainingFireTicks(current);mode.updatePlayerAbilities(abilities);ignition.factor=1;ignition.frozen=140;ignition.igniteForTicks(duration);
        var row=new JsonObject();row.addProperty("current",current);row.addProperty("ticks",duration);row.addProperty("factor",1);row.addProperty("invulnerable",abilities.invulnerable);row.addProperty("next",ignition.getRemainingFireTicks());row.addProperty("frozen",ignition.frozen);ignitions.add(row);
      }
    }
    var result=new JsonObject();result.add("ignitions",ignitions);result.add("ticks",ticks);result.add("clears",clears);result.add("lava",lava);result.add("setters",setters);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+ignitions.size()+" actual living/player ignitions, "+ticks.size()+" Entity.baseTick burn callbacks, "+clears.size()+" clear boundaries, "+lava.size()+" lava callbacks and "+setters.size()+" mode setters; fluid discovery/health/world effects excluded.");
  }
}
