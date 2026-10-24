import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.core.Holder;
import net.minecraft.core.component.DataComponents;

/** Native held-item/effect modifiers and exact attack-speed evaluation. */
public class AttackSpeedOracle {
  static class Strength extends Player {
    double attackSpeed;
    Strength() { super(null,null); }
    public double getAttributeValue(Holder<Attribute> attribute) { return attackSpeed; }
    public net.minecraft.world.level.GameType gameMode() { return net.minecraft.world.level.GameType.SURVIVAL; }
  }
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var supplier = Player.createAttributes().build();
    var order = AttributeInstance.class.getDeclaredMethod("getModifiersOrEmpty",AttributeModifier.Operation.class);
    order.setAccessible(true);
    var unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var ticker = MobAiOracle.field(LivingEntity.class,"attackStrengthTicker");
    var rows = new JsonArray();
    for (var item : List.of(Items.AIR,Items.STONE,Items.WOODEN_SWORD,Items.IRON_SWORD,Items.DIAMOND_SWORD,
      Items.WOODEN_AXE,Items.STONE_AXE,Items.IRON_AXE,Items.DIAMOND_AXE,Items.NETHERITE_HOE,Items.MACE,Items.TRIDENT))
      for (int haste : new int[] {-1,0,1,4,255}) for (int fatigue : new int[] {-1,0,1,3,9,255})
      for (var slot : List.of(EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND)) {
        var attributes = new AttributeMap(supplier);
        var speed = attributes.getInstance(Attributes.ATTACK_SPEED);
        var stack = item == Items.AIR ? ItemStack.EMPTY : new ItemStack(item);
        stack.forEachModifier(slot,(attribute,modifier) -> {
          if (attribute == Attributes.ATTACK_SPEED) speed.addTransientModifier(modifier);
        });
        if (haste >= 0) MobEffects.HASTE.value().addAttributeModifiers(attributes,haste);
        if (fatigue >= 0) MobEffects.MINING_FATIGUE.value().addAttributeModifiers(attributes,fatigue);
        var row = new JsonObject(); row.addProperty("item",BuiltInRegistries.ITEM.getKey(item).toString());
        row.addProperty("mainhand",slot == EquipmentSlot.MAINHAND); row.addProperty("haste",haste); row.addProperty("fatigue",fatigue);
        row.addProperty("id",BuiltInRegistries.ATTRIBUTE.getId(Attributes.ATTACK_SPEED.value()));
        row.addProperty("base",speed.getBaseValue()); row.addProperty("value",NaturalSpawnOracle.bits(speed.getValue()));
        var modifiers = new JsonArray();
        for (var modifier : speed.getModifiers()) {
          var m = new JsonArray(); m.add(modifier.id().toString()); m.add(modifier.amount()); m.add(modifier.operation().ordinal()); modifiers.add(m);
        }
        row.add("modifiers",modifiers);
        var evaluation = new JsonArray();
        for (var modifier : (Collection<?>)order.invoke(speed,AttributeModifier.Operation.ADD_MULTIPLIED_TOTAL))
          evaluation.add(((AttributeModifier)modifier).id().toString());
        row.add("evaluation",evaluation); rows.add(row);
        var player = (Strength)unsafe.allocateInstance(Strength.class); player.attackSpeed = speed.getValue();
        row.addProperty("delay",Float.floatToRawIntBits(player.getCurrentItemAttackStrengthDelay()));
        var charged = new ItemStack(Items.STONE); charged.set(DataComponents.MINIMUM_ATTACK_CHARGE,.25F);
        var strengths = new JsonArray();
        for (int ticks : new int[] {0,1,5,20,100}) for (float partial : new float[] {0,.5F}) {
          ticker.setInt(player,ticks);
          var sample = new JsonArray(); sample.add(ticks); sample.add((double)partial);
          sample.add(Float.floatToRawIntBits(player.getAttackStrengthScale(partial)));
          sample.add(player.cannotAttackWithItem(charged,2)); strengths.add(sample);
        }
        row.add("strengths",strengths);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(rows)+"\n");
    System.out.println("PASS: native player attack speed cases: "+rows.size());
  }
}
