import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.phys.*;

/** Original calls to native XP constructors with supplied launch draws; ticks are OrbTravelOracle's. */
public class OrbMotionOracle {
  static final Gson JSON = new Gson();
  static double[] launchDraws;
  static int doubleCalls;
  static Field field(Class<?> c, String name) throws Exception {
    var f = c.getDeclaredField(name); f.setAccessible(true); return f;
  }
  static RandomSource tape(double[] doubles) {
    return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),
      new Class<?>[]{RandomSource.class}, (proxy, method, args) -> {
        if (method.getName().equals("nextDouble")) return doubles[doubleCalls++];
        throw new AssertionError("Unexpected RNG call: " + method.getName());
      });
  }
  static class World extends ServerLevel {
    private World() { super(null,null,null,null,null,null,false,0L,List.of(),false); }
    public int getNextEntityId() { return 1; }
    // Spawn escape is excluded: every launch position is clear.
    public boolean noCollision(AABB box) { return true; }
  }
  static class Orb extends ExperienceOrb {
    Orb(World world, Vec3 pos, Vec3 direction) { super(world,pos,direction,3); }
    public void setYRot(float yaw) {
      super.setYRot(yaw);
      if (launchDraws != null) {
        try { field(Entity.class,"random").set(this,tape(launchDraws)); }
        catch (Exception e) { throw new AssertionError(e); }
      }
    }
  }
  static JsonArray vector(Vec3 v) { return JSON.toJsonTree(new double[]{v.x,v.y,v.z}).getAsJsonArray(); }
  static JsonArray bits(Vec3 v) {
    var a = new JsonArray();
    for (double n : new double[]{v.x,v.y,v.z}) a.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(n)));
    return a;
  }
  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(World)unsafe.allocateInstance(World.class);
    var launches=new JsonArray();
    var directions=List.of(Vec3.ZERO,new Vec3(1,0,0),new Vec3(-1,2,-3),new Vec3(1e-200,0,0),
      new Vec3(Math.nextDown((double)1e-5f),0,0),new Vec3(1e-5f,0,0),new Vec3(Math.nextUp((double)1e-5f),0,0));
    for (var pos:List.of(Vec3.ZERO,new Vec3(-17.125,64,128.5))) for (var dir:directions)
      for (double[] draws:List.of(new double[]{0,0,0},new double[]{.5,.5,.5},
        new double[]{Math.nextDown(1d),Math.nextDown(1d),Math.nextDown(1d)},new double[]{.2,.7,.9})) {
        launchDraws=draws; doubleCalls=0;
        var orb=new Orb(world,pos,dir); launchDraws=null;
        if (doubleCalls!=3) throw new AssertionError("Launch draws");
        var row=new JsonObject(); row.add("position",vector(pos)); row.add("direction",vector(dir));
        row.add("draws",JSON.toJsonTree(draws)); row.add("position_bits",bits(orb.position()));
        row.add("velocity_bits",bits(orb.getDeltaMovement())); launches.add(row);
      }
    var output=new JsonObject(); output.addProperty("version","26.3");
    output.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    output.add("launches",launches);
    Files.writeString(Path.of(args[0]),JSON.toJson(output));
    System.out.println("PASS: "+launches.size()+" native XP launches; spawn escape excluded.");
  }
}
