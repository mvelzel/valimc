import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.io.ByteArrayOutputStream;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.network.syncher.SynchedEntityData;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.storage.*;

/** Observes actual fallOn damage calls; block mutations, sound and health are excluded. */
public class LandingOracle {
  private static class ProbeLevel extends ServerLevel {
    DamageSources sources; RandomSource random;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public DamageSources damageSources(){return sources;}
    public RandomSource getRandom(){return random;}
    public void broadcastEntityEvent(Entity entity,byte event){}
  }
  private static class ProbeEntity extends Entity {
    ProbeLevel world; boolean shift; JsonObject call; DamageSource fall,stalagmite;
    private ProbeEntity(){super(null,null);}
    protected void defineSynchedData(SynchedEntityData.Builder builder){}
    protected void readAdditionalSaveData(ValueInput input){}
    protected void addAdditionalSaveData(ValueOutput output){}
    public Level level(){return world;}
    public boolean isSuppressingBounce(){return shift;}
    public void playSound(SoundEvent sound,float volume,float pitch){}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){throw new AssertionError("Unexpected direct damage");}
    public boolean causeFallDamage(double distance,float multiplier,DamageSource source){
      if(call!=null)throw new AssertionError("Multiple fall damage calls");
      call=new JsonObject();call.addProperty("distance",distance);call.addProperty("multiplier",(double)multiplier);
      if(source!=fall&&source!=stalagmite)throw new AssertionError("Unexpected source");
      call.addProperty("source",source==fall?"fall":"stalagmite");return false;
    }
    JsonObject observe(BlockState state,double distance,boolean shift){
      this.shift=shift;call=null;state.getBlock().fallOn(world,state,BlockPos.ZERO,this,distance);return call;
    }
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonElement spec(ProbeEntity entity,BlockState state,boolean shift){
    var zero=entity.observe(state,0,shift);var eight=entity.observe(state,8,shift);var far=entity.observe(state,64,shift);
    if(zero==null||eight==null||far==null){
      if(zero!=null||eight!=null||far!=null)throw new AssertionError("Distance-dependent callback "+state);
      return JsonNull.INSTANCE;
    }
    double offset=zero.get("distance").getAsDouble(),scale=(eight.get("distance").getAsDouble()-offset)/8;
    if(far.get("distance").getAsDouble()!=64*scale+offset||!zero.get("source").equals(eight.get("source"))||!eight.get("source").equals(far.get("source"))||!zero.get("multiplier").equals(eight.get("multiplier"))||!eight.get("multiplier").equals(far.get("multiplier")))
      throw new AssertionError("Non-affine landing rule "+state);
    var result=new JsonObject();result.addProperty("distance_scale",scale);result.addProperty("distance_offset",offset);
    result.add("multiplier",eight.get("multiplier"));result.add("source",eight.get("source"));return result;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);world.random=RandomSource.create(1);
    world.sources=(DamageSources)unsafe.allocateInstance(DamageSources.class);
    var entity=(ProbeEntity)unsafe.allocateInstance(ProbeEntity.class);entity.world=world;
    entity.fall=(DamageSource)unsafe.allocateInstance(DamageSource.class);entity.stalagmite=(DamageSource)unsafe.allocateInstance(DamageSource.class);
    field(DamageSources.class,"fall").set(world.sources,entity.fall);field(DamageSources.class,"stalagmite").set(world.sources,entity.stalagmite);
    var gson=new Gson();var properties=new JsonArray();var indexes=new LinkedHashMap<String,Integer>();
    var states=new ByteArrayOutputStream();var cases=new JsonArray();int observed=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=states.size())throw new AssertionError("Non-contiguous states");
      var facts=new JsonArray();facts.add(spec(entity,state,false));facts.add(spec(entity,state,true));observed+=6;
      var key=gson.toJson(facts);Integer index=indexes.get(key);
      if(index==null){index=properties.size();indexes.put(key,index);properties.add(facts);}
      if(index>255)throw new AssertionError("Too many landing rules");states.write(index);
      for(boolean shift:new boolean[]{false,true}){
        var c=new JsonObject();c.addProperty("id",Block.getId(state));c.addProperty("shift",shift);c.addProperty("distance",8);
        c.add("call",entity.observe(state,8,shift));cases.add(c);observed++;
      }
    }
    // Independent thresholds and remote distances for each distinct rule/shift.
    var representatives=new HashSet<Integer>();var packed=states.toByteArray();
    for(var state:Block.BLOCK_STATE_REGISTRY){
      int index=packed[Block.getId(state)]&255;
      if(!representatives.add(index))continue;
      for(boolean shift:new boolean[]{false,true})for(double distance:new double[]{0,2.999999,3.999998,4,6,19.25,60000000}){
        var c=new JsonObject();c.addProperty("id",Block.getId(state));c.addProperty("shift",shift);c.addProperty("distance",distance);
        c.add("call",entity.observe(state,distance,shift));cases.add(c);observed++;
      }
    }
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);
    result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");result.addProperty("state_count",states.size());
    result.add("properties",properties);result.addProperty("states",HexFormat.of().formatHex(packed));
    Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+observed+" native fallOn observations / "+states.size()+" states / "+properties.size()+" rules; "+cases.size()+" exported cases. Nonliving observer excludes terrain mutations and powder-snow sounds.");
    for(var block:List.of(Blocks.BED.red(),Blocks.HAY_BLOCK,Blocks.HONEY_BLOCK,Blocks.SLIME_BLOCK,Blocks.POWDER_SNOW))
      System.out.println(net.minecraft.core.registries.BuiltInRegistries.BLOCK.getKey(block)+" state="+Block.getId(block.defaultBlockState()));
  }
}
