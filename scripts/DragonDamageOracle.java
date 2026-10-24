import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.boss.enderdragon.*;
import net.minecraft.world.entity.boss.enderdragon.phases.*;
import net.minecraft.world.entity.projectile.arrow.*;
import net.minecraft.world.entity.projectile.hurtingprojectile.windcharge.WindCharge;
import net.minecraft.world.level.GameType;

/** Native multipart hurt admission and subclass damage rules (VMC-045a4). */
public class DragonDamageOracle {
  public static void main(String[] args) throws Exception {
    var level=MobAiOracle.setup(MobAiOracle.Probe.class);
    var player=new MobAiOracle.Fighter(level,1,GameType.SURVIVAL);
    var other=new net.minecraft.world.entity.monster.zombie.Zombie(EntityTypes.ZOMBIE,level);
    player.snapTo(-2,80,3,0,0); other.snapTo(-2,80,3,0,0);
    var cases=new JsonArray();
    var cooldown=MobAiOracle.field(LivingEntity.class,"damageCooldownTime");
    for(int phase=0;phase<11;phase++) for(int part=0;part<8;part++)
      for(String source : List.of("player_attack","mob_attack","arrow","trident","wind_charge","explosion","generic","magic","in_fire","generic_kill"))
        for(int scene=0;scene<2;scene++) {
          var d=new EnderDragon(EntityTypes.ENDER_DRAGON,level); d.snapTo(0,80,0,0,0);
          d.getPhaseManager().setPhase(EnderDragonPhase.getById(phase));
          d.setHealth(scene==0 ? 200 : 4); cooldown.setInt(d,scene==0 ? 0 : 20);
          MobAiOracle.field(LivingEntity.class,"lastHurt").setFloat(d,scene==0 ? 0 : 3);
          DragonFlightOracle.set(d,"sittingDamageReceived",scene==0 ? 49f : 0f);
          Entity direct=switch(source) {
            case "arrow" -> new Arrow(EntityTypes.ARROW,level);
            case "trident" -> new ThrownTrident(EntityTypes.TRIDENT,level);
            case "wind_charge" -> new WindCharge(EntityTypes.WIND_CHARGE,level);
            default -> null;
          };
          DamageSource damage=switch(source) {
            case "player_attack" -> level.damageSources().playerAttack(player);
            case "mob_attack" -> level.damageSources().mobAttack(other);
            case "arrow" -> level.damageSources().arrow((AbstractArrow)direct,player);
            case "trident" -> level.damageSources().trident(direct,player);
            case "wind_charge" -> level.damageSources().windCharge(direct,player);
            case "explosion" -> level.damageSources().explosion(null,null);
            case "magic" -> level.damageSources().magic();
            case "in_fire" -> level.damageSources().inFire();
            case "generic_kill" -> level.damageSources().genericKill();
            default -> level.damageSources().generic();
          };
          var row=new JsonObject(); row.addProperty("phase",phase); row.addProperty("part",part);
          row.addProperty("source",source); row.addProperty("scene",scene); var hits=new JsonArray();
          float[] amounts={0,.008f,.01f,1,8,32,220}; int[] delays={0,0,1,0,11,0,11};
          for(int i=0;i<amounts.length;i++) {
            for(int t=0;t<delays[i];t++) { cooldown.setInt(d,Math.max(0,cooldown.getInt(d)-1)); d.hurtTime=Math.max(0,d.hurtTime-1); }
            if(direct!=null) direct.setRemainingFireTicks(0);
            boolean admitted=d.getSubEntities()[part].hurtServer(level,damage,amounts[i]);
            var hit=new JsonObject(); hit.addProperty("amount",(double)amounts[i]); hit.addProperty("delay",delays[i]);
            hit.addProperty("admitted",admitted); hit.addProperty("health",(double)d.getHealth());
            hit.addProperty("cooldown",cooldown.getInt(d)); hit.addProperty("hurt_time",d.hurtTime);
            hit.addProperty("last_hurt",(double)MobAiOracle.field(LivingEntity.class,"lastHurt").getFloat(d));
            hit.addProperty("sitting_damage",((Number)DragonFlightOracle.field(d,"sittingDamageReceived")).doubleValue());
            hit.addProperty("phase",d.getPhaseManager().getCurrentPhase().getPhase().getId());
            hit.addProperty("projectile_fire",direct==null ? 0 : direct.getRemainingFireTicks()); hits.add(hit);
          }
          row.add("hits",hits); cases.add(row);
        }
    var packets=new JsonArray();
    var phaseAccessor=(net.minecraft.network.syncher.EntityDataAccessor<?>)MobAiOracle.field(EnderDragon.class,"DATA_PHASE").get(null);
    for(int phase=0;phase<11;phase++) {
      var d=new EnderDragon(EntityTypes.ENDER_DRAGON,level); d.setId(300);
      d.getPhaseManager().setPhase(EnderDragonPhase.getById(phase));
      var values=d.getEntityData().getNonDefaultValues();
      var packet=new net.minecraft.network.protocol.game.ClientboundSetEntityDataPacket(300,
        values==null ? List.of() : values.stream().filter(v -> v.id()==phaseAccessor.id()).toList());
      var row=new JsonObject(); row.addProperty("phase",phase);
      row.addProperty("wire",HexFormat.of().formatHex(ExplosionOracle.encode(packet))); packets.add(row);
    }
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("server_sha1",VersionMetadata.serverSha1()); out.add("cases",cases); out.add("packets",packets);
    Files.writeString(Path.of(args[0]),new GsonBuilder().create().toJson(out));
  }
}
