import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.tags.TagKey;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EquipmentSlot;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/** Native boundary/callback and ServerPlayer load immunity; full health/world tick excluded. */
public class PlayerVoidOracle {
  private static class ProbeLevel extends ServerLevel {
    int minimum;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public int getMinY(){return minimum;}
  }
  private static class Probe extends Player {
    ProbeLevel world; DamageSources sources; int calls; float amount; String source;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public DamageSources damageSources(){return sources;}
    public boolean hurtServer(ServerLevel level,DamageSource damage,float value){
      calls++;amount=value;source=damage.typeHolder().unwrapKey().orElseThrow().identifier().toString();return true;
    }
  }
  private static class ServerProbe extends ServerPlayer {
    GameType mode;
    private ServerProbe(){super(null,null,null,null);}
    public GameType gameMode(){return mode;}
    public ItemStack getItemBySlot(EquipmentSlot slot){return ItemStack.EMPTY;}
  }
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var source=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);var damage=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var id:source.listElementIds().toList())damage.register(id,source.getOrThrow(id).value(),RegistrationInfo.BUILT_IN);
    damage.freeze();var access=new RegistryAccess.ImmutableRegistryAccess(List.of(damage)).freeze();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);var p=(Probe)unsafe.allocateInstance(Probe.class);p.world=world;p.sources=new DamageSources(access);
    field(Entity.class,"level").set(p,world);var cases=new JsonArray();
    for(int minimum:new int[]{-64,0,320}){
      world.minimum=minimum;double boundary=minimum-64;
      for(double y:new double[]{-1000000,boundary-1,Math.nextDown(boundary),boundary,Math.nextUp(boundary),boundary+1,1000000}){
        field(Entity.class,"position").set(p,new Vec3(.5,y,.5));p.calls=0;p.amount=0;p.source=null;
        p.checkBelowWorld();p.checkBelowWorld();var c=new JsonObject();c.addProperty("minimum",minimum);c.addProperty("y",y);c.addProperty("calls",p.calls);c.addProperty("amount",p.amount);c.addProperty("source",p.source);cases.add(c);
      }
    }
    var holder=damage.getOrThrow(DamageTypes.FELL_OUT_OF_WORLD);
    var names=JsonParser.parseString(Files.readString(Path.of("priv/protocol/registries.json"))).getAsJsonObject().getAsJsonArray("minecraft:damage_type");
    int id=-1;for(int i=0;i<names.size();i++)if(names.get(i).getAsString().equals("minecraft:out_of_world"))id=i;
    if(id<0)throw new AssertionError("Missing void source");
    var tags=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject().getAsJsonObject("minecraft:damage_type");
    var keys=new ArrayList<TagKey<DamageType>>();for(var e:tags.entrySet())for(var value:e.getValue().getAsJsonArray())if(value.getAsInt()==id)keys.add(TagKey.create(Registries.DAMAGE_TYPE,net.minecraft.resources.Identifier.parse(e.getKey())));
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);bind.invoke(holder,keys);
    var sp=(ServerProbe)unsafe.allocateInstance(ServerProbe.class);var sourceDamage=new DamageSource(holder);var loading=new JsonArray();
    var restart=ServerGamePacketListenerImpl.class.getDeclaredMethod("restartClientLoadTimerAfterRespawn");restart.setAccessible(true);
    var mark=ServerGamePacketListenerImpl.class.getDeclaredMethod("markClientLoaded");mark.setAccessible(true);
    for(var mode:GameType.values())for(int ticks=0;ticks<=64;ticks++){
      sp.mode=mode;var abilities=new net.minecraft.world.entity.player.Abilities();mode.updatePlayerAbilities(abilities);field(Player.class,"abilities").set(sp,abilities);
      var listener=(ServerGamePacketListenerImpl)unsafe.allocateInstance(ServerGamePacketListenerImpl.class);restart.invoke(listener);for(int n=0;n<ticks;n++)listener.tickClientLoadTimeout();sp.connection=listener;
      var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("ticks",ticks);c.addProperty("loaded",listener.hasClientLoaded());c.addProperty("immune",sp.isInvulnerableTo(null,sourceDamage));
      mark.invoke(listener);c.addProperty("marked_immune",sp.isInvulnerableTo(null,sourceDamage));loading.add(c);
    }
    var result=new JsonObject();result.add("boundaries",cases);result.add("loading",loading);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native below-world threshold/callback cases and "+loading.size()+" actual ServerPlayer void loading-immunity cases; full health/world tick excluded.");
  }
}
