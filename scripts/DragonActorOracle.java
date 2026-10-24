import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.particles.ParticleOptions;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.boss.enderdragon.*;
import net.minecraft.world.entity.boss.enderdragon.phases.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.Vec3;

/** Complete native ticks, including inherited Mob/LivingEntity work (VMC-045a5). */
public class DragonActorOracle {
  static class Probe extends DragonPhaseOracle.Probe {
    JsonArray particles, removed, global;
    int difficulty;
    Probe() { super(); }
    public net.minecraft.world.Difficulty getDifficulty() { return net.minecraft.world.Difficulty.byId(difficulty); }
    public BlockState getBlockState(BlockPos p) {
      return blocks.containsKey(p) ? blocks.get(p) : super.getBlockState(p);
    }
    public boolean removeBlock(BlockPos p, boolean moving) {
      if(getBlockState(p).isAir()) return false;
      blocks.put(p.immutable(),Blocks.AIR.defaultBlockState());
      removed.add(DragonFlightOracle.vec(p.getX(),p.getY(),p.getZ())); return true;
    }
    public void addParticle(ParticleOptions particle,double x,double y,double z,double dx,double dy,double dz) {
      var row=new JsonObject(); row.addProperty("name",BuiltInRegistries.PARTICLE_TYPE.getKey(particle.getType()).toString());
      row.add("position",DragonFlightOracle.vec(x,y,z)); particles.add(row);
    }
    public void globalLevelEvent(int type,BlockPos pos,int data) { global.add(type); }
    public boolean shouldTickDeath(Entity entity) { return true; }
  }
  static void reset(Probe level) {
    level.blocks.clear(); level.entities.clear(); level.fighters.clear(); level.added=new ArrayList<>();
    level.sounds.clear(); level.particles=new JsonArray(); level.removed=new JsonArray(); level.global=new JsonArray();
    level.terrain=1; level.ground=70; level.visible=true;
  }
  static JsonObject state(DragonPhaseOracle.Dragon d,Probe level) throws Exception {
    var row=DragonPhaseOracle.snapshot(d);
    row.addProperty("head",(double)d.getYHeadRot()); row.addProperty("body_yaw",(double)d.yBodyRot);
    row.addProperty("ambient",d.ambientSoundTime); row.addProperty("wall",d.inWall);
    row.addProperty("death_time",d.dragonDeathTime); row.addProperty("removed",d.isRemoved());
    row.addProperty("crystal",d.nearestCrystal==null ? -1 : d.nearestCrystal.getId());
    row.add("breaks",level.removed); row.add("particles",level.particles); row.add("global",level.global);
    var effects=new JsonArray();
    for(var e : level.added) {
      var out=new JsonObject(); out.addProperty("type",BuiltInRegistries.ENTITY_TYPE.getKey(e.getType()).toString());
      out.add("position",DragonFlightOracle.vec(e.position()));
      if(e instanceof ExperienceOrb orb) out.addProperty("xp",orb.getValue());
      if(e instanceof AreaEffectCloud cloud) { out.addProperty("radius",(double)cloud.getRadius()); out.addProperty("duration",cloud.getDuration()); }
      if(e instanceof net.minecraft.world.entity.projectile.hurtingprojectile.DragonFireball) out.add("direction",DragonFlightOracle.vec(e.getDeltaMovement().normalize()));
      effects.add(out);
    }
    row.add("added",effects);
    row.add("events",new Gson().toJsonTree(level.sounds.getOrDefault(d,List.of())));
    return row;
  }
  public static void main(String[] args) throws Exception {
    var level=MobAiOracle.setup(Probe.class); level.difficulty=2; var cases=new JsonArray();
    var flags=net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS;
    for(int phase=0;phase<11;phase++) for(int scene=0;scene<4;scene++) {
      reset(level); level.rules=new net.minecraft.world.level.gamerules.GameRules(flags);
      level.rules.set(net.minecraft.world.level.gamerules.GameRules.MOB_GRIEFING,scene!=3,null);
      var d=new DragonPhaseOracle.Dragon(level); level.current=d; level.entities.add(d);
      var at=phase>=3&&phase<=7 ? new Vec3(.5,90,.5) : new Vec3(40,110,20);
      d.snapTo(at.x,at.y,at.z,25,0); d.setYHeadRot(25); d.setHealth(180);
      d.setNoAi(scene==1); d.getRandom().setSeed(7241+scene);
      d.getPhaseManager().setPhase(EnderDragonPhase.getById(phase));
      var crystal=new EndCrystal(EntityTypes.END_CRYSTAL,level); crystal.setId(800);
      crystal.snapTo(at.x+12,at.y+1,at.z,0,0); level.entities.add(crystal);
      var row=new JsonObject(); row.addProperty("start_phase",phase); row.addProperty("scene",scene);
      row.add("position",DragonFlightOracle.vec(at)); row.add("crystal_position",DragonFlightOracle.vec(crystal.position()));
      var blocks=new JsonArray();
      if(scene>=2) for(int x=(int)at.x-8;x<=(int)at.x+8;x++) for(int y=(int)at.y;y<=(int)at.y+4;y++) for(int z=(int)at.z-8;z<=(int)at.z+8;z++) {
        var pos=new BlockPos(x,y,z); var block=x%3==0 ? Blocks.BEDROCK.defaultBlockState() : x%3==1 ? Blocks.END_STONE.defaultBlockState() : Blocks.FIRE.defaultBlockState();
        level.blocks.put(pos,block); var b=new JsonObject(); b.add("position",DragonFlightOracle.vec(x,y,z)); b.addProperty("state",net.minecraft.world.level.block.Block.getId(block)); blocks.add(b);
      }
      row.add("blocks",blocks);
      var fighter=new MobAiOracle.Fighter(level,1,GameType.SURVIVAL);
      fighter.snapTo(8,90,2,0,0); var player=MobAiOracle.serverFighter(fighter);
      level.fighters.add(player); level.entities.add(player);
      if(phase==1) d.getPhaseManager().getPhase(EnderDragonPhase.STRAFE_PLAYER).setTarget(player);
      if(phase==8) d.getPhaseManager().getPhase(EnderDragonPhase.CHARGING_PLAYER).setTarget(player.position());
      row.addProperty("player_id",player.getId());
      var ticks=new JsonArray();
      for(int t=0;t<360;t++) {
        if(t==100) { crystal.discard(); d.onCrystalDestroyed(level,crystal,crystal.blockPosition(),level.damageSources().playerAttack(fighter)); }
        level.added.clear(); level.sounds.clear(); level.particles=new JsonArray(); level.removed=new JsonArray(); level.global=new JsonArray();
        player.tickCount++; player.setDeltaMovement(Vec3.ZERO); player.hits.clear();
        d.setOldPosAndRot(); d.tickCount++; d.tick(); var out=state(d,level);
        out.add("push",DragonFlightOracle.vec(player.getDeltaMovement()));
        out.add("hits",new Gson().toJsonTree(player.hits)); ticks.add(out);
        if(d.getHealth()<=0) break;
      }
      row.add("ticks",ticks); cases.add(row);
    }
    for(boolean previous : new boolean[]{false,true}) {
      reset(level); level.rules=new net.minecraft.world.level.gamerules.GameRules(flags);
      var fight=new DragonPhaseOracle.Fight(0) { public boolean hasPreviouslyKilledDragon() { return previous; }
        public void setDragonKilled(EnderDragon dragon) {} };
      var d=new DragonPhaseOracle.Dragon(level); d.setDragonFight(fight); level.current=d; level.entities.add(d);
      d.snapTo(.5,90,.5,25,0); d.setYHeadRot(25); d.setHealth(0); d.getRandom().setSeed(7241);
      var row=new JsonObject(); row.addProperty("death",true); row.addProperty("previous",previous); row.add("position",DragonFlightOracle.vec(d.position()));
      var ticks=new JsonArray();
      for(int t=0;t<200;t++) {
        level.added.clear(); level.sounds.clear(); level.particles=new JsonArray(); level.removed=new JsonArray(); level.global=new JsonArray();
        d.setOldPosAndRot(); d.tickCount++; d.tick(); ticks.add(state(d,level));
      }
      row.add("ticks",ticks); cases.add(row);
    }
    var despawn=new JsonArray();
    for(int difficulty : new int[]{0,2}) for(double distance : new double[]{10,127.9,128.1,200})
      for(boolean persistent : new boolean[]{false,true}) {
        reset(level); level.difficulty=difficulty;
        var d=new DragonPhaseOracle.Dragon(level); level.current=d; level.entities.add(d);
        d.snapTo(.5+distance,64,.5,0,0);
        if(persistent) d.setPersistenceRequired();
        var fighter=new MobAiOracle.Fighter(level,1,GameType.SURVIVAL);
        fighter.snapTo(.5,64,.5,0,0); var player=MobAiOracle.serverFighter(fighter);
        level.fighters.add(player); level.entities.add(player);
        MobAiOracle.field(LivingEntity.class,"noActionTime").setInt(d,100);
        d.checkDespawn();
        var row=new JsonArray(); row.add(difficulty); row.add(distance); row.add(persistent);
        row.add(d.isRemoved()); row.add(MobAiOracle.field(LivingEntity.class,"noActionTime").getInt(d));
        despawn.add(row);
      }
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("server_sha1",VersionMetadata.serverSha1()); out.add("cases",cases); out.add("despawn",despawn);
    Files.writeString(java.nio.file.Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out));
  }
}
