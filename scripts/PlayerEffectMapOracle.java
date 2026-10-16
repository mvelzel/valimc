import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;

/** Native map membership/refresh/clock notifications, with inert effects and controlled callbacks. */
public class PlayerEffectMapOracle {
  static class Body extends LivingEntity {
    ServerLevel world; JsonArray events;
    private Body(){super(EntityTypes.ARMOR_STAND,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public ServerLevel level(){return world;}
    public boolean canBeAffected(MobEffectInstance effect){return true;}
    public boolean isDeadOrDying(){return false;}
    void advance(){tickCount++;tickEffects();}
    void event(String kind,MobEffectInstance effect,boolean reset){var row=new JsonArray();row.add(kind);row.add(BuiltInRegistries.MOB_EFFECT.getId(effect.getEffect().value()));row.add(reset);events.add(row);}
    protected void onEffectAdded(MobEffectInstance effect,Entity source){event("add",effect,false);}
    protected void onEffectUpdated(MobEffectInstance effect,boolean reset,Entity source){event("update",effect,reset);}
    protected void onEffectsRemoved(Collection<MobEffectInstance> removed){for(var effect:removed)event("remove",effect,false);}
  }
  static Holder<MobEffect> holder(int id){return BuiltInRegistries.MOB_EFFECT.get(id).orElseThrow();}
  static JsonArray state(Body body)throws Exception {
    var rows=new JsonArray();
    for(var effect:body.getActiveEffects().stream().sorted(Comparator.comparingInt(e->BuiltInRegistries.MOB_EFFECT.getId(e.getEffect().value()))).toList()){
      var row=new JsonObject();row.addProperty("id",BuiltInRegistries.MOB_EFFECT.getId(effect.getEffect().value()));row.add("rungs",StatusEffectOracle.state(effect));rows.add(row);
    }
    return rows;
  }
  static JsonObject operation(Body body,String kind,int id,int ticks,int amplifier,int flags)throws Exception {
    body.events=new JsonArray();var row=new JsonObject();row.addProperty("op",kind);row.addProperty("id",id);
    switch(kind){
      case "add" -> {row.addProperty("ticks",ticks);row.addProperty("amplifier",amplifier);row.addProperty("flags",flags);row.addProperty("changed",body.addEffect(new MobEffectInstance(holder(id),ticks,amplifier,(flags&1)!=0,(flags&2)!=0,(flags&4)!=0)));}
      case "remove" -> row.addProperty("changed",body.removeEffect(holder(id)));
      case "tick" -> body.advance();
      default -> throw new AssertionError(kind);
    }
    row.add("state",state(body));row.add("events",body.events);return row;
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();StatusEffectOracle.hidden=MobEffectInstance.class.getDeclaredField("hiddenEffect");StatusEffectOracle.hidden.setAccessible(true);
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var u=(sun.misc.Unsafe)field.get(null);
    var body=(Body)u.allocateInstance(Body.class);body.world=(ServerLevel)u.allocateInstance(ServerLevel.class);
    var active=LivingEntity.class.getDeclaredField("activeEffects");active.setAccessible(true);active.set(body,new HashMap<Holder<MobEffect>,MobEffectInstance>());
    var rows=new JsonArray();int[] durations={-1,0,1,2,20,599,600,601,1201,Integer.MAX_VALUE};int[] levels={0,1,2,255};
    // Explicit heartbeat, promotion-at-heartbeat, expiration, unrelated effect and duplicate removal.
    var targeted=new JsonArray();
    targeted.add(operation(body,"add",11,601,0,7));targeted.add(operation(body,"add",11,1,1,0));
    targeted.add(operation(body,"add",12,0,0,7));
    for(int i=0;i<4;i++)targeted.add(operation(body,"tick",0,0,0,0));
    targeted.add(operation(body,"remove",11,0,0,0));targeted.add(operation(body,"remove",11,0,0,0));rows.add(targeted);
    var random=new Random(263037);for(int trace=0;trace<128;trace++){
      body.getActiveEffectsMap().clear();var ops=new JsonArray();
      for(int step=0;step<64;step++){
        int id=random.nextBoolean()?11:12;int action=random.nextInt(8);
        ops.add(operation(body,action<3?"add":action==3?"remove":"tick",id,durations[random.nextInt(durations.length)],levels[random.nextInt(levels.length)],random.nextInt(8)));
      }
      rows.add(ops);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("traces",rows);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+rows.size()+" native LivingEntity map traces, refresh/expiry/removal and exact promotion/600-tick callbacks. Inert Fire Resistance/Water Breathing; application eligibility, actions, attributes, persistence and client excluded.");
  }
}
