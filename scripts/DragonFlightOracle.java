import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.EntityTypes;
import net.minecraft.world.entity.boss.enderdragon.*;
import net.minecraft.world.entity.boss.enderdragon.phases.*;
import net.minecraft.world.level.dimension.end.EnderDragonFight;
import net.minecraft.world.level.levelgen.Heightmap;
import net.minecraft.world.level.pathfinder.Node;
import net.minecraft.world.phys.Vec3;

/** Native dragon movement and arena-path probes (VMC-045a2). */
public class DragonFlightOracle {
  static class Probe extends MobAiOracle.Probe {
    int terrain;
    Probe() { super(); }
    public int getHeight(Heightmap.Types type, int x, int z) {
      return height(terrain,x,z);
    }
    public BlockPos getHeightmapPos(Heightmap.Types type, BlockPos pos) {
      return new BlockPos(pos.getX(),getHeight(type,pos.getX(),pos.getZ()),pos.getZ());
    }
  }
  // Only the target is supplied. All movement, turn profiles and part placement
  // are the native dragon's; its own phase decisions are checked separately.
  static class Target extends AbstractDragonPhaseInstance {
    DragonPhaseInstance profile;
    Vec3 target;
    Target(EnderDragon d, int phase) { super(d); profile = d.getPhaseManager().getPhase(EnderDragonPhase.getById(phase)); }
    public Vec3 getFlyTargetLocation() { return target; }
    public float getFlySpeed() { return profile.getFlySpeed(); }
    public float getTurnSpeed() { return profile.getTurnSpeed(); }
    public boolean isSitting() { return profile.isSitting(); }
    public EnderDragonPhase<?> getPhase() { return profile.getPhase(); }
  }
  static int height(int terrain, int x, int z) {
    return switch (terrain) { case 1 -> 90; case 2 -> 65 + Math.floorMod(x * 13 + z * 7, 48); default -> 0; };
  }
  static Object field(Object o, String name) throws Exception {
    var f = o.getClass().getDeclaredField(name); f.setAccessible(true); return f.get(o);
  }
  static void set(Object o, String name, Object value) throws Exception {
    var f = o.getClass().getDeclaredField(name); f.setAccessible(true); f.set(o,value);
  }
  static JsonArray vec(double... xs) { var a = new JsonArray(); for (var x : xs) a.add(x); return a; }
  static JsonArray vec(Vec3 v) { return vec(v.x,v.y,v.z); }
  static EnderDragon dragon(Probe level) { return new EnderDragon(EntityTypes.ENDER_DRAGON,level); }
  static JsonObject facts(Probe level) throws Exception {
    var out = new JsonObject(); var d = dragon(level); level.terrain = 1; d.findClosestNode();
    var nodes = (Node[])field(d,"nodes"); var adjacent = (int[])field(d,"nodeAdjacency"); var graph = new JsonArray();
    for (int i=0;i<nodes.length;i++) graph.add(vec(nodes[i].x,nodes[i].y-90,nodes[i].z,adjacent[i]));
    out.add("graph",graph); var parts = new JsonArray();
    for (var p : d.getSubEntities()) { var row = new JsonObject(); row.addProperty("name",p.name);
      row.addProperty("width",p.getBbWidth()); row.addProperty("height",p.getBbHeight()); parts.add(row); }
    out.add("parts",parts); var phases = new JsonArray();
    for (int i=0;i<EnderDragonPhase.getCount();i++) {
      var p = EnderDragonPhase.getById(i); var instance = d.getPhaseManager().getPhase(p); var row = new JsonObject();
      row.addProperty("id",i); row.addProperty("name",p.toString().split(" ")[0]);
      row.addProperty("speed",(double)instance.getFlySpeed()); row.addProperty("sitting",instance.isSitting()); phases.add(row);
    }
    out.add("phases",phases); out.addProperty("version","26.3"); out.addProperty("server_sha1",VersionMetadata.serverSha1()); return out;
  }
  static JsonObject snapshot(EnderDragon d) {
    var row = new JsonObject(); row.add("position",vec(d.position())); row.add("velocity",vec(d.getDeltaMovement()));
    row.addProperty("yaw",(double)d.getYRot()); row.addProperty("turn",(double)d.yRotA); var parts = new JsonArray();
    for (var p : d.getSubEntities()) { var b=p.getBoundingBox(); parts.add(vec(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ)); }
    row.add("parts",parts); return row;
  }
  static JsonArray flights(Probe level) throws Exception {
    var all = new JsonArray();
    for (int phase=0;phase<EnderDragonPhase.getCount();phase++) for (int scene=0;scene<6;scene++) {
      var d=dragon(level); d.snapTo(-17.25,90.125,23.75, scene==0 ? 725 : -137.5f,0);
      d.setDeltaMovement(scene==1 ? new Vec3(45,-.25,-30) : new Vec3(.4,.125,-.7)); d.yRotA=scene==2 ? -31.25f : 2.25f;
      var target=new Target(d,phase); set(d.getPhaseManager(),"currentPhase",target);
      var row=new JsonObject(); row.addProperty("phase",phase); row.addProperty("scene",scene); row.add("initial",snapshot(d)); var ticks=new JsonArray();
      for (int tick=0;tick<80;tick++) {
        target.target=switch(scene) {
          case 0 -> new Vec3(30,70,-40);
          case 1 -> new Vec3(-20,180,30);
          case 2 -> new Vec3(d.getX(),d.getY()+2,d.getZ());
          case 3 -> tick%7==0 ? null : new Vec3(-40+tick,60+tick*.25,50-tick*.75);
          default -> new Vec3(-18,90,23);
        };
        boolean wall=scene==4 && tick%3==0, noAi=scene==5;
        d.inWall=wall; d.setNoAi(noAi); d.tickCount++; d.aiStep();
        var out=snapshot(d); out.add("target",target.target==null?JsonNull.INSTANCE:vec(target.target)); out.addProperty("wall",wall); out.addProperty("no_ai",noAi); ticks.add(out);
      }
      row.add("ticks",ticks); all.add(row);
    }
    return all;
  }
  static JsonArray paths(Probe level) throws Exception {
    var all=new JsonArray();
    for (int terrain=0;terrain<3;terrain++) for (int crystals : new int[]{-1,0,10}) {
      level.terrain=terrain; var d=dragon(level);
      if (crystals>=0) { var fight=(EnderDragonFight)MobAiOracle.unsafe.allocateInstance(EnderDragonFight.class); set(fight,"aliveCrystals",crystals); d.setDragonFight(fight); }
      d.findClosestNode(); var row=new JsonObject(); row.addProperty("terrain",terrain); row.addProperty("crystals",crystals);
      var closest=new JsonArray();
      for (var p : List.of(new Vec3(0,90,0),new Vec3(61,80,0),new Vec3(-42.5,110,1),new Vec3(0,150,-30),new Vec3(1000,1000,1000))) {
        var c=new JsonObject(); c.add("position",vec(p)); c.addProperty("node",d.findClosestNode(p.x,p.y,p.z)); closest.add(c);
      }
      row.add("closest",closest); var paths=new JsonArray();
      for (int start=0;start<24;start++) for(int end=0;end<24;end++) for(boolean finish : new boolean[]{false,true}) {
        var p=d.findPath(start,end,finish ? new Node(3,77,-2) : null); var c=new JsonObject(); c.addProperty("start",start); c.addProperty("end",end); c.addProperty("finish",finish);
        if (p==null) c.add("nodes",JsonNull.INSTANCE); else { var ns=new JsonArray(); for(int i=0;i<p.getNodeCount();i++) { var n=p.getNode(i); ns.add(vec(n.x,n.y,n.z)); } c.add("nodes",ns); }
        paths.add(c);
      }
      row.add("paths",paths); all.add(row);
    }
    return all;
  }
  public static void main(String[] args) throws Exception {
    var level=MobAiOracle.setup(Probe.class); var out=facts(level);
    if (!args[0].equals("facts")) { out.add("flights",flights(level)); out.add("paths",paths(level)); }
    Files.writeString(Path.of(args[1]),new GsonBuilder().serializeNulls().setPrettyPrinting().create().toJson(out));
  }
}
