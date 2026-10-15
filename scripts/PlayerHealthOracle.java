import com.google.gson.*;
import java.lang.reflect.*;
import java.lang.invoke.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.network.syncher.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.*;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.storage.*;

/** Actual health/save/load, cooldown and player ability-gate prefixes; world/defenses/events excluded. */
public class PlayerHealthOracle {
  private static final RuntimeException STOP=new RuntimeException("health prefix complete");
  private static class Probe extends Player {
    double maximum;
    Float damage;
    GameType mode;
    private Probe(){super(null,null);}
    public GameType gameMode(){return mode==null?GameType.SURVIVAL:mode;}
    public ServerLevel level(){return null;}
    public double getAttributeValue(Holder<Attribute> type){if(type==Attributes.MAX_HEALTH)return maximum;throw new AssertionError(type);}
    public void onSyncedDataUpdated(EntityDataAccessor<?> key){}
    public boolean isInvulnerableTo(ServerLevel level,DamageSource source){return false;}
    public boolean isSleeping(){return false;}
    public ItemStack getUseItem(){return ItemStack.EMPTY;}
    public float applyItemBlocking(ServerLevel level,DamageSource source,float amount){return 0;}
    protected void actuallyHurt(ServerLevel level,DamageSource source,float amount){damage=amount;}
    protected void resolveMobResponsibleForDamage(DamageSource source){throw STOP;}
    void window(int cooldown,float last){damageCooldownTime=cooldown;lastHurt=last;hurtTime=7;damage=null;}
    float last(){return lastHurt;}
    @SuppressWarnings("unchecked")
    private <T> void base(SynchedEntityData.Builder builder,String name,T value)throws Exception{
      builder.define((EntityDataAccessor<T>)field(Entity.class,name).get(null),value);
    }
    void data()throws Exception{
      var b=new SynchedEntityData.Builder(this);
      base(b,"DATA_SHARED_FLAGS_ID",(byte)0);base(b,"DATA_AIR_SUPPLY_ID",300);
      base(b,"DATA_CUSTOM_NAME",Optional.empty());base(b,"DATA_CUSTOM_NAME_VISIBLE",false);
      base(b,"DATA_SILENT",false);base(b,"DATA_NO_GRAVITY",false);
      base(b,"DATA_POSE",Pose.STANDING);base(b,"DATA_TICKS_FROZEN",0);
      defineSynchedData(b);field(Entity.class,"entityData").set(this,b.build());
    }
    void saveHealth(ValueOutput output){super.addAdditionalSaveData(output);}
    void loadHealth(ValueInput input){super.readAdditionalSaveData(input);}
  }
  private static class Source extends DamageSource {
    boolean bypass, bypassAbilities;
    Source(boolean bypass){this(bypass,false);}
    Source(boolean bypass,boolean bypassAbilities){super((Holder<DamageType>)null);this.bypass=bypass;this.bypassAbilities=bypassAbilities;}
    public boolean is(TagKey<DamageType> tag){return (bypass&&tag==DamageTypeTags.BYPASSES_COOLDOWN)||(bypassAbilities&&tag==DamageTypeTags.BYPASSES_INVULNERABILITY);}
    public boolean scalesWithDifficulty(){return false;}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Throwable{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);var p=(Probe)u.allocateInstance(Probe.class);p.maximum=20;p.data();field(LivingEntity.class,"activeEffects").set(p,new HashMap<>());
    var cases=new JsonArray();
    for(double maximum:new double[]{1,20,20.1,1024})for(float value:new float[]{-1,0,Float.MIN_VALUE,.1f,19.999f,20,20.001f,1024,1025,60000000}){
      p.maximum=maximum;p.setHealth(value);p.hurtTime=7;p.deathTime=11;p.damageCooldownTime=17;var saved=new JsonObject();
      var output=(ValueOutput)Proxy.newProxyInstance(ValueOutput.class.getClassLoader(),new Class<?>[]{ValueOutput.class},(proxy,method,a)->{
        if(method.getName().equals("putFloat")){saved.addProperty((String)a[0],(double)(float)a[1]);return null;}
        if(method.getName().equals("putShort")){saved.addProperty((String)a[0],((Number)a[1]).intValue());if(a[0].equals("DeathTime"))throw STOP;return null;}
        throw new AssertionError("Unexpected save prefix "+method);
      });
      try{p.saveHealth(output);throw new AssertionError("Missing save boundary");}catch(RuntimeException e){if(e!=STOP)throw e;}
      var c=new JsonObject();c.addProperty("maximum",maximum);c.addProperty("input",(double)value);c.addProperty("health",(double)p.getHealth());c.add("saved",saved);
      for(boolean missing:new boolean[]{false,true}){
        p.setHealth(0);p.hurtTime=0;p.deathTime=0;p.damageCooldownTime=0;
        var input=(ValueInput)Proxy.newProxyInstance(ValueInput.class.getClassLoader(),new Class<?>[]{ValueInput.class},(proxy,method,a)->{
          return switch(method.getName()){
            case "getFloatOr" -> a[0].equals("Health")&&!missing?saved.get("Health").getAsFloat():a[1];
            case "getShortOr" -> missing?(int)(short)a[1]:saved.get((String)a[0]).getAsInt();
            case "getBooleanOr" -> {if(a[0].equals("FallFlying"))throw STOP;yield a[1];}
            case "read" -> Optional.empty();
            default -> throw new AssertionError("Unexpected load prefix "+method);
          };
        });
        try{p.loadHealth(input);throw new AssertionError("Missing load boundary");}catch(RuntimeException e){if(e!=STOP)throw e;}
        var loaded=new JsonObject();loaded.addProperty("health",(double)p.getHealth());loaded.addProperty("hurt",p.hurtTime);loaded.addProperty("death",p.deathTime);loaded.addProperty("cooldown",p.damageCooldownTime);c.add(missing?"missing":"loaded",loaded);
      }
      cases.add(c);
    }
    var windows=new JsonArray();
    var hurt=MethodHandles.privateLookupIn(LivingEntity.class,MethodHandles.lookup()).findSpecial(LivingEntity.class,"hurtServer",MethodType.methodType(boolean.class,ServerLevel.class,DamageSource.class,float.class),LivingEntity.class);
    for(int cooldown:new int[]{0,10,11,20})for(float last:new float[]{0,.1f,2})for(float amount:new float[]{-1,0,.05f,.1f,2,3,Float.MAX_VALUE})for(boolean bypass:new boolean[]{false,true})for(float health:new float[]{0,20}){
      p.maximum=20;p.setHealth(health);p.window(cooldown,last);boolean accepted=false;
      try{if((boolean)hurt.invoke(p,(ServerLevel)null,new Source(bypass),amount))throw new AssertionError("Missing hurt boundary");}catch(RuntimeException e){if(e!=STOP)throw e;accepted=true;}
      var c=new JsonObject();c.addProperty("cooldown",cooldown);c.addProperty("last",(double)last);c.addProperty("amount",(double)amount);c.addProperty("bypass",bypass);c.addProperty("health",(double)health);c.addProperty("accepted",accepted);c.addProperty("damage",p.damage==null?0:(double)p.damage);c.addProperty("next_cooldown",p.damageCooldownTime);c.addProperty("next_hurt",p.hurtTime);c.addProperty("next_last",(double)p.last());windows.add(c);
    }
    var modeWindows=new JsonArray();
    var playerHurt=MethodHandles.privateLookupIn(Player.class,MethodHandles.lookup()).findSpecial(Player.class,"hurtServer",MethodType.methodType(boolean.class,ServerLevel.class,DamageSource.class,float.class),Player.class);
    for(var mode:GameType.values())for(boolean bypassAbilities:new boolean[]{false,true})for(int cooldown:new int[]{0,11,20})for(float health:new float[]{0,20}){
      p.mode=mode;var abilities=new net.minecraft.world.entity.player.Abilities();mode.updatePlayerAbilities(abilities);field(Player.class,"abilities").set(p,abilities);
      p.setHealth(health);p.window(cooldown,2);boolean accepted=false;
      try{if((boolean)playerHurt.invoke(p,(ServerLevel)null,new Source(false,bypassAbilities),4))throw new AssertionError("Missing player hurt boundary");}catch(RuntimeException e){if(e!=STOP)throw e;accepted=true;}
      var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("bypass_abilities",bypassAbilities);c.addProperty("health",health);c.addProperty("cooldown",cooldown);c.addProperty("accepted",accepted);c.addProperty("damage",p.damage==null?0:(double)p.damage);modeWindows.add(c);
    }
    var result=new JsonObject();result.add("health",cases);result.add("windows",windows);result.add("mode_windows",modeWindows);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));System.out.println("PASS: "+cases.size()+" actual health/save/load cases, "+windows.size()+" cooldown prefixes and "+modeWindows.size()+" player ability/window prefixes (world/defenses/events/death excluded).");
  }
}
