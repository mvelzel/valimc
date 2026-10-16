import com.google.gson.*;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.consume_effects.*;

/** Original stock milk/honey callback observations on the actual LivingEntity effect map. */
public class ConsumableRemovalOracle {
  static class Body extends LivingEntity {
    ServerLevel world; List<Integer> removed;
    private Body(){super(EntityTypes.ARMOR_STAND,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public ServerLevel level(){return world;}
    protected void onEffectsRemoved(Collection<MobEffectInstance> effects){for(var effect:effects)removed.add(BuiltInRegistries.MOB_EFFECT.getId(effect.getEffect().value()));}
  }
  static Field hidden;
  static JsonArray state(Body body)throws Exception {
    var rows=new JsonArray();
    for(var effect:body.getActiveEffects().stream().sorted(Comparator.comparingInt(e->BuiltInRegistries.MOB_EFFECT.getId(e.getEffect().value()))).toList()){
      var row=new JsonObject();row.addProperty("id",BuiltInRegistries.MOB_EFFECT.getId(effect.getEffect().value()));var rungs=new JsonArray();
      for(var current=effect;current!=null;current=(MobEffectInstance)hidden.get(current)){
        var rung=new JsonArray();rung.add(current.getDuration());rung.add(current.getAmplifier());rung.add(current.isAmbient());rung.add(current.isVisible());rung.add(current.showIcon());rungs.add(rung);
      }
      row.add("rungs",rungs);rows.add(row);
    }
    return rows;
  }
  static void observe(JsonArray rows,Body body,Item item,List<Holder<MobEffect>> kinds,int duration,boolean suppressed)throws Exception {
    var active=body.getActiveEffectsMap();active.clear();body.removed=new ArrayList<>();
    for(var kind:kinds){var effect=new MobEffectInstance(kind,duration,0);if(suppressed)effect.update(new MobEffectInstance(kind,1,255));active.put(kind,effect);}
    var row=new JsonObject();row.addProperty("item",BuiltInRegistries.ITEM.getKey(item).toString());row.add("initial",state(body));
    var callbacks=item.components().get(DataComponents.CONSUMABLE).onConsumeEffects();
    if(callbacks.size()!=1)throw new AssertionError("Unexpected stock effect count");
    boolean changed=callbacks.getFirst().apply(null,new ItemStack(item),body);
    Collections.sort(body.removed);row.addProperty("changed",changed);row.add("removed",new Gson().toJsonTree(body.removed));row.add("next",state(body));rows.add(row);
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    var body=(Body)unsafe.allocateInstance(Body.class);body.world=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    var active=LivingEntity.class.getDeclaredField("activeEffects");active.setAccessible(true);active.set(body,new HashMap<Holder<MobEffect>,MobEffectInstance>());
    hidden=MobEffectInstance.class.getDeclaredField("hiddenEffect");hidden.setAccessible(true);
    var facts=new JsonArray();var rows=new JsonArray();var all=BuiltInRegistries.MOB_EFFECT.listElements().map(e->(Holder<MobEffect>)e).toList();
    for(var item:List.of(Items.MILK_BUCKET,Items.HONEY_BOTTLE)){
      var stack=new ItemStack(item);var c=stack.get(DataComponents.CONSUMABLE);var callback=c.onConsumeEffects().getFirst();String policy;
      if(callback instanceof ClearAllStatusEffectsConsumeEffect)policy="all";
      else if(callback instanceof RemoveStatusEffectsConsumeEffect remove && remove.effects().size()==1 && remove.effects().contains(MobEffects.POISON))policy="poison";
      else throw new AssertionError("Unexpected removal callback: "+callback);
      var fact=new JsonObject();fact.addProperty("item",BuiltInRegistries.ITEM.getKey(item).toString());fact.addProperty("policy",policy);fact.addProperty("ticks",c.consumeTicks());facts.add(fact);
      observe(rows,body,item,List.of(),0,false);
      for(var kind:all)for(int duration:new int[]{-1,0,1,600})for(boolean suppressed:new boolean[]{false,true})observe(rows,body,item,List.of(kind),duration,suppressed);
      for(int duration:new int[]{-1,0,1,600})for(boolean suppressed:new boolean[]{false,true})observe(rows,body,item,all,duration,suppressed);
    }
    var out=new JsonObject();out.add("facts",facts);out.add("cases",rows);Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+rows.size()+" actual milk/honey stock callbacks, all40 native map entries, empty/finite/zero/infinite/hidden state and removed callbacks; consumption/health/persistence/client excluded.");
  }
}
