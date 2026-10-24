import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.particles.*;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.game.ClientboundBossEventPacket;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.util.RandomSource;
import net.minecraft.world.BossEvent;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.boss.enderdragon.*;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.ExplosionDamageCalculator;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.dimension.end.*;
import net.minecraft.world.level.levelgen.feature.*;

/** Native podium writes, gateway order, boss packets and whole respawn clocks (VMC-045a6). */
public class DragonArenaOracle {
  static class Chunks extends net.minecraft.server.level.ServerChunkCache {
    private Chunks() { super(null,null,null,null,null,null,0,0,false,null); }
    public net.minecraft.world.level.chunk.ChunkGenerator getGenerator() { return null; }
  }
  static class Probe extends MobAiOracle.Probe {
    long seed;
    JsonArray writes, drops, events, explosions, added;
    Probe() { super(); }
    public long getSeed() { return seed; }
    public int getMinY() { return 0; }
    public int getHeight() { return 256; }
    public boolean setBlock(BlockPos pos, BlockState block, int flags, int limit) {
      writes.add(vector(pos.getX(),pos.getY(),pos.getZ(),Block.getId(block)));
      blocks.put(pos.immutable(),block); return true;
    }
    public boolean destroyBlock(BlockPos pos, boolean drop, Entity source, int limit) {
      if (drop) drops.add(vector(pos.getX(),pos.getY(),pos.getZ(),Block.getId(getBlockState(pos))));
      blocks.put(pos.immutable(),Blocks.AIR.defaultBlockState()); return true;
    }
    public boolean removeBlock(BlockPos pos, boolean moving) {
      blocks.put(pos.immutable(),Blocks.AIR.defaultBlockState()); return true;
    }
    public boolean addFreshEntity(Entity entity) {
      entities.add(entity);
      if(entity instanceof EndCrystal crystal) {
        var row=new JsonObject(); row.add("position",vector(crystal.getX(),crystal.getY(),crystal.getZ()));
        row.addProperty("invulnerable",crystal.isInvulnerable()); row.add("beam",pos(crystal.getBeamTarget())); added.add(row);
      }
      return true;
    }
    public void levelEvent(Entity source,int type,BlockPos at,int data) { events.add(vector(type,at.getX(),at.getY(),at.getZ())); }
    @Override public void explode(Entity source,DamageSource damage,ExplosionDamageCalculator calculator,
        double x,double y,double z,float radius,boolean fire,Level.ExplosionInteraction interaction,
        ParticleOptions small,ParticleOptions large,
        net.minecraft.util.random.WeightedList<ExplosionParticleInfo> particles,Holder<SoundEvent> sound) {
      var row=new JsonObject(); row.add("position",vector(x,y,z)); row.addProperty("radius",radius);
      row.addProperty("blocks",interaction.toString()); explosions.add(row);
    }
    void clear() { writes=new JsonArray(); drops=new JsonArray(); events=new JsonArray(); explosions=new JsonArray(); added=new JsonArray(); }
  }
  static class Fight extends EnderDragonFight {
    DragonRespawnStage stage=DragonRespawnStage.START;
    int time=0;
    boolean reset=false;
    Fight() { super(false,true,true,Optional.of(DragonRespawnStage.START),0,Optional.empty(),Optional.empty(),List.of(),List.of()); }
    protected void setRespawnStage(DragonRespawnStage next) { stage=next; time=0; }
    public void resetSpikeCrystals() { reset=true; }
  }
  static JsonArray vector(double... values) { var row=new JsonArray(); for(var n:values) row.add(n); return row; }
  static JsonElement pos(BlockPos p) { return p==null?JsonNull.INSTANCE:vector(p.getX(),p.getY(),p.getZ()); }
  static String stage(DragonRespawnStage s) { return switch(s) {
    case START -> "start"; case PREPARING_TO_SUMMON_PILLARS -> "preparing";
    case SUMMONING_PILLARS -> "pillars"; case SUMMONING_DRAGON -> "summoning"; case END -> "end"; }; }
  static JsonObject packets(Probe level) {
    var rows=new JsonObject(); var uuid=new UUID(1234,5678);
    var event=new BossEvent(uuid,Component.translatable("entity.minecraft.ender_dragon"),BossEvent.BossBarColor.PINK,BossEvent.BossBarOverlay.PROGRESS) {};
    event.setProgress(.375F);
    for(int flags=0;flags<8;flags++) {
      event.setDarkenScreen((flags&1)!=0); event.setPlayBossMusic((flags&2)!=0); event.setCreateWorldFog((flags&4)!=0);
      rows.addProperty("add_"+flags,CombatOracle.wire(level.access,ClientboundBossEventPacket.createAddPacket(event)));
      rows.addProperty("flags_"+flags,CombatOracle.wire(level.access,ClientboundBossEventPacket.createUpdatePropertiesPacket(event)));
    }
    rows.addProperty("remove",CombatOracle.wire(level.access,ClientboundBossEventPacket.createRemovePacket(uuid)));
    rows.addProperty("progress",CombatOracle.wire(level.access,ClientboundBossEventPacket.createUpdateProgressPacket(event)));
    event.setName(Component.literal("The returned dragon"));
    rows.addProperty("name",CombatOracle.wire(level.access,ClientboundBossEventPacket.createUpdateNamePacket(event)));
    for(var color:BossEvent.BossBarColor.values()) for(var overlay:BossEvent.BossBarOverlay.values()) {
      event.setColor(color); event.setOverlay(overlay);
      rows.addProperty("style_"+color.ordinal()+"_"+overlay.ordinal(),CombatOracle.wire(level.access,ClientboundBossEventPacket.createUpdateStylePacket(event)));
    }
    return rows;
  }
  public static void main(String[] args) throws Exception {
    var level=MobAiOracle.setup(Probe.class);
    var chunks=(Chunks)MobAiOracle.unsafe.allocateInstance(Chunks.class);
    MobAiOracle.setFinal(net.minecraft.server.level.ServerLevel.class,"chunkSource",level,chunks);
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("server_sha1",VersionMetadata.serverSha1());
    out.add("packets",packets(level)); var podiums=new JsonArray();
    for(boolean active:new boolean[]{false,true}) for(boolean clutter:new boolean[]{false,true}) {
      level.blocks.clear(); level.clear(); var origin=new BlockPos(-7,68,12);
      if(clutter) for(var p:BlockPos.betweenClosed(origin.offset(-4,-1,-4),origin.offset(4,32,4)))
        level.blocks.put(p.immutable(),Blocks.STONE.defaultBlockState());
      new EndPodiumFeature(active).place(level,null,RandomSource.create(9),origin);
      var row=new JsonObject(); row.addProperty("active",active); row.addProperty("clutter",clutter);
      row.add("writes",level.writes); row.add("drops",level.drops); podiums.add(row);
    }
    out.add("podiums",podiums); var seeds=new JsonArray();
    for(long seed:new long[]{0,1,-1,42,20261024,Long.MAX_VALUE,Long.MIN_VALUE}) {
      level.seed=seed; var row=new JsonObject(); row.addProperty("seed",Long.toString(seed));
      var indices=new ArrayList<Integer>(); for(int i=0;i<20;i++) indices.add(i);
      net.minecraft.util.Util.shuffle(indices,RandomSource.createThreadLocalInstance(seed));
      row.add("gateways",new Gson().toJsonTree(indices)); var points=new JsonArray();
      for(int i=0;i<20;i++) points.add(vector(Math.floor(96*Math.cos(2*(-Math.PI+Math.PI/20*i))),75,Math.floor(96*Math.sin(2*(-Math.PI+Math.PI/20*i)))));
      row.add("gateway_positions",points); var spikes=new JsonArray();
      for(var s:EndSpikeFeature.getSpikesForLevel(level)) {
        var spike=new JsonObject(); spike.addProperty("x",s.getCenterX()); spike.addProperty("z",s.getCenterZ());
        spike.addProperty("height",s.getHeight()); spike.addProperty("radius",s.getRadius()); spike.addProperty("guarded",s.isGuarded()); spikes.add(spike);
      }
      row.add("spikes",spikes); seeds.add(row);
    }
    out.add("seeds",seeds); level.seed=20261024; level.entities.clear(); level.blocks.clear(); level.clear();
    var crystals=new ArrayList<EndCrystal>();
    for(int i=0;i<4;i++) { var c=new EndCrystal(level,i*3,69,0); c.setId(700+i); crystals.add(c); level.entities.add(c); }
    var fight=new Fight(); var ticks=new JsonArray();
    for(int tick=0;tick<1000&&fight.stage!=DragonRespawnStage.END;tick++) {
      level.clear(); fight.stage.tick(level,fight,crystals,fight.time++);
      var row=new JsonObject(); row.addProperty("stage",stage(fight.stage)); row.addProperty("time",fight.time);
      var beams=new JsonArray(); for(var c:crystals) beams.add(pos(c.getBeamTarget())); row.add("beams",beams);
      row.add("events",level.events); row.add("explosions",level.explosions); row.add("added",level.added);
      if(!level.added.isEmpty()) row.add("pillar_writes",level.writes);
      row.addProperty("reset",fight.reset); row.addProperty("removed",crystals.getFirst().isRemoved()); ticks.add(row);
    }
    out.add("ritual",ticks);
    Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(out));
  }
}
