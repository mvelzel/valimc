import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.monster.Shulker;
import net.minecraft.world.phys.*;

/** Actual native shulker boxes and projectile segments across their six opening axes. */
public class ShulkerBodyBoxOracle {
  static JsonArray point(Vec3 p) {
    var out = new JsonArray();
    for (double v : new double[] {p.x,p.y,p.z}) out.add(NaturalSpawnOracle.bits(v));
    return out;
  }
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
    var cases = new JsonArray();
    for (var face : Direction.values()) for (int i=0; i<=20; i++)
      for (var at : List.of(new Vec3(.5,64,.5),new Vec3(-15.5,72.25,16.5),new Vec3(127.5,64,-128.5))) {
        var mob = (Shulker)MobAiOracle.mob("minecraft:shulker",level);
        attach.invoke(mob,face); float peek = i / 20F; peekField.setFloat(mob,peek); mob.setPos(at); at = mob.position();
        level.entities.clear(); level.entities.add(mob);
        var row = new JsonObject(); row.addProperty("face",face.get3DDataValue());
        row.addProperty("peek",Float.floatToRawIntBits(peek)); row.add("at",point(at));
        var b = mob.getBoundingBox(); var box = new JsonArray();
        for (double v : new double[] {b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ}) box.add(NaturalSpawnOracle.bits(v));
        row.add("box",box);
        // Sweep perpendicular to the lid at offsets inside, on and beyond the closed cube.
        var direction = face.getOpposite(); var step = direction.getUnitVec3();
        var shots = new JsonArray();
        for (double distance : new double[] {.25,.5,.75,1.0,1.25,1.5,1.75}) {
          var centre = at.add(0,.5,0).add(step.scale(distance));
          var travel = direction.getAxis() == Direction.Axis.X ? new Vec3(0,0,3) : new Vec3(3,0,0);
          var start = centre.subtract(travel.scale(.5)); var end = start.add(travel);
          var query = new AABB(start,end).inflate(1);
          var hit = net.minecraft.world.entity.projectile.ProjectileUtil.getEntityHitResult(level,(Entity)null,start,end,query,e -> true,0F);
          var shot = new JsonObject(); shot.add("start",point(start)); shot.add("velocity",point(travel));
          shot.add("hit",hit == null ? JsonNull.INSTANCE : point(hit.getLocation())); shots.add(shot);
        }
        row.add("shots",shots); cases.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(cases)+"\n");
    System.out.println("PASS: native shulker physical boxes: "+cases.size());
  }
}
