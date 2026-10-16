import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.RandomSource;
import net.minecraft.world.effect.MobEffectInstance;
import net.minecraft.world.entity.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.consume_effects.ApplyStatusEffectsConsumeEffect;

/** Original stock callback facts and actual chance/group/copy observations; no effect gameplay. */
public class ConsumeStatusOracle {
  static class Body extends LivingEntity {
    RandomSource random; float draw; int draws; boolean accepts;
    List<MobEffectInstance> calls;
    private Body(){super(EntityTypes.ARMOR_STAND,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public RandomSource getRandom(){return random;}
    public boolean addEffect(MobEffectInstance effect,Entity source){calls.add(effect);return accepts;}
  }
  static JsonObject effect(MobEffectInstance effect){
    var row=new JsonObject();row.addProperty("id",BuiltInRegistries.MOB_EFFECT.getId(effect.getEffect().value()));
    var rung=new JsonArray();rung.add(effect.getDuration());rung.add(effect.getAmplifier());rung.add(effect.isAmbient());rung.add(effect.isVisible());rung.add(effect.showIcon());row.add("rung",rung);return row;
  }
  static JsonArray effects(List<MobEffectInstance> effects){var rows=new JsonArray();effects.forEach(e->rows.add(effect(e)));return rows;}
  static void observe(JsonArray rows,Body body,String name,ItemStack stack,ApplyStatusEffectsConsumeEffect callback){
    var draws=new LinkedHashSet<Float>(List.of(0f,Math.nextDown(callback.probability()),callback.probability(),Math.nextUp(callback.probability()),.3f,.8f,Math.nextDown(1f)));
    for(float draw:draws)if(draw>=0&&draw<1)for(boolean accepts:new boolean[]{false,true}){
      body.draw=draw;body.draws=0;body.accepts=accepts;body.calls=new ArrayList<>();
      boolean changed=callback.apply(null,stack,body);var first=new ArrayList<>(body.calls);
      for(int i=0;i<first.size();i++)if(first.get(i)==callback.effects().get(i))throw new AssertionError("Shared stock effect instance");
      var row=new JsonObject();row.addProperty("item",name);row.addProperty("probability",(double)callback.probability());row.addProperty("draw",(double)draw);row.addProperty("accepts",accepts);row.addProperty("changed",changed);row.addProperty("draws",body.draws);row.add("expected_effects",effects(callback.effects()));row.add("calls",effects(body.calls));rows.add(row);
      body.calls=new ArrayList<>();callback.apply(null,stack,body);
      for(int i=0;i<first.size();i++)if(first.get(i)==body.calls.get(i))throw new AssertionError("Reused completed-meal instance");
    }
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var body=(Body)((sun.misc.Unsafe)f.get(null)).allocateInstance(Body.class);
    body.random=(RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,a)->{if(!method.getName().equals("nextFloat"))throw new AssertionError(method);body.draws++;return body.draw;});
    var facts=new JsonArray();var rows=new JsonArray();
    for(var item:BuiltInRegistries.ITEM){
      var stack=new ItemStack(item);var consumable=stack.get(DataComponents.CONSUMABLE);
      if(consumable==null||consumable.onConsumeEffects().isEmpty()||!consumable.onConsumeEffects().stream().allMatch(e->e instanceof ApplyStatusEffectsConsumeEffect))continue;
      String name=BuiltInRegistries.ITEM.getKey(item).toString();var callbacks=new JsonArray();
      for(var effect:consumable.onConsumeEffects()){
        var apply=(ApplyStatusEffectsConsumeEffect)effect;var callback=new JsonObject();callback.addProperty("probability",(double)apply.probability());callback.add("effects",effects(apply.effects()));callbacks.add(callback);observe(rows,body,name,stack,apply);
      }
      var fact=new JsonObject();fact.addProperty("item",name);fact.addProperty("item_id",BuiltInRegistries.ITEM.getId(item));fact.add("callbacks",callbacks);facts.add(fact);
    }
    for(float probability:new float[]{0,.3f,.8f,1})observe(rows,body,"synthetic_empty",ItemStack.EMPTY,new ApplyStatusEffectsConsumeEffect(List.of(),probability));
    var metadata=new JsonObject();metadata.addProperty("version","26.3");metadata.addProperty("protocol",777);metadata.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");metadata.add("items",facts);
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(metadata)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+facts.size()+" stock apply-status food facts and "+rows.size()+" actual callback probability/group/order/copy cases; effect admission/gameplay, food, inventory and live owners excluded.");
  }
}
