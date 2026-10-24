import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.monster.Shulker;
import net.minecraft.world.entity.item.*;
import net.minecraft.world.item.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.*;

/** Invoke the actual lid-change callback, including native entity selection and move. */
public class ShulkerPushOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup,access,new net.minecraft.world.damagesource.DamageSources(access));
    var attach = Shulker.class.getDeclaredMethod("setAttachFace",Direction.class); attach.setAccessible(true);
    var current = MobAiOracle.field(Shulker.class,"currentPeekAmount");
    var previous = MobAiOracle.field(Shulker.class,"currentPeekAmountO");
    var changed = Shulker.class.getDeclaredMethod("onPeekAmountChange"); changed.setAccessible(true);
    var physical = Shulker.class.getDeclaredMethod("getPhysicalPeek",float.class); physical.setAccessible(true);
    var cases = new JsonArray();
    for (var face : Direction.values()) for (float[] transition : new float[][] {{0,1},{0,.05F},{.25F,.3F},{.5F,.55F},{.95F,1},{1,.95F},{.3F,.3F}})
      for (var kind : List.of("husk","no_ai","slime","spider","item","orb","player","spectator","shulker","no_physics","arrow","area_effect_cloud","end_crystal","tnt","falling_block","shulker_bullet"))
      for (double offset : new double[] {-.8,0,.3,1.5}) for (boolean wall : List.of(false,true)) {
        level.blocks.clear(); level.entities.clear();
        var shell = (Shulker)MobAiOracle.mob("minecraft:shulker",level);
        attach.invoke(shell,face); current.setFloat(shell,transition[0]); shell.setPos(.5,64,.5);
        Entity target = switch (kind) {
          case "item" -> new ItemEntity(level,0,0,0,new ItemStack(Items.STONE));
          case "orb" -> new ExperienceOrb(level,0,0,0,1);
          case "player", "spectator" -> new MobAiOracle.Fighter(level,1,kind.equals("player") ? GameType.SURVIVAL : GameType.SPECTATOR);
          case "arrow", "area_effect_cloud", "end_crystal", "tnt", "falling_block", "shulker_bullet" ->
            BuiltInRegistries.ENTITY_TYPE.getValue(net.minecraft.resources.Identifier.parse("minecraft:"+kind)).create(level,EntitySpawnReason.COMMAND);
          default -> MobAiOracle.mob("minecraft:"+(List.of("no_ai","no_physics").contains(kind) ? "husk" : kind),level);
        };
        if (kind.equals("no_ai")) ((Mob)target).setNoAi(true);
        if (kind.equals("no_physics")) target.noPhysics = true;
        var direction = face.getOpposite(); var step = direction.getUnitVec3();
        float old = (float)physical.invoke(null,transition[0]);
        var centre = shell.position().add(0,.5,0).add(step.scale(.5+old+offset));
        target.setPos(centre.x,centre.y-target.getBbHeight()/2.0,centre.z);
        target.setDeltaMovement(.17,-.11,.23); target.setOnGround(true);
        if (wall) {
          var c = centre.add(step.scale(target.getBbHeight()/2.0+.025));
          level.blocks.put(BlockPos.containing(c),Blocks.STONE.defaultBlockState());
        }
        level.entities.add(shell); level.entities.add(target);
        var row = new JsonObject(); row.addProperty("face",face.get3DDataValue()); row.addProperty("kind",kind);
        row.addProperty("old",Float.floatToRawIntBits(transition[0])); row.addProperty("new",Float.floatToRawIntBits(transition[1]));
        row.addProperty("no_physics",target.noPhysics); row.add("before_velocity",ShulkerBodyBoxOracle.point(target.getDeltaMovement()));
        row.addProperty("step",(double)target.maxUpStep()); row.addProperty("simulates",target.canSimulateMovement());
        row.add("at",ShulkerBodyBoxOracle.point(shell.position())); row.add("start",ShulkerBodyBoxOracle.point(target.position()));
        row.addProperty("width",(double)target.getBbWidth()); row.addProperty("height",(double)target.getBbHeight());
        var blocks = new JsonArray();
        for (var p : level.blocks.keySet()) { var b = new JsonArray(); b.add(p.getX()); b.add(p.getY()); b.add(p.getZ()); blocks.add(b); }
        row.add("blocks",blocks);
        previous.setFloat(shell,transition[0]); current.setFloat(shell,transition[1]);
        changed.invoke(shell);
        row.add("position",ShulkerBodyBoxOracle.point(target.position())); row.add("velocity",ShulkerBodyBoxOracle.point(target.getDeltaMovement()));
        row.addProperty("ground",target.onGround()); row.add("shell",ShulkerBodyBoxOracle.point(shell.position())); cases.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(cases)+"\n");
    System.out.println("PASS: native shulker lid push cases: "+cases.size());
  }
}
