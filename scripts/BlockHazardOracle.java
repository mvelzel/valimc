import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.phys.Vec3;

/** Actual stock player hazard requests; captures immediate callbacks, not health or defenses. */
public class BlockHazardOracle {
  static class Body extends FireContactOracle.Body {
    boolean careful,client;Vec3 movement,previous,stuck;
    public boolean isSteppingCarefully(){return careful;}
    public boolean isClientAuthoritative(){return client;}
    public Vec3 getKnownMovement(){return movement;}
    public Vec3 position(){return Vec3.ZERO;}
    public void makeStuckInBlock(BlockState state,Vec3 multiplier){stuck=multiplier;}
  }
  static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var registry=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    for(var key:original.listElementIds().toList())registry.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);registry.freeze();
    var sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze());
    var u=(sun.misc.Unsafe)FireContactOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(FireContactOracle.World)u.allocateInstance(FireContactOracle.World.class);world.sources=sources;
    var body=(Body)u.allocateInstance(Body.class);body.world=world;body.damage=new ArrayList<>();
    FireContactOracle.field(Entity.class,"level").set(body,world);FireContactOracle.field(Entity.class,"type").set(body,EntityTypes.PLAYER);
    FireContactOracle.field(Player.class,"abilities").set(body,new net.minecraft.world.entity.player.Abilities());
    var insideTypes=new Class<?>[]{BlockState.class,Level.class,BlockPos.class,Entity.class,InsideBlockEffectApplier.class,boolean.class};
    var campfire=CampfireBlock.class.getDeclaredMethod("entityInside",insideTypes);campfire.setAccessible(true);
    var cactus=CactusBlock.class.getDeclaredMethod("entityInside",insideTypes);cactus.setAccessible(true);
    var berry=SweetBerryBushBlock.class.getDeclaredMethod("entityInside",insideTypes);berry.setAccessible(true);
    var damageField=CampfireBlock.class.getDeclaredField("fireDamage");damageField.setAccessible(true);
    var oldX=FireContactOracle.field(Entity.class,"xOld");var oldY=FireContactOracle.field(Entity.class,"yOld");var oldZ=FireContactOracle.field(Entity.class,"zOld");
    double threshold=(double).003f;
    var moves=List.of(Vec3.ZERO,new Vec3(.003,0,0),new Vec3(threshold,0,0),new Vec3(Math.nextDown(threshold),0,0),new Vec3(0,0,threshold),new Vec3(-threshold,64,0),new Vec3(0,64,0),new Vec3(1e-12,0,1e-12),new Vec3(64,0,-64));
    var states=new JsonArray();var rows=new JsonArray();int count=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      String kind;int value;
      if(state.is(Blocks.MAGMA_BLOCK)){kind="magma";value=1;}
      else if(state.is(Blocks.CAMPFIRE)||state.is(Blocks.SOUL_CAMPFIRE)){kind="campfire";value=state.getValue(BlockStateProperties.LIT)?damageField.getInt(state.getBlock()):0;}
      else if(state.is(Blocks.CACTUS)){kind="cactus";value=1;}
      else if(state.is(Blocks.SWEET_BERRY_BUSH)){kind="berry";value=state.getValue(BlockStateProperties.AGE_3);}
      else continue;
      var fact=new JsonArray();fact.add(Block.getId(state));fact.add(kind);fact.add(value);states.add(fact);count++;
      for(boolean careful:new boolean[]{false,true})for(boolean client:new boolean[]{false,true})for(int i=0;i<moves.size();i++){
        body.careful=careful;body.client=client;body.movement=moves.get(i);body.previous=moves.get(moves.size()-1-i);body.stuck=null;body.damage.clear();
        oldX.setDouble(body,body.previous.x);oldY.setDouble(body,body.previous.y);oldZ.setDouble(body,body.previous.z);
        var collector=new InsideBlockEffectApplier.StepBasedCollector();
        switch(kind){
          case "magma"->state.getBlock().stepOn(world,BlockPos.ZERO,state,body);
          case "campfire"->campfire.invoke(state.getBlock(),state,world,BlockPos.ZERO,body,collector,false);
          case "cactus"->cactus.invoke(state.getBlock(),state,world,BlockPos.ZERO,body,collector,false);
          case "berry"->berry.invoke(state.getBlock(),state,world,BlockPos.ZERO,body,collector,false);
        }
        var before=new ArrayList<>(body.damage);collector.applyAndClear(body);
        if(!body.damage.equals(before))throw new AssertionError("Hazard unexpectedly deferred damage");
        if(kind.equals("berry")!=(body.stuck!=null))throw new AssertionError("Unexpected slowing callback");
        var row=new JsonObject();row.addProperty("state",Block.getId(state));row.addProperty("careful",careful);row.addProperty("client",client);row.add("known",vector(body.movement));row.add("previous",vector(body.previous));row.add("damage",new Gson().toJsonTree(body.damage));rows.add(row);
      }
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.addProperty("state_count",Block.BLOCK_STATE_REGISTRY.size());facts.add("states",states);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+count+" stock hazard states and "+rows.size()+" actual player callback requests; careful/lit/age gates, native float movement boundaries and immediate/deferred distinction. Geometry, immunity, health and wear excluded.");
  }
}
