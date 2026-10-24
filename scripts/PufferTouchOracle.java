import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.ClientboundGameEventPacket;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.MobEffectInstance;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.fish.Pufferfish;

/** Native playerTouch with an explicit player damage decision and captured player packets. */
public class PufferTouchOracle {
  static MobAiOracle.Probe level;
  static boolean accepted;
  static Float damage;
  static JsonArray effects, packets;
  static class Player extends ServerPlayer {
    private Player() { super(null, null, null, null); }
    public ServerLevel level() { return level; }
    public net.minecraft.world.scores.PlayerTeam getTeam() { return null; }
    public boolean hurtServer(ServerLevel level, DamageSource source, float amount) { damage = amount; return accepted; }
    public boolean addEffect(MobEffectInstance effect, Entity source) {
      var row = new JsonArray(); row.add(BuiltInRegistries.MOB_EFFECT.getKey(effect.getEffect().value()).toString());
      row.add(effect.getDuration()); row.add(effect.getAmplifier()); effects.add(row); return true;
    }
  }
  static class Listener extends ServerGamePacketListenerImpl {
    private Listener() { super(null, null, null, null); }
    public void send(Packet<?> packet) {
      if (!(packet instanceof ClientboundGameEventPacket event)) throw new AssertionError(packet);
      var buf = new FriendlyByteBuf(Unpooled.buffer());
      try { ClientboundGameEventPacket.STREAM_CODEC.encode(buf, event);
        var bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes); packets.add(HexFormat.of().formatHex(bytes));
      } finally { buf.release(); }
    }
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class, "theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE, lookup));
    BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    level = MobAiOracle.probe(lookup, access, new DamageSources(access));
    var player = (Player)MobAiOracle.unsafe.allocateInstance(Player.class);
    player.connection = (Listener)MobAiOracle.unsafe.allocateInstance(Listener.class);
    var fish = (Pufferfish)MobAiOracle.mob("minecraft:pufferfish", level);
    var cases = new JsonArray();
    for (int puff = 0; puff <= 2; puff++) for (boolean take : List.of(false, true)) {
      accepted = take; damage = null; effects = new JsonArray(); packets = new JsonArray();
      fish.setPuffState(puff); fish.playerTouch(player);
      var row = new JsonObject(); row.addProperty("puff", puff); row.addProperty("accepted", take);
      row.addProperty("damage", damage); row.add("effects", effects); row.add("packets", packets); cases.add(row);
    }
    Files.writeString(Path.of(args[0]), new GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(cases) + "\n");
    System.out.println("PASS: native pufferfish player contact cases: " + cases.size());
  }
}
