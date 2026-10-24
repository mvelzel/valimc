import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.goal.BreathAirGoal;
import net.minecraft.world.entity.animal.dolphin.Dolphin;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.properties.*;
import net.minecraft.world.phys.*;

/** The actual breathing goal's own Entity.move, before navigation and move controls. */
public class DolphinBreathOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup,access,new net.minecraft.world.damagesource.DamageSources(access));
    var fluids = Entity.class.getDeclaredMethod("updateFluidInteraction"); fluids.setAccessible(true);
    var rows = new JsonArray();
    for (var layout : List.of("free","wall","ceiling","slab","stairs","shulker"))
      for (var velocity : List.of(new Vec3(.7,.7,.1),new Vec3(-.7,-.1,.4),new Vec3(.001,.002,.001),new Vec3(-1,-.7,-.5),Vec3.ZERO))
      for (float yaw : new float[] {0,45,90,-135}) for (boolean ground : List.of(false,true))
      for (double y : new double[] {64,64.3}) {
        level.blocks.clear(); level.entities.clear();
        for (int x=-4;x<=4;x++) for (int z=-4;z<=4;z++) {
          level.blocks.put(new BlockPos(x,63,z),Blocks.STONE.defaultBlockState());
          for (int cy=64;cy<=67;cy++) level.blocks.put(new BlockPos(x,cy,z),Blocks.WATER.defaultBlockState());
        }
        if (layout.equals("wall")) for (int cy=64;cy<=66;cy++) level.blocks.put(new BlockPos(1,cy,0),Blocks.STONE.defaultBlockState());
        if (layout.equals("ceiling")) for (int x=-1;x<=1;x++) for (int z=-1;z<=1;z++) level.blocks.put(new BlockPos(x,65,z),Blocks.STONE.defaultBlockState());
        if (layout.equals("slab")) level.blocks.put(new BlockPos(1,64,0),Blocks.STONE_SLAB.defaultBlockState());
        if (layout.equals("stairs")) level.blocks.put(new BlockPos(1,64,0),Blocks.OAK_STAIRS.defaultBlockState().setValue(StairBlock.FACING,Direction.WEST));
        var boxes = new JsonArray();
        if (layout.equals("shulker")) {
          var other = MobAiOracle.mob("minecraft:shulker",level); other.setPos(1.5,64,.5); level.entities.add(other);
          boxes.add(new Gson().toJsonTree(new double[] {other.getBoundingBox().minX,other.getBoundingBox().minY,other.getBoundingBox().minZ,other.getBoundingBox().maxX,other.getBoundingBox().maxY,other.getBoundingBox().maxZ}));
        }
        var mob = (Dolphin)MobAiOracle.mob("minecraft:dolphin",level);
        mob.setPos(.5,y,.5); mob.setNoGravity(true); mob.setOnGround(ground); mob.setAirSupply(139);
        mob.setYRot(yaw); mob.xxa=.4f; mob.yya=.2f; mob.zza=.7f;
        mob.setDeltaMovement(velocity); fluids.invoke(mob);
        var row = new JsonObject(); row.addProperty("layout",layout); row.addProperty("yaw",yaw); row.addProperty("ground",ground);
        row.add("start",ShulkerBodyBoxOracle.point(mob.position())); row.add("velocity",ShulkerBodyBoxOracle.point(velocity));
        mob.setDeltaMovement(Math.abs(velocity.x)<.003?0:velocity.x,Math.abs(velocity.y)<.003?0:velocity.y,Math.abs(velocity.z)<.003?0:velocity.z);
        mob.xxa*=.98f; mob.zza*=.98f;
        new BreathAirGoal(mob).tick();
        row.add("position",ShulkerBodyBoxOracle.point(mob.position())); row.add("boxes",boxes);
        var cells = new JsonArray(); for (var p : level.blocks.keySet()) cells.add(RedstoneOracle.row(p,Block.getId(level.blocks.get(p)))); row.add("cells",cells);
        rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(rows)+"\n");
    System.out.println("PASS: actual native dolphin breathing-goal moves: "+rows.size());
  }
}
