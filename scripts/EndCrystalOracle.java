import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.particles.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.protocol.game.ClientboundSetEntityDataPacket;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.boss.enderdragon.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.context.UseOnContext;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.*;

/** Original probes of native crystal use, damage and packets (VMC-045a1). */
public class EndCrystalOracle {
  static class Context extends UseOnContext {
    Context(Level level, ItemStack stack, BlockPos pos, Direction face) {
      super(level, null, InteractionHand.MAIN_HAND, stack,
          new BlockHitResult(Vec3.atCenterOf(pos), face, pos, false));
    }
  }
  static class Probe extends MobAiOracle.Probe {
    List<Entity> placed;
    int explosions;
    float power;
    Probe() { super(); }
    public boolean addFreshEntity(Entity e) { placed.add(e); return true; }
    @Override public void explode(Entity source, DamageSource damage, ExplosionDamageCalculator calculator,
        double x, double y, double z, float radius, boolean fire, Level.ExplosionInteraction interaction,
        ParticleOptions small, ParticleOptions large,
        net.minecraft.util.random.WeightedList<ExplosionParticleInfo> particles, Holder<SoundEvent> sound) {
      explosions++; power = radius;
    }
  }
  static JsonArray vector(double... v) {
    var out = new JsonArray(); for (var x : v) out.add(x); return out;
  }
  static JsonObject placement(Probe level) {
    var result = new JsonObject(); var cases = new JsonArray();
    for (var base : List.of(Blocks.OBSIDIAN, Blocks.BEDROCK, Blocks.STONE))
      for (var above : List.of(Blocks.AIR, Blocks.CAVE_AIR, Blocks.FIRE, Blocks.WATER, Blocks.STONE))
        for (var face : Direction.values())
          for (double offset : new double[]{-2, -.5, 0, 1, 1.5, 2}) {
            var pos = new BlockPos(-3, 70, 4);
            level.blocks.clear(); level.entities.clear(); level.placed.clear();
            level.blocks.put(pos, base.defaultBlockState());
            level.blocks.put(pos.above(), above.defaultBlockState());
            // The cell two above need not be air; only entities there obstruct.
            level.blocks.put(pos.above(2), Blocks.STONE.defaultBlockState());
            var blocker = new EndCrystal(level, pos.getX() + offset, pos.getY() + 1, pos.getZ() + .5);
            level.entities.add(blocker);
            var stack = new ItemStack(Items.END_CRYSTAL, 2);
            ((EndCrystalItem)Items.END_CRYSTAL).useOn(new Context(level, stack, pos, face));
            var row = new JsonObject();
            row.addProperty("base", net.minecraft.world.level.block.Block.getId(base.defaultBlockState()));
            row.addProperty("above", net.minecraft.world.level.block.Block.getId(above.defaultBlockState()));
            row.addProperty("face", face.get3DDataValue());
            var b = blocker.getBoundingBox();
            row.add("box", vector(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ));
            row.addProperty("placed", !level.placed.isEmpty()); row.addProperty("count", stack.getCount());
            if (!level.placed.isEmpty()) {
              var c = (EndCrystal)level.placed.getFirst();
              row.add("position", vector(c.getX(),c.getY(),c.getZ())); row.addProperty("bottom",c.showsBottom());
            }
            cases.add(row);
          }
    result.add("placement", cases); return result;
  }
  public static void main(String[] args) throws Exception {
    var level = MobAiOracle.setup(Probe.class);
    level.placed = new ArrayList<>();
    var out = placement(level);
    var damage = new JsonArray();
    var dragon = new EnderDragon(EntityTypes.ENDER_DRAGON, level);
    var sources = new LinkedHashMap<String,DamageSource>();
    sources.put("generic",level.damageSources().generic());
    sources.put("in_fire",level.damageSources().inFire());
    sources.put("explosion",level.damageSources().explosion(null,null));
    sources.put("generic_kill",level.damageSources().genericKill());
    sources.put("dragon",level.damageSources().mobAttack(dragon));
    var creative = new MobAiOracle.Fighter(level,1,net.minecraft.world.level.GameType.CREATIVE);
    creative.getAbilities().instabuild = true;
    sources.put("creative",level.damageSources().playerAttack(creative));
    sources.put("survival",level.damageSources().playerAttack(new MobAiOracle.Fighter(level,2,net.minecraft.world.level.GameType.SURVIVAL)));
    sources.put("fall",level.damageSources().fall());
    for (var source : sources.entrySet()) for (boolean invulnerable : new boolean[]{false,true})
      for (float amount : new float[]{0,1,20}) {
        var crystal = new EndCrystal(level,1.5,80,2.5); crystal.setPermanentlyInvulnerable(invulnerable);
        level.explosions = 0; level.power = 0;
        boolean hurt = crystal.hurtServer(level,source.getValue(),amount);
        var row = new JsonObject(); row.addProperty("source",source.getKey());
        row.addProperty("invulnerable",invulnerable); row.addProperty("amount",amount);
        row.addProperty("hurt",hurt); row.addProperty("removed",crystal.isRemoved());
        row.addProperty("explosions",level.explosions); row.addProperty("power",level.power); damage.add(row);
      }
    out.add("damage",damage);
    var packets = new JsonArray();
    for (boolean bottom : new boolean[]{false,true}) for (BlockPos beam : Arrays.asList(null,new BlockPos(-3,128,4))) {
      var c = new EndCrystal(level,0,80,0); c.setId(300); c.setShowBottom(bottom); c.setBeamTarget(beam);
      var values = c.getEntityData().getNonDefaultValues();
      var packet = new ClientboundSetEntityDataPacket(300,values == null ? List.of() : values);
      var row = new JsonObject(); row.addProperty("bottom",bottom);
      row.add("beam",beam == null ? JsonNull.INSTANCE : vector(beam.getX(),beam.getY(),beam.getZ()));
      row.addProperty("wire",HexFormat.of().formatHex(ExplosionOracle.encode(packet))); packets.add(row);
    }
    out.add("packets",packets);
    out.addProperty("version","26.3"); out.addProperty("server_sha1",VersionMetadata.serverSha1());
    Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out));
  }
}
