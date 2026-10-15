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
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/** Execute the native boundary and living callback; health/mode/defenses are deliberately excluded. */
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
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native below-world threshold/callback cases with repeat checks; health, immunity and defenses excluded.");
  }
}
