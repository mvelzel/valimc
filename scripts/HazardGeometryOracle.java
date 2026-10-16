import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import java.nio.file.*;
import java.util.*;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.debug.ServerDebugSubscribers;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.phys.Vec3;

/** Native support, retained-path immediate damage, then deferred fire effects; controlled health gate. */
public class HazardGeometryOracle {
  static class Server extends DedicatedServer {
    ServerDebugSubscribers subscribers;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ServerDebugSubscribers debugSubscribers(){return subscribers;}
  }
  static class World extends FireGeometryOracle.Scene {
    Server server;
    public MinecraftServer getServer(){return server;}
    public boolean isRainingAt(BlockPos pos){return false;}
  }
  static class Body extends FireGeometryOracle.Body {
    boolean grounded,careful,client,alive;Vec3 known;int deathAt;
    public boolean onGround(){return grounded;}
    public boolean isSteppingCarefully(){return careful;}
    public boolean isClientAuthoritative(){return client;}
    public Vec3 getKnownMovement(){return known;}
    public void makeStuckInBlock(BlockState state,Vec3 multiplier){}
    public boolean isAlive(){return alive;}
    public int getTicksFrozen(){return frozen;}
    public boolean hurtServer(ServerLevel level,DamageSource source,float amount){
      boolean result=super.hurtServer(level,source,amount);if(deathAt>0&&damage.size()>=deathAt)alive=false;return result;
    }
  }
  static Vec3 v(double x,double y,double z){return new Vec3(x,y,z);}
  public static void main(String[] args)throws Exception {
    var lookup=MiningToolOracle.initialize();var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var registry=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var key:original.listElementIds().toList())registry.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);registry.freeze();
    var u=(sun.misc.Unsafe)FireContactOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var server=(Server)u.allocateInstance(Server.class);server.subscribers=new ServerDebugSubscribers(server);
    var world=(World)u.allocateInstance(World.class);world.server=server;world.sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze());
    var body=(Body)u.allocateInstance(Body.class);body.world=world;body.damage=new ArrayList<>();body.mainSupportingBlockPos=Optional.empty();
    FireContactOracle.field(Entity.class,"level").set(body,world);FireContactOracle.field(Entity.class,"type").set(body,EntityTypes.PLAYER);
    FireContactOracle.field(Entity.class,"visitedBlocks").set(body,new LongOpenHashSet());FireContactOracle.field(Player.class,"abilities").set(body,new Abilities());
    var dimensions=(Map<Pose,EntityDimensions>)FireContactOracle.field(Avatar.class,"POSES").get(null);
    var rows=new JsonArray();
    var paths=List.of(new Vec3[]{v(.5,64,.5),v(.5,64,.5)},new Vec3[]{v(-1,64,.5),v(4,64,.5)},new Vec3[]{v(4,64,.5),v(-1,64,.5)},new Vec3[]{v(.5,64.0625,.5),v(.5,64.0625,.5)},new Vec3[]{v(.5,64.4375,.5),v(.5,64.4375,.5)},new Vec3[]{v(.5,65,.5),v(.5,65,.5)});
    for(int scene=0;scene<12;scene++)for(var path:paths)for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))for(boolean grounded:new boolean[]{false,true})for(boolean careful:new boolean[]{false,true})for(int death:new int[]{0,1}){
      world.blocks=new HashMap<>();world.observed=new LinkedHashMap<>();
      BlockState contact=switch(scene){case 0->Blocks.CACTUS.defaultBlockState();case 1->Blocks.CAMPFIRE.defaultBlockState();case 2->Blocks.SOUL_CAMPFIRE.defaultBlockState();case 3->Blocks.CAMPFIRE.defaultBlockState().setValue(BlockStateProperties.LIT,false);case 4->Blocks.SWEET_BERRY_BUSH.defaultBlockState().setValue(BlockStateProperties.AGE_3,3);case 5->Blocks.SWEET_BERRY_BUSH.defaultBlockState();default->Blocks.AIR.defaultBlockState();};
      world.blocks.put(new BlockPos(0,64,0),contact);world.blocks.put(new BlockPos(0,63,0),Blocks.MAGMA_BLOCK.defaultBlockState());
      if(scene>=6){world.blocks.put(new BlockPos(0,64,0),Blocks.FIRE.defaultBlockState());world.blocks.put(new BlockPos(1,64,0),scene==6?Blocks.CACTUS.defaultBlockState():scene==7?Blocks.CAMPFIRE.defaultBlockState():Blocks.SWEET_BERRY_BUSH.defaultBlockState().setValue(BlockStateProperties.AGE_3,3));world.blocks.put(new BlockPos(2,64,0),scene==9?Blocks.LAVA.defaultBlockState():Blocks.WATER.defaultBlockState());world.blocks.put(new BlockPos(3,64,0),Blocks.SOUL_FIRE.defaultBlockState());}
      if(scene==10||scene==11){world.blocks.put(new BlockPos(0,64,0),scene==10?Blocks.CACTUS.defaultBlockState():Blocks.CAMPFIRE.defaultBlockState());world.blocks.put(new BlockPos(1,64,0),Blocks.FIRE.defaultBlockState());world.blocks.put(new BlockPos(2,64,0),Blocks.CACTUS.defaultBlockState());}
      body.feet=path[1];body.dimensions=dimensions.get(pose);body.grounded=grounded;body.careful=careful;body.client=true;body.known=path[1].subtract(path[0]);body.alive=true;body.deathAt=death;
      body.noPhysics=false;body.fallDistance=5;body.factor=1;body.immune=false;body.frozen=140;body.damage.clear();body.setRemainingFireTicks(-1);
      FireContactOracle.field(Entity.class,"position").set(body,body.feet);FireContactOracle.field(Entity.class,"bb").set(body,body.dimensions.makeBoundingBox(body.feet));
      FireContactOracle.field(Entity.class,"blockPosition").set(body,BlockPos.containing(body.feet));
      FireContactOracle.field(Entity.class,"insideEffectCollector").set(body,new InsideBlockEffectApplier.StepBasedCollector());
      var draws=new FireContactOracle.Draws(2);world.random=draws.source();
      body.applyEffectsFromBlocks(path[0],path[1]);
      var row=new JsonObject();row.addProperty("scene",scene);row.add("from",FireGeometryOracle.vec(path[0]));row.add("to",FireGeometryOracle.vec(path[1]));row.addProperty("pose",pose.toString().toLowerCase(Locale.ROOT));row.addProperty("grounded",grounded);row.addProperty("careful",careful);row.addProperty("death_at",death);
      var blocks=new JsonArray();for(int x=-2;x<=5;x++)for(int y=62;y<=68;y++)for(int z=-1;z<=1;z++){var b=new JsonArray();b.add(x);b.add(y);b.add(z);b.add(Block.getId(world.blocks.getOrDefault(new BlockPos(x,y,z),Blocks.AIR.defaultBlockState())));blocks.add(b);}row.add("blocks",blocks);
      row.add("damage",new Gson().toJsonTree(body.damage));row.addProperty("alive",body.alive);row.addProperty("fire",body.getRemainingFireTicks());row.addProperty("draws",draws.count);row.addProperty("frozen",body.frozen);rows.add(row);
    }
    Files.writeString(java.nio.file.Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual Entity support/inside/deferred contact traces, mixed hazards/fire/water, poses, native bounds, grounded/careful and first-hit death gates. Armor/real health/cooldowns and movement acceptance excluded.");
  }
}
