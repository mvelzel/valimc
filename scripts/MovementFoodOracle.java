import com.google.gson.*;
import java.lang.reflect.*;
import java.lang.invoke.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.resources.Identifier;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.TagKey;
import net.minecraft.world.level.material.Fluid;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.food.FoodData;
import net.minecraft.world.level.GameType;

/** Native travel, ability gates and jump callbacks; owner/world contacts excluded. */
public class MovementFoodOracle {
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel(){super(null,null,null,null,null,null,false,0,null,false);}
  }
  private static class Probe extends ServerPlayer {
    int flags; float exhaustion; ProbeLevel world;
    private Probe(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public boolean isPassenger(){return (flags&1)!=0;}
    public boolean isSwimming(){return (flags&2)!=0;}
    public boolean isEyeInFluid(TagKey<Fluid> fluid){return (flags&4)!=0;}
    public boolean isInWater(){return (flags&8)!=0;}
    public boolean onClimbable(){return (flags&16)!=0;}
    public boolean onGround(){return (flags&32)!=0;}
    public boolean isSprinting(){return (flags&64)!=0;}
    public boolean isCrouching(){return (flags&128)!=0;}
    public boolean isFallFlying(){return false;}
    protected float getJumpPower(){return 0;}
    public void awardStat(Identifier stat){}
    public void awardStat(Identifier stat,int amount){}
    public void causeFoodExhaustion(float amount){exhaustion+=amount;}
  }
  public static void main(String[] args)throws Throwable{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)field.get(null);var p=(Probe)unsafe.allocateInstance(Probe.class);
    p.world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    var moves=List.of(new double[]{0,0,0},new double[]{0,.5,0},new double[]{.005,0,0},
      new double[]{Math.nextDown(.005),0,0},new double[]{Math.nextUp(.005),0,0},
      new double[]{Math.nextDown(.005f),0,0},
      new double[]{.0049999997,0,0},new double[]{.0049999999,0,0},new double[]{.3,.4,0},
      new double[]{3,4,0},new double[]{-.3,-.4,-.2},new double[]{512,0,512},
      new double[]{.015,0,0},new double[]{.01,.02,.03});
    var cases=new JsonArray();
    for(int flags=0;flags<256;flags++)for(var move:moves){
      p.flags=flags;p.exhaustion=0;p.checkMovementStatistics(move[0],move[1],move[2]);
      var c=new JsonObject();c.addProperty("flags",flags);c.add("movement",new Gson().toJsonTree(move));c.addProperty("exhaustion",(double)p.exhaustion);cases.add(c);
    }
    var gates=new JsonArray();
    var cause=MethodHandles.privateLookupIn(Player.class,MethodHandles.lookup()).findSpecial(Player.class,"causeFoodExhaustion",MethodType.methodType(void.class,float.class),Player.class);
    var abilitiesField=Player.class.getDeclaredField("abilities");abilitiesField.setAccessible(true);
    var foodField=Player.class.getDeclaredField("foodData");foodField.setAccessible(true);
    var exhaustionField=FoodData.class.getDeclaredField("exhaustionLevel");exhaustionField.setAccessible(true);
    for(var mode:GameType.values())for(float amount:new float[]{0,.1f,4,6,40,Float.MAX_VALUE}){
      var abilities=new Abilities();mode.updatePlayerAbilities(abilities);abilitiesField.set(p,abilities);
      var food=new FoodData();foodField.set(p,food);cause.invoke(p,amount);
      var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("amount",(double)amount);c.addProperty("exhaustion",(double)exhaustionField.getFloat(food));gates.add(c);
    }
    var jumps=new JsonArray();
    for(boolean sprinting:new boolean[]{false,true}){
      p.flags=sprinting?64:0;p.exhaustion=0;p.jumpFromGround();
      var c=new JsonObject();c.addProperty("sprinting",sprinting);c.addProperty("exhaustion",(double)p.exhaustion);jumps.add(c);
    }
    var result=new JsonObject();result.add("movement",cases);result.add("gates",gates);result.add("jumps",jumps);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native travel requests, "+gates.size()+" real Player ability gates and "+jumps.size()+" ServerPlayer jump callbacks (physics/stats controlled); owner/world composition excluded.");
  }
}
