import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.*;

/** Original calls to native XP constructors/tick. Contacts and post-move velocity are supplied. */
public class OrbMotionOracle {
  static final Gson JSON = new Gson();
  static sun.misc.Unsafe unsafe;
  static double[] launchDraws;
  static int doubleCalls;
  static Field field(Class<?> c, String name) throws Exception {
    var f = c.getDeclaredField(name); f.setAccessible(true); return f;
  }
  static RandomSource tape(double[] doubles, int[] floats, int[] calls) {
    return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),
      new Class<?>[]{RandomSource.class}, (proxy, method, args) -> {
        if (method.getName().equals("nextDouble")) return doubles[doubleCalls++];
        if (method.getName().equals("nextFloat")) return floats[calls[0]++] / 16777216f;
        throw new AssertionError("Unexpected RNG call: " + method.getName());
      });
  }
  static class World extends ServerLevel {
    Block support; boolean embedded, lava; int queries; Target target;
    private World() { super(null,null,null,null,null,null,false,0L,List.of(),false); }
    public int getNextEntityId() { return 1; }
    // The second query supplies a clear escape destination; escape choice is excluded.
    public boolean noCollision(AABB box) { return ++queries > 1 || !embedded; }
    public BlockState getBlockState(BlockPos p) { return support.defaultBlockState(); }
    public FluidState getFluidState(BlockPos p) {
      return lava ? Fluids.LAVA.defaultFluidState() : Fluids.EMPTY.defaultFluidState();
    }
    public Player getNearestPlayer(Entity e, double range) { return target; }
  }
  static class Target extends Player {
    private Target() { super(null,null); }
    public GameType gameMode() { return GameType.SURVIVAL; }
    public boolean isDeadOrDying() { return false; }
  }
  static class Orb extends ExperienceOrb {
    boolean water, grounded, below, discarded; Vec3 requested, post;
    Orb(World world) { super(EntityTypes.EXPERIENCE_ORB, world); setPos(0,64,0); }
    Orb(World world, Vec3 pos, Vec3 direction) { super(world,pos,direction,3); }
    public void setYRot(float yaw) {
      super.setYRot(yaw);
      if (launchDraws != null) {
        try { field(Entity.class,"random").set(this,tape(launchDraws,null,null)); }
        catch (Exception e) { throw new AssertionError(e); }
      }
    }
    public void baseTick() {} // World/base effects and fluid-current sampling are excluded.
    public boolean isEyeInFluid(TagKey<Fluid> tag) { return water; }
    public boolean onGround() { return grounded; }
    public void move(MoverType kind, Vec3 velocity) {
      requested = velocity; if (post != null) setDeltaMovement(post);
      verticalCollisionBelow = below;
    }
    public void applyEffectsFromBlocks() {}
    public BlockPos getBlockPosBelowThatAffectsMyMovement() { return BlockPos.ZERO; }
    public void remove(Entity.RemovalReason reason) {
      if (reason != Entity.RemovalReason.DISCARDED) throw new AssertionError(reason);
      discarded = true;
    }
  }
  static JsonArray vector(Vec3 v) { return JSON.toJsonTree(new double[]{v.x,v.y,v.z}).getAsJsonArray(); }
  static JsonArray bits(Vec3 v) {
    var a = new JsonArray();
    for (double n : new double[]{v.x,v.y,v.z}) a.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(n)));
    return a;
  }
  static JsonObject tick(World world, Vec3 input, boolean water, boolean embedded, boolean noGravity,
                         int[] draws, Vec3 offset, int collision, int age) throws Exception {
    world.queries=0; world.embedded=embedded; world.lava=draws!=null; world.target=null;
    if (offset != null) {
      world.target=(Target)unsafe.allocateInstance(Target.class);
      field(Entity.class,"position").set(world.target,new Vec3(offset.x,64+offset.y,offset.z));
      field(Entity.class,"eyeHeight").setFloat(world.target,1.62f);
    }
    var orb=new Orb(world); orb.water=water; orb.grounded=collision>0; orb.below=collision>0;
    orb.post=collision==1?Vec3.ZERO:collision==2?new Vec3(-.125,.123,.25):null;
    orb.setNoGravity(noGravity); orb.setDeltaMovement(input);
    field(ExperienceOrb.class,"age").setInt(orb,age);
    int[] calls={0}; field(Entity.class,"random").set(orb,tape(null,draws,calls));
    var row=new JsonObject(); row.add("input",vector(input));
    row.addProperty("water",water); row.addProperty("embedded",embedded); row.addProperty("no_gravity",noGravity);
    row.add("lava_draws",JSON.toJsonTree(draws)); row.addProperty("friction",world.support.getFriction());
    row.addProperty("ground",orb.grounded); row.addProperty("below",orb.below);
    row.addProperty("age",age); row.add("post",orb.post==null?JsonNull.INSTANCE:vector(orb.post));
    orb.tick();
    var target=(Player)field(ExperienceOrb.class,"followingPlayer").get(orb);
    row.add("target",target==null?JsonNull.INSTANCE:vector(new Vec3(target.getX()-orb.getX(),
      target.getY()+(double)target.getEyeHeight()/2-orb.getY(),target.getZ()-orb.getZ())));
    row.add("requested_bits",bits(orb.requested)); row.add("velocity_bits",bits(orb.getDeltaMovement()));
    row.addProperty("age_after",field(ExperienceOrb.class,"age").getInt(orb));
    row.addProperty("expired",orb.discarded); row.addProperty("draw_calls",calls[0]);
    if (calls[0]!=(draws==null?0:4)) throw new AssertionError("RNG count");
    return row;
  }
  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize(); unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class); bind.setAccessible(true);
    for (var f:List.of(Fluids.LAVA,Fluids.FLOWING_LAVA)) bind.invoke(f.builtInRegistryHolder(),List.of(FluidTags.LAVA));
    var world=(World)unsafe.allocateInstance(World.class); world.support=Blocks.STONE;
    var launches=new JsonArray();
    var directions=List.of(Vec3.ZERO,new Vec3(1,0,0),new Vec3(-1,2,-3),new Vec3(1e-200,0,0),
      new Vec3(Math.nextDown((double)1e-5f),0,0),new Vec3(1e-5f,0,0),new Vec3(Math.nextUp((double)1e-5f),0,0));
    for (var pos:List.of(Vec3.ZERO,new Vec3(-17.125,64,128.5))) for (var dir:directions)
      for (double[] draws:List.of(new double[]{0,0,0},new double[]{.5,.5,.5},
        new double[]{Math.nextDown(1d),Math.nextDown(1d),Math.nextDown(1d)},new double[]{.2,.7,.9})) {
        world.queries=0; launchDraws=draws; doubleCalls=0;
        var orb=new Orb(world,pos,dir); launchDraws=null;
        if (doubleCalls!=3) throw new AssertionError("Launch draws");
        var row=new JsonObject(); row.add("position",vector(pos)); row.add("direction",vector(dir));
        row.add("draws",JSON.toJsonTree(draws)); row.add("position_bits",bits(orb.position()));
        row.add("velocity_bits",bits(orb.getDeltaMovement())); launches.add(row);
      }
    var ticks=new JsonArray();
    for (var support:List.of(Blocks.STONE,Blocks.ICE,Blocks.HONEY_BLOCK))
      for (var v:List.of(Vec3.ZERO,new Vec3(.3,.2,-.1),new Vec3(-.0,-.03,-.0),
        new Vec3(.1,Math.nextDown(-.03),.2),new Vec3(0,.06f,0),new Vec3(.01,-1,.01)))
       for (boolean water:new boolean[]{false,true}) for (boolean embedded:new boolean[]{false,true})
        for (boolean noGravity:new boolean[]{false,true})
         for (int[] draws:new int[][]{null,{0,16777215,16777215,0},{8388608,1,1,8388608}})
          for (Vec3 target:new Vec3[]{null,new Vec3(0,-(double)1.62f/2,0),new Vec3(.5,1,-.25),new Vec3(8,0,0)})
           for (int collision=0;collision<3;collision++) {
             world.support=support;
             ticks.add(tick(world,v,water,embedded,noGravity,draws,target,collision,0));
           }
    var ages=new JsonArray();
    for (int age:new int[]{-32768,-1,0,5998,5999})
      ages.add(tick(world,Vec3.ZERO,false,false,true,null,null,0,age));
    var output=new JsonObject(); output.addProperty("version","26.3");
    output.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    output.add("launches",launches); output.add("ticks",ticks); output.add("ages",ages);
    Files.writeString(Path.of(args[0]),JSON.toJson(output));
    System.out.println("PASS: "+launches.size()+" native launches, "+ticks.size()+" actual XP ticks and "+ages.size()+" expiry boundaries; supplied contacts/post-move facts, selection/escape/merge/current/world effects excluded.");
  }
}
