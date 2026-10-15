import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.*;

/** Actual ordered Entity.checkInsideBlocks callbacks in a supplied immutable block scene. */
public class StuckContactOracle {
  static class ProbeLevel extends ServerLevel {
    Map<BlockPos,BlockState> blocks;Map<BlockPos,BlockState> observed;BlockPos visiting;RandomSource random;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){visiting=pos.immutable();var s=blocks.getOrDefault(visiting,Blocks.AIR.defaultBlockState());observed.put(visiting,s);return s;}
    public RandomSource getRandom(){return random;}
  }
  static class Probe extends Player {
    ProbeLevel world;EntityDimensions dimensions;Vec3 feet;boolean spectator,weaving;BlockPos lastPos;BlockState lastState;
    private Probe(){super(null,null);}
    public GameType gameMode(){return spectator?GameType.SPECTATOR:GameType.CREATIVE;}
    public ServerLevel level(){return world;}
    public float getHealth(){return 20.0f;}
    protected AABB makeBoundingBox(Vec3 pos){return dimensions.makeBoundingBox(pos);}
    public boolean isDescending(){return false;}
    public ItemStack getMainHandItem(){return ItemStack.EMPTY;}
    public ItemStack getItemBySlot(EquipmentSlot slot){return ItemStack.EMPTY;}
    public boolean hasEffect(Holder<MobEffect> type){return type==MobEffects.WEAVING&&weaving;}
    public Vec3 getKnownMovement(){return Vec3.ZERO;}
    public BlockState getInBlockState(){return world.blocks.getOrDefault(BlockPos.containing(feet),Blocks.AIR.defaultBlockState());}
    public void makeStuckInBlock(BlockState state,Vec3 multiplier){
      super.makeStuckInBlock(state,multiplier);
      if(!getAbilities().flying){lastPos=world.visiting;lastState=state;}
    }
    Vec3 multiplier(){return stuckSpeedMultiplier;}
    void clear(){stuckSpeedMultiplier=null;lastPos=null;lastState=null;}
  }
  static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  static JsonArray vec(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  static JsonArray pos(BlockPos p){var a=new JsonArray();a.add(p.getX());a.add(p.getY());a.add(p.getZ());return a;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var p=(Probe)u.allocateInstance(Probe.class);var world=(ProbeLevel)u.allocateInstance(ProbeLevel.class);p.world=world;world.random=RandomSource.create(15017);
    var abilities=new Abilities();field(Player.class,"abilities").set(p,abilities);field(Entity.class,"type").set(p,EntityTypes.PLAYER);field(Entity.class,"visitedBlocks").set(p,new LongOpenHashSet());
    var dimensions=(Map<Pose,EntityDimensions>)field(Avatar.class,"POSES").get(null);
    var inside=Entity.class.getDeclaredMethod("checkInsideBlocks",List.class,InsideBlockEffectApplier.StepBasedCollector.class);inside.setAccessible(true);
    var position=field(Entity.class,"position");var movement=Class.forName("net.minecraft.world.entity.Entity$Movement").getDeclaredConstructor(Vec3.class,Vec3.class);movement.setAccessible(true);
    var paths=List.of(new Vec3[]{new Vec3(.5,64,.5),new Vec3(.5,64,.5)},new Vec3[]{new Vec3(.5,64,.5),new Vec3(4.5,64,.5)},new Vec3[]{new Vec3(4.5,64,.5),new Vec3(.5,64,.5)},new Vec3[]{new Vec3(.5,68,.5),new Vec3(.5,64.95,.5)},new Vec3[]{new Vec3(-1,64.95,.5),new Vec3(.5,64.95,.5)},new Vec3[]{new Vec3(.5,64,.5),new Vec3(3.2,64,.5)},new Vec3[]{new Vec3(-.3,64,.5),new Vec3(-.3,64,.5)});
    var cases=new JsonArray();
    for(int scene=0;scene<5;scene++){
      world.blocks=new HashMap<>();
      for(int y=64;y<=66;y++){
        if(scene==1||scene==4)world.blocks.put(new BlockPos(1,y,0),Blocks.COBWEB.defaultBlockState());
        if(scene==2||scene==4)world.blocks.put(new BlockPos(2,y,0),Blocks.SWEET_BERRY_BUSH.defaultBlockState());
        if(scene==3||scene==4)world.blocks.put(new BlockPos(scene==3?0:3,y,0),Blocks.POWDER_SNOW.defaultBlockState());
      }
      for(var path:paths)for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))for(double fall:new double[]{0,5})
        for(boolean flying:new boolean[]{false,true})for(boolean spectator:new boolean[]{false,true})for(boolean weaving:new boolean[]{false,true}){
          p.feet=path[1];position.set(p,p.feet);p.dimensions=dimensions.get(pose);p.weaving=weaving;p.spectator=spectator;p.noPhysics=spectator;p.fallDistance=fall;abilities.flying=flying;p.clear();world.observed=new LinkedHashMap<>();
          try{inside.invoke(p,List.of(movement.newInstance(path[0],path[1])),new InsideBlockEffectApplier.StepBasedCollector());}catch(InvocationTargetException e){throw new RuntimeException(e.getCause());}
          world.observed.put(BlockPos.containing(p.feet),p.getInBlockState());
          var c=new JsonObject();c.addProperty("scene",scene);c.add("from",vec(path[0]));c.add("to",vec(path[1]));c.addProperty("pose",pose.toString().toLowerCase(Locale.ROOT));c.addProperty("fall",fall);c.addProperty("flying",flying);c.addProperty("spectator",spectator);c.addProperty("weaving",weaving);
          var blocks=new JsonArray();for(var entry:world.observed.entrySet()){var b=pos(entry.getKey());b.add(Block.getId(entry.getValue()));blocks.add(b);}c.add("blocks",blocks);
          c.add("multiplier",p.multiplier()==null?JsonNull.INSTANCE:vec(p.multiplier()));c.addProperty("fall_after",p.fallDistance);c.add("last_position",p.lastPos==null?JsonNull.INSTANCE:pos(p.lastPos));c.addProperty("last_state",p.lastState==null?-1:Block.getId(p.lastState));cases.add(c);
        }
    }
    Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native ordered slowing contact scenes, with current feet/fall/pose/flight/spectator/weaving contexts; deferred damage/freezing excluded.");
  }
}
