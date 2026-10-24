import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.particles.*;
import net.minecraft.core.registries.*;
import net.minecraft.network.protocol.game.*;
import net.minecraft.sounds.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.projectile.ShulkerBullet;
import net.minecraft.world.phys.*;

/** Native terminal callbacks, with their actual sound and particle packet payloads. */
public class ShulkerBulletHurtOracle {
  static class Probe extends MobAiOracle.Probe {
    JsonArray packets;
    public void playSeededSound(Entity e, double x, double y, double z, Holder<SoundEvent> sound, SoundSource source, float volume, float pitch, long seed) {
      packets.add(CombatOracle.wire(access,new ClientboundSoundPacket(sound,source,x,y,z,volume,pitch,0)));
    }
    public <T extends ParticleOptions> int sendParticles(T options,double x,double y,double z,int count,double dx,double dy,double dz,double speed) {
      packets.add(CombatOracle.wire(access,new ClientboundLevelParticlesPacket(options,false,false,x,y,z,(float)dx,(float)dy,(float)dz,(float)speed,count)));
      return 1;
    }
  }
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(Probe.class,lookup,access,new net.minecraft.world.damagesource.DamageSources(access));
    var blockHit = ShulkerBullet.class.getDeclaredMethod("onHit",HitResult.class); blockHit.setAccessible(true);
    var rows = new JsonArray();
    for (var at : List.of(new Vec3(.5,64,.5),new Vec3(-16.125,72.5,127.875)))
      for (var mode : List.of("hurt","block","block_tick")) for (float amount : new float[] {0,1,20}) {
        var bullet = (ShulkerBullet)EntityTypes.SHULKER_BULLET.create(level,EntitySpawnReason.COMMAND);
        bullet.setPos(at); level.packets = new JsonArray(); level.blocks.clear();
        boolean accepted = true;
        if (mode.equals("hurt")) accepted = bullet.hurtServer(level,level.sources.generic(),amount);
        else if (mode.equals("block_tick")) {
          bullet.setNoGravity(true); bullet.setDeltaMovement(.8,0,0);
          level.blocks.put(BlockPos.containing(at.add(1,0,0)),net.minecraft.world.level.block.Blocks.STONE.defaultBlockState());
          bullet.tick();
        } else blockHit.invoke(bullet,new BlockHitResult(at,Direction.WEST,BlockPos.containing(at),false));
        var row = new JsonObject(); row.addProperty("mode",mode); row.addProperty("amount",amount);
        row.add("position",ShulkerBodyBoxOracle.point(at)); row.addProperty("accepted",accepted);
        row.addProperty("removed",bullet.isRemoved()); row.add("packets",level.packets); rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(rows)+"\n");
    System.out.println("PASS: native shulker bullet terminal feedback cases: "+rows.size());
  }
}
