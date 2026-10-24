import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.decoration.ArmorStand;
import net.minecraft.world.entity.monster.Guardian;

/** Native guardian hurt attempts; retaliation is observed independently of damage admission. */
public class GuardianHurtOracle {
  static List<Float> standHits;
  static class Stand extends ArmorStand {
    Stand(net.minecraft.world.level.Level level) { super(level,0,64,0); }
    public boolean hurtServer(ServerLevel level, DamageSource source, float amount) { standHits.add(amount); return true; }
  }
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var damage = MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup);
    try (var resources = new net.minecraft.server.packs.resources.MultiPackResourceManager(
      net.minecraft.server.packs.PackType.SERVER_DATA,
      List.of(net.minecraft.server.packs.repository.ServerPacksSource.createVanillaPackSource().fullResources()))) {
      MobAiOracle.bind(resources,damage);
    }
    var registries = new ArrayList<Registry<?>>(); registries.add(damage); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup,access,new DamageSources(access));
    var moving = Guardian.class.getDeclaredMethod("setMoving",boolean.class); moving.setAccessible(true);
    var cases = new JsonArray();
    for (var type : List.of("guardian","elder_guardian")) for (boolean move : List.of(false,true))
      for (var directType : List.of("player","armor_stand","arrow")) for (var source : List.of("player_attack","thorns","on_fire")) {
        var guardian = (Guardian)MobAiOracle.mob("minecraft:"+type,level); moving.invoke(guardian,move);
        var player = new MobAiOracle.Fighter(level,1,net.minecraft.world.level.GameType.SURVIVAL);
        standHits = new ArrayList<>();
        Entity direct = switch (directType) {
          case "armor_stand" -> new Stand(level);
          case "arrow" -> EntityTypes.ARROW.create(level,EntitySpawnReason.COMMAND);
          default -> player;
        };
        var kind = damage.getOrThrow(ResourceKey.create(Registries.DAMAGE_TYPE,Identifier.withDefaultNamespace(source)));
        var hit = new DamageSource(kind,direct,player);
        var row = new JsonObject(); row.addProperty("type","minecraft:"+type); row.addProperty("moving",move);
        row.addProperty("direct","minecraft:"+directType); row.addProperty("source",source);
        var trace = new JsonArray();
        for (int i=0;i<2;i++) {
          boolean accepted = guardian.hurtServer(level,hit,1F);
          var step = new JsonObject(); step.addProperty("accepted",accepted); step.addProperty("health",guardian.getHealth());
          step.addProperty("thorns",directType.equals("armor_stand") ? standHits.size() : player.hits.size());
          trace.add(step);
        }
        row.add("trace",trace); cases.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(cases)+"\n");
    System.out.println("PASS: native guardian hurt-attempt cases: "+cases.size());
  }
}
