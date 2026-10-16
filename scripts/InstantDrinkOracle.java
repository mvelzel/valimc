import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.alchemy.PotionContents;
import net.minecraft.world.level.*;

/** Original native PotionContents callback probe, intercepting health requests only. */
public class InstantDrinkOracle {
  static class Body extends Player {
    DamageSources sources; ServerLevel level; JsonArray actions;
    private Body() { super(null, null); }
    public GameType gameMode() { return GameType.SURVIVAL; }
    public Level level() { return level; }
    public boolean isInvertedHealAndHarm() { return false; }
    public DamageSources damageSources() { return sources; }
    public void heal(float amount) {
      var action=new JsonArray(); action.add("heal"); action.add((double)amount); actions.add(action);
    }
    public boolean hurtServer(ServerLevel world, DamageSource source, float amount) {
      if(source.getEntity()!=this || source.getDirectEntity()!=this)
        throw new AssertionError("Drinking player source attribution lost");
      var action=new JsonArray(); action.add("hurt");
      action.add(source.typeHolder().unwrapKey().orElseThrow().identifier().getPath());
      action.add((double)amount); actions.add(action); return true;
    }
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup(); var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var registry=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var key:original.listElementIds().toList())registry.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);
    registry.freeze();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); field.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)field.get(null); var body=(Body)unsafe.allocateInstance(Body.class);
    body.level=(ServerLevel)unsafe.allocateInstance(ServerLevel.class);
    body.sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze());
    var rows=new JsonArray();
    for(var kind:List.of(MobEffects.INSTANT_HEALTH,MobEffects.INSTANT_DAMAGE))
      for(int amplifier=0;amplifier<=255;amplifier++)
        for(int duration:new int[]{-1,0,1,20,Integer.MAX_VALUE})
          for(float scale:new float[]{0,.5f,1,4}) {
            body.actions=new JsonArray();
            var contents=new PotionContents(Optional.empty(),Optional.empty(),
              List.of(new MobEffectInstance(kind,duration,amplifier)),Optional.empty());
            contents.applyToLivingEntity(body,scale);
            var row=new JsonObject(); row.addProperty("id",BuiltInRegistries.MOB_EFFECT.getId(kind.value()));
            row.addProperty("amplifier",amplifier); row.addProperty("duration",duration);
            row.addProperty("duration_scale",scale); row.add("actions",body.actions); rows.add(row);
          }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native player drink heal/harm requests, all256 amplifiers, duration/scale independence and self-attributed indirect magic; downstream health/death/consumption excluded.");
  }
}
