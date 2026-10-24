import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.monster.Endermite;

/** The native subclass lifecycle, including NoAI and stored boundary values. */
public class EndermiteLifeOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup,access,new net.minecraft.world.damagesource.DamageSources(access));
    var life = MobAiOracle.field(Endermite.class,"life");
    var cases = new JsonArray();
    for (int initial : new int[] {0,2398,2399,2400,2401}) for (boolean persistent : List.of(false,true)) {
      var mob = (Endermite)MobAiOracle.mob("minecraft:endermite",level);
      mob.setNoAi(true); mob.setNoGravity(true); mob.setPos(.5,64,.5);
      if (persistent) mob.setPersistenceRequired();
      life.setInt(mob,initial);
      var row = new JsonObject(); row.addProperty("initial",initial); row.addProperty("persistent",persistent);
      var trace = new JsonArray();
      for (int tick=0; tick<8; tick++) {
        mob.aiStep();
        var at = new JsonObject(); at.addProperty("life",life.getInt(mob)); at.addProperty("removed",mob.isRemoved()); trace.add(at);
        if (mob.isRemoved()) break;
      }
      row.add("trace",trace); cases.add(row);
    }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(cases)+"\n");
    System.out.println("PASS: native NoAI endermite lifetime traces: "+cases.size());
  }
}
