import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;

/** Real instance refresh and server-duration transitions; fire resistance avoids periodic actions. */
public class StatusEffectOracle {
  static Field hidden;
  static MobEffectInstance effect(int ticks,int level,int flags){return new MobEffectInstance(MobEffects.FIRE_RESISTANCE,ticks,level,(flags&1)!=0,(flags&2)!=0,(flags&4)!=0);}
  static JsonArray state(MobEffectInstance effect)throws Exception {
    var result=new JsonArray();int count=0;
    while(effect!=null){
      if(++count>256)throw new AssertionError("Unbounded stock amplifier chain");
      var node=new JsonArray();node.add(effect.getDuration());node.add(effect.getAmplifier());node.add(effect.isAmbient());node.add(effect.isVisible());node.add(effect.showIcon());result.add(node);
      effect=(MobEffectInstance)hidden.get(effect);
    }
    return result;
  }
  static JsonObject update(MobEffectInstance current,MobEffectInstance incoming)throws Exception {
    var row=new JsonObject();row.addProperty("op","update");row.add("input",state(incoming));row.addProperty("changed",current.update(incoming));row.add("state",state(current));return row;
  }
  static JsonObject tick(MobEffectInstance current,FireContactOracle.Body body,int count)throws Exception {
    var row=new JsonObject();row.addProperty("op","tick");row.addProperty("count",count);int[] promotions={0};boolean remains=false;
    for(int i=0;i<count;i++){body.tickCount++;remains=current.tickServer(null,body,()->promotions[0]++);}
    row.addProperty("remains",remains);row.addProperty("promotions",promotions[0]);row.add("state",state(current));return row;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();hidden=MobEffectInstance.class.getDeclaredField("hiddenEffect");hidden.setAccessible(true);
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var u=(sun.misc.Unsafe)field.get(null);
    var body=(FireContactOracle.Body)u.allocateInstance(FireContactOracle.Body.class);var rows=new JsonArray();
    int[] durations={-1,0,1,2,20,200,Integer.MAX_VALUE};int[] levels={0,1,2,255};
    for(int duration:durations)for(int level:levels)for(int flags=0;flags<8;flags++)for(int nextDuration:durations)for(int nextLevel:levels)for(int nextFlags=0;nextFlags<8;nextFlags++){
      var current=effect(duration,level,flags);var row=new JsonObject();row.add("initial",state(current));var operations=new JsonArray();operations.add(update(current,effect(nextDuration,nextLevel,nextFlags)));operations.add(tick(current,body,3));row.add("operations",operations);rows.add(row);
    }
    var random=new Random(262603);for(int trace=0;trace<256;trace++){
      var current=effect(200,0,0);var row=new JsonObject();row.add("initial",state(current));var operations=new JsonArray();
      for(int step=0;step<32;step++)if(random.nextBoolean())operations.add(update(current,effect(durations[random.nextInt(durations.length)],levels[random.nextInt(levels.length)],random.nextInt(8))));else operations.add(tick(current,body,1+random.nextInt(25)));
      row.add("operations",operations);rows.add(row);
    }
    var current=effect(-1,0,0);var deep=new JsonObject();deep.add("initial",state(current));var ops=new JsonArray();
    for(int level=1;level<=255;level++)ops.add(update(current,effect(256-level,level,7)));
    ops.add(tick(current,body,256));deep.add("operations",ops);rows.add(deep);
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",rows);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+rows.size()+" native status instance traces: all flags, finite/infinite refresh, hidden chains through256 amplifiers, mixed server ticks and promotion callbacks. Gameplay actions/attributes/client/persistence excluded.");
  }
}
