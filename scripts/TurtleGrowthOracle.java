import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.function.BiConsumer;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.resources.ResourceKey;
import net.minecraft.resources.Identifier;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.turtle.Turtle;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.gamerules.GameRules;
import net.minecraft.world.level.storage.loot.LootTable;

/** Native age-boundary dispatch: intercept only its gift request, not ageing or the callback. */
public class TurtleGrowthOracle {
  static class Growing extends Turtle {
    List<String> gifts = new ArrayList<>();
    Growing(ServerLevel level) {
      super((EntityType<? extends Turtle>)BuiltInRegistries.ENTITY_TYPE.getValue(Identifier.parse("minecraft:turtle")), level);
    }
    @Override public boolean dropFromGiftLootTable(ServerLevel level, ResourceKey<LootTable> key,
        BiConsumer<ServerLevel, ItemStack> consumer) {
      gifts.add(key.identifier().toString()); return true;
    }
  }
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup,access,new net.minecraft.world.damagesource.DamageSources(access));
    var locked = AgeableMob.class.getDeclaredMethod("setAgeLocked",boolean.class); locked.setAccessible(true);
    var rows = new JsonArray();
    for (int age : new int[] {-2,-1,0,1}) for (boolean lock : List.of(false,true))
      for (boolean drops : List.of(false,true)) for (boolean noAi : List.of(false,true)) {
        level.rules.set(GameRules.MOB_DROPS,drops,null);
        var mob = new Growing(level); mob.setNoGravity(true); mob.setNoAi(noAi); mob.setPos(.5,64,.5);
        mob.setAge(age); locked.invoke(mob,lock); mob.gifts.clear();
        var row = new JsonObject(); row.addProperty("age",age); row.addProperty("locked",lock);
        row.addProperty("drops",drops); row.addProperty("no_ai",noAi);
        var trace = new JsonArray();
        for (int tick=0; tick<4; tick++) {
          mob.gifts.clear(); mob.aiStep();
          var at = new JsonObject(); at.addProperty("age",mob.getAge());
          at.add("gifts",new Gson().toJsonTree(mob.gifts)); trace.add(at);
        }
        row.add("trace",trace); rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(rows)+"\n");
    System.out.println("PASS: native turtle age-boundary traces: "+rows.size());
  }
}
