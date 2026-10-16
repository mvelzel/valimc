import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.BlockStateProperties;
import net.minecraft.world.level.material.FluidState;
import net.minecraft.world.phys.*;
import com.mojang.serialization.Lifecycle;

/** Actual native retained-path geometry and deferred fire/fluid callbacks; health/death excluded. */
public class FireGeometryOracle {
  static class Scene extends FireContactOracle.World {
    Map<BlockPos,BlockState> blocks,observed;
    public net.minecraft.world.level.gamerules.GameRules getGameRules(){return new net.minecraft.world.level.gamerules.GameRules(net.minecraft.world.flag.FeatureFlagSet.of());}
    public BlockState getBlockState(BlockPos p){var pos=p.immutable();var state=blocks.getOrDefault(pos,Blocks.AIR.defaultBlockState());observed.put(pos,state);return state;}
    public FluidState getFluidState(BlockPos p){return getBlockState(p).getFluidState();}
  }
  static class Body extends FireContactOracle.Body {
    EntityDimensions dimensions;Vec3 feet;
    protected AABB makeBoundingBox(Vec3 p){return dimensions.makeBoundingBox(p);}
    public boolean isDescending(){return false;}
    public float getHealth(){return 20.0f;} // No initialized network health field is needed by this probe.
    public void onInsideBlock(BlockState state){} // Advancement delivery is outside this geometry probe.
    public void fillCrashReportCategory(net.minecraft.CrashReportCategory category){}
    public boolean canFreeze(){return false;}
    public boolean hasEffect(Holder<net.minecraft.world.effect.MobEffect> effect){return false;}
    public boolean mayInteract(net.minecraft.server.level.ServerLevel world,BlockPos pos){return false;}
    public ItemStack getItemBySlot(EquipmentSlot slot){return ItemStack.EMPTY;}
    public ItemStack getMainHandItem(){return ItemStack.EMPTY;}
    public Vec3 getKnownMovement(){return Vec3.ZERO;}
    public BlockState getInBlockState(){return ((Scene)world).blocks.getOrDefault(BlockPos.containing(feet),Blocks.AIR.defaultBlockState());}
  }
  record Path(Vec3 from,Vec3 to,Vec3 axis){}
  static Vec3 v(double x,double y,double z){return new Vec3(x,y,z);}
  static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var registry=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    for(var key:original.listElementIds().toList())registry.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);registry.freeze();
    var sources=new DamageSources(new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze());
    var u=(sun.misc.Unsafe)FireContactOracle.field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var world=(Scene)u.allocateInstance(Scene.class);world.sources=sources;
    var body=(Body)u.allocateInstance(Body.class);body.world=world;body.damage=new ArrayList<>();
    var abilities=new Abilities();FireContactOracle.field(Player.class,"abilities").set(body,abilities);
    FireContactOracle.field(Entity.class,"type").set(body,EntityTypes.PLAYER);FireContactOracle.field(Entity.class,"visitedBlocks").set(body,new LongOpenHashSet());
    var dimensions=(Map<Pose,EntityDimensions>)FireContactOracle.field(Avatar.class,"POSES").get(null);
    var inside=Entity.class.getDeclaredMethod("checkInsideBlocks",List.class,InsideBlockEffectApplier.StepBasedCollector.class);inside.setAccessible(true);
    var movement=Class.forName("net.minecraft.world.entity.Entity$Movement");var linear=movement.getDeclaredConstructor(Vec3.class,Vec3.class);linear.setAccessible(true);var axis=movement.getDeclaredConstructor(Vec3.class,Vec3.class,Vec3.class);axis.setAccessible(true);
    var batches=new ArrayList<List<Path>>();
    for(var point:List.of(v(.5,64,.5),v(-.3,64,.5),v(-.30001,64,.5),v(.5,64.8888888955116272,.5),v(.5,64.8888889955116272,.5),v(.5,65,.5)))batches.add(List.of(new Path(point,point,null)));
    batches.add(List.of(new Path(v(-1,64,.5),v(4,64,.5),null)));batches.add(List.of(new Path(v(4,64,.5),v(-1,64,.5),null)));
    batches.add(List.of(new Path(v(.5,64,.5),v(2.5,65,1.5),v(10,1,.1))));batches.add(List.of(new Path(v(.5,64,.5),v(2.5,65,1.5),v(.1,1,10))));
    batches.add(List.of(new Path(v(.5,64,.5),v(64.5,64,.5),null)));
    batches.add(List.of(new Path(v(.5,64,.5),v(1.5,64,.5),null),new Path(v(1.5,64,.5),v(2.5,64,.5),null),new Path(v(2.5,64,.5),v(.5,64,.5),null)));
    var rows=new JsonArray();
    for(int scene=0;scene<11;scene++){
      world.blocks=new HashMap<>();
      if(scene>=1&&scene<=4)world.blocks.put(new BlockPos(0,64,0),switch(scene){case 1->Blocks.FIRE.defaultBlockState();case 2->Blocks.SOUL_FIRE.defaultBlockState();case 3->Blocks.LAVA.defaultBlockState();default->Blocks.WATER.defaultBlockState();});
      if(scene==5||scene==6){world.blocks.put(new BlockPos(1,64,0),scene==5?Blocks.FIRE.defaultBlockState():Blocks.LAVA.defaultBlockState());world.blocks.put(new BlockPos(2,64,0),Blocks.WATER.defaultBlockState());world.blocks.put(new BlockPos(3,64,0),Blocks.SOUL_FIRE.defaultBlockState());}
      if(scene==7)world.blocks.put(new BlockPos(0,64,0),Blocks.OAK_SLAB.defaultBlockState().setValue(BlockStateProperties.WATERLOGGED,true));
      if(scene==8){world.blocks.put(new BlockPos(0,64,0),Blocks.WATER.defaultBlockState().setValue(LiquidBlock.LEVEL,7));world.blocks.put(new BlockPos(0,65,0),Blocks.WATER.defaultBlockState());}
      if(scene==9)for(int x:new int[]{1,20,64})world.blocks.put(new BlockPos(x,64,0),Blocks.FIRE.defaultBlockState());
      if(scene==10){world.blocks.put(new BlockPos(1,64,0),Blocks.COBWEB.defaultBlockState());world.blocks.put(new BlockPos(2,64,0),Blocks.POWDER_SNOW.defaultBlockState());world.blocks.put(new BlockPos(3,64,0),Blocks.SOUL_FIRE.defaultBlockState());}
      for(var batch:batches)for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))for(boolean spectator:new boolean[]{false,true})for(double fall:new double[]{0,5}){
        body.feet=batch.getLast().to();body.dimensions=dimensions.get(pose);body.noPhysics=spectator;body.fallDistance=fall;body.factor=1;body.immune=false;body.frozen=140;body.damage.clear();body.setRemainingFireTicks(-1);
        FireContactOracle.field(Entity.class,"position").set(body,body.feet);
        // Disable only optional server-debug delivery during geometry; bind the real
        // level before deferred Entity.hurt so every native damage callback is observed.
        FireContactOracle.field(Entity.class,"level").set(body,null);
        var draws=new FireContactOracle.Draws(2);world.random=draws.source();world.observed=new LinkedHashMap<>();
        var collector=new InsideBlockEffectApplier.StepBasedCollector();var moves=new ArrayList<Object>();var paths=new JsonArray();
        for(var p:batch){moves.add(p.axis()==null?linear.newInstance(p.from(),p.to()):axis.newInstance(p.from(),p.to(),p.axis()));var x=new JsonObject();x.add("from",vec(p.from()));x.add("to",vec(p.to()));x.add("axis",p.axis()==null?JsonNull.INSTANCE:vec(p.axis()));paths.add(x);}
        try{inside.invoke(body,moves,collector);}catch(InvocationTargetException e){throw new RuntimeException(e.getCause());}
        FireContactOracle.field(Entity.class,"level").set(body,world);collector.applyAndClear(body);
        world.observed.put(BlockPos.containing(body.feet),body.getInBlockState());
        var row=new JsonObject();row.addProperty("scene",scene);row.addProperty("current",-1);row.addProperty("factor",1);row.addProperty("immune",false);row.addProperty("invulnerable",false);row.addProperty("increment",2);row.add("paths",paths);row.add("feet",vec(body.feet));row.addProperty("pose",pose.toString().toLowerCase(Locale.ROOT));row.addProperty("spectator",spectator);row.addProperty("fall",fall);
        var blocks=new JsonArray();for(var e:world.observed.entrySet()){var b=new JsonArray();b.add(e.getKey().getX());b.add(e.getKey().getY());b.add(e.getKey().getZ());b.add(Block.getId(e.getValue()));blocks.add(b);}row.add("blocks",blocks);
        row.addProperty("next",body.getRemainingFireTicks());row.addProperty("frozen",body.frozen);row.addProperty("draws",draws.count);row.add("damage",new Gson().toJsonTree(body.damage));rows.add(row);
      }
    }
    Files.writeString(java.nio.file.Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native retained-path fire/fluid contact scenes; bounds, surfaces, waterlogging, axis order, revisits, long-path fallback, pose/spectator and prior slowing contexts. Health/death excluded.");
  }
}
