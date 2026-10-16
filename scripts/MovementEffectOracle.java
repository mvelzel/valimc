import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;

/** Original probe of native effect modifier creation, attribute evaluation and removal. */
public class MovementEffectOracle {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var supplier = Player.createAttributes().build();
    var sprintField = LivingEntity.class.getDeclaredField("SPEED_MODIFIER_SPRINTING");
    sprintField.setAccessible(true);
    var sprintModifier = (AttributeModifier) sprintField.get(null);
    var orderMethod = AttributeInstance.class.getDeclaredMethod("getModifiersOrEmpty", AttributeModifier.Operation.class);
    orderMethod.setAccessible(true);
    var orders = new TreeSet<String>();
    var rows = new JsonArray();
    // Observe native evaluation order independently of callback insertion order.
    for (int speed = -1; speed <= 255; speed++) for (int slow = -1; slow <= 255; slow++)
      for (boolean sprint : new boolean[]{false, true}) {
        var attributes = new AttributeMap(supplier);
        var movement = attributes.getInstance(Attributes.MOVEMENT_SPEED);
        if (speed >= 0) MobEffects.SPEED.value().addAttributeModifiers(attributes, speed);
        if (slow >= 0) MobEffects.SLOWNESS.value().addAttributeModifiers(attributes, slow);
        if (sprint) movement.addOrUpdateTransientModifier(sprintModifier);
        var row = new JsonObject();
        row.addProperty("speed", speed); row.addProperty("slowness", slow);
        row.addProperty("sprint", sprint); row.addProperty("base", movement.getBaseValue());
        row.addProperty("value", movement.getValue());
        row.addProperty("travel_speed", (double)(float)movement.getValue());
        var modifiers = new JsonArray();
        for (var modifier : movement.getModifiers()) {
          var item = new JsonArray(); item.add(modifier.id().toString());
          item.add(modifier.amount()); item.add(modifier.operation().ordinal());
          modifiers.add(item);
        }
        row.add("modifiers", modifiers);
        var evaluation = new JsonArray();
        for (var modifier : (Collection<?>)orderMethod.invoke(movement, AttributeModifier.Operation.ADD_MULTIPLIED_TOTAL))
          evaluation.add(((AttributeModifier)modifier).id().toString());
        row.add("evaluation_order", evaluation); orders.add(evaluation.toString());
        MobEffects.SPEED.value().removeAttributeModifiers(attributes);
        MobEffects.SLOWNESS.value().removeAttributeModifiers(attributes);
        row.addProperty("removed", movement.getValue());
        rows.add(row);
      }
    Files.writeString(Path.of(args[0]), new Gson().toJson(rows));
    System.out.println("Native evaluation orders: " + orders);
    System.out.println("PASS: " + rows.size() + " native Speed/Slowness amplifier pairs, sprint, player-base/clamp, modifier identities and removal; live movement excluded.");
  }
}
