import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.monster.Shulker;
import net.minecraft.world.phys.*;

/** Actual native mob collision around shulker lids, with several body sizes. */
public class ShulkerMobCollisionOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    MobAiOracle.unsafe = (sun.misc.Unsafe)MobAiOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var registries = new ArrayList<Registry<?>>();
    registries.add(MobAiOracle.registry(Registries.DAMAGE_TYPE,lookup)); BuiltInRegistries.REGISTRY.forEach(registries::add);
    var access = new RegistryAccess.ImmutableRegistryAccess(registries).freeze();
    var level = MobAiOracle.probe(lookup,access,new net.minecraft.world.damagesource.DamageSources(access));
    var attach = Shulker.class.getDeclaredMethod("setAttachFace",Direction.class); attach.setAccessible(true);
    var peekField = MobAiOracle.field(Shulker.class,"currentPeekAmount");
    var collide = Entity.class.getDeclaredMethod("collide",Vec3.class); collide.setAccessible(true);
    var cases = new JsonArray();
    for (var face : Direction.values()) for (float peek : new float[] {0,.3F,1}) for (boolean dead : List.of(false,true))
      for (var type : List.of("minecraft:husk","minecraft:slime","minecraft:spider"))
      for (int axis=0;axis<3;axis++) for (int sign : new int[] {-1,1})
        for (double y : axis == 1 ? new double[] {0} : new double[] {0,1.25,2.25}) {
          var mob = (Shulker)MobAiOracle.mob("minecraft:shulker",level);
          attach.invoke(mob,face); peekField.setFloat(mob,peek); mob.setPos(.5,64,.5);
          if (dead) mob.setHealth(0);
          level.entities.clear(); level.entities.add(mob);
          var player = MobAiOracle.mob(type,level);
          double[] start = {.5,64+y,.5}; start[axis] += sign*3;
          double[] move = {0,0,0}; move[axis] = -sign*4;
          var position = new Vec3(start[0],start[1],start[2]); var motion = new Vec3(move[0],move[1],move[2]);
          player.setPos(position); var old = player.getBoundingBox();
          var actual = (Vec3)collide.invoke(player,motion); var target = position.add(motion);
          var row = new JsonObject(); row.addProperty("face",face.get3DDataValue());
          row.addProperty("peek",Float.floatToRawIntBits(peek)); row.addProperty("dead",dead);
          row.add("position",ShulkerBodyBoxOracle.point(position)); row.add("motion",ShulkerBodyBoxOracle.point(motion));
          row.add("actual",ShulkerBodyBoxOracle.point(position.add(actual))); row.addProperty("type",type); cases.add(row);
        }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(cases)+"\n");
    System.out.println("PASS: native mob/shulker collision cases: "+cases.size());
  }
}
