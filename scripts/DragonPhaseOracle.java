import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicLong;
import net.minecraft.core.BlockPos;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.boss.enderdragon.*;
import net.minecraft.world.entity.boss.enderdragon.phases.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.dimension.end.EnderDragonFight;
import net.minecraft.world.level.pathfinder.Path;
import net.minecraft.world.phys.Vec3;

/** Whole native phase/flight sequences, without a live server (VMC-045a3). */
public class DragonPhaseOracle {
  static class Probe extends DragonFlightOracle.Probe {
    boolean visible;
    int ground;
    List<Entity> added;
    Probe() { super(); }
    public BlockState getBlockState(BlockPos pos) {
      return pos.getY()<ground ? Blocks.END_STONE.defaultBlockState() : super.getBlockState(pos);
    }
    public boolean addFreshEntity(Entity entity) { added.add(entity); return true; }
  }
  static class Fight extends EnderDragonFight {
    int crystals;
    Fight(int count) { super(false,false,false,Optional.empty(),0,Optional.empty(),Optional.empty(),List.of(),List.of()); crystals=count; }
    public int aliveCrystals() { return crystals; }
    public void updateDragon(EnderDragon dragon) {}
  }
  static class Dragon extends EnderDragon {
    Probe probe;
    Dragon(Probe level) { super(EntityTypes.ENDER_DRAGON,level); probe=level; }
    public boolean hasLineOfSight(Entity entity) { return probe.visible; }
  }
  static Object optional(Object o, String name) throws Exception {
    try { return DragonFlightOracle.field(o,name); } catch(NoSuchFieldException e) { return null; }
  }
  static JsonObject snapshot(Dragon d) throws Exception {
    var row=DragonFlightOracle.snapshot(d); var phase=d.getPhaseManager().getCurrentPhase();
    row.addProperty("phase",phase.getPhase().getId()); row.add("target",phase.getFlyTargetLocation()==null ? JsonNull.INSTANCE : DragonFlightOracle.vec(phase.getFlyTargetLocation()));
    var seed=MobAiOracle.field(net.minecraft.world.level.levelgen.LegacyRandomSource.class,"seed"); row.addProperty("random",((AtomicLong)seed.get(d.getRandom())).get());
    var path=(Path)optional(phase,"currentPath");
    if(path==null) row.add("path",JsonNull.INSTANCE); else { var nodes=new JsonArray(); for(int i=path.getNextNodeIndex();i<path.getNodeCount();i++) { var n=path.getNode(i); nodes.add(DragonFlightOracle.vec(n.x,n.y,n.z)); } row.add("path",nodes); }
    String counter=switch(phase.getPhase().getId()) { case 5 -> "flameTicks"; case 6 -> "scanningTime"; case 7 -> "attackingTicks"; case 8 -> "timeSinceCharge"; case 9 -> "time"; default -> null; };
    if(counter!=null) row.addProperty("ticks",(int)optional(phase,counter));
    row.addProperty("flames",(int)optional(d.getPhaseManager().getPhase(EnderDragonPhase.SITTING_FLAMING),"flameCount"));
    row.addProperty("charge",(int)optional(d.getPhaseManager().getPhase(EnderDragonPhase.STRAFE_PLAYER),"fireballCharge"));
    row.addProperty("health",(double)d.getHealth()); return row;
  }
  public static void main(String[] args) throws Exception {
    var level=MobAiOracle.setup(Probe.class); level.added=new ArrayList<>(); level.terrain=1;
    var cases=new JsonArray();
    for(int phase=0;phase<11;phase++) for(int scene=0;scene<4;scene++) for(int crystals : new int[]{-1,0,10}) {
      level.blocks.clear(); level.entities.clear(); level.fighters.clear(); level.added.clear(); level.visible=scene!=3; level.ground=scene==3 ? 0 : 70;
      var d=new Dragon(level); if(crystals>=0) d.setDragonFight(new Fight(crystals));
      var at=phase>=3&&phase<=7 ? new Vec3(.5,90,.5) : new Vec3(40,110,20);
      if(phase==5 && scene==3) at=new Vec3(.5,10000,.5);
      d.snapTo(at.x,at.y,at.z,25,0); d.setYHeadRot(25); d.getRandom().setSeed(4519+scene);
      MobAiOracle.ServerFighter player=null;
      if(scene!=1) {
        var fighter=new MobAiOracle.Fighter(level,1,GameType.SURVIVAL);
        var pos=scene==2 ? new Vec3(80,90,35) : new Vec3(8,90,2);
        fighter.snapTo(pos.x,pos.y,pos.z,0,0); player=MobAiOracle.serverFighter(fighter);
        level.fighters.add(player); // Contact damage is outside the phase model.
      }
      d.getPhaseManager().setPhase(EnderDragonPhase.getById(phase));
      if(phase==1 && player!=null) d.getPhaseManager().getPhase(EnderDragonPhase.STRAFE_PLAYER).setTarget(player);
      if(phase==8 && player!=null) d.getPhaseManager().getPhase(EnderDragonPhase.CHARGING_PLAYER).setTarget(player.position());
      var row=new JsonObject(); row.addProperty("start_phase",phase); row.addProperty("scene",scene); row.addProperty("crystals",crystals); row.add("position",DragonFlightOracle.vec(at));
      var players=new JsonArray(); if(player!=null) { var p=new JsonObject(); p.addProperty("id",player.getId()); p.add("position",DragonFlightOracle.vec(player.position())); p.addProperty("height",(double)player.getBbHeight()); players.add(p); } row.add("players",players);
      var ticks=new JsonArray(); AreaEffectCloud flame=null;
      int total=phase==6 ? 1200 : phase==0 ? 800 : 320;
      for(int tick=0;tick<total;tick++) {
        if(scene==2 && player!=null) {
          if(tick<120) player.setPos(80+Math.sin(tick*.07)*20,90,35+Math.cos(tick*.05)*15);
          else level.fighters.clear();
        }
        boolean collision=scene==2 && tick%71==70; d.horizontalCollision=collision; d.verticalCollision=false;
        var before=flame; boolean alive=before!=null&&!before.isRemoved(); level.added.clear(); d.tickCount++; d.aiStep();
        var out=snapshot(d); out.addProperty("collision",collision);
        out.addProperty("player_present",player!=null && (scene!=2 || tick<120));
        out.add("player_position",player==null ? JsonNull.INSTANCE : DragonFlightOracle.vec(player.position())); var effects=new JsonArray();
        for(var entity : level.added) {
          var e=new JsonObject(); e.add("position",DragonFlightOracle.vec(entity.position()));
          if(entity instanceof AreaEffectCloud cloud) { e.addProperty("kind","flame"); flame=cloud;
            e.addProperty("radius",(double)cloud.getRadius()); e.addProperty("duration",cloud.getDuration()); }
          else { e.addProperty("kind","fireball"); e.add("direction",DragonFlightOracle.vec(entity.getDeltaMovement().normalize())); }
          effects.add(e);
        }
        out.addProperty("end_flame",alive&&before.isRemoved()); out.add("effects",effects); ticks.add(out);
        if(d.getHealth()<=0) break;
      }
      row.add("ticks",ticks); cases.add(row);
    }
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("server_sha1",VersionMetadata.serverSha1()); out.add("cases",cases);
    Files.writeString(java.nio.file.Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out));
  }
}
