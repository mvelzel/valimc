import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import it.unimi.dsi.fastutil.longs.LongOpenHashSet;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.phys.Vec3;

/** Native batch contact ordering, shared hit set, axis movement and step-budget destination fallback. */
public class StuckPathsOracle {
  private record Segment(Vec3 from,Vec3 to,Vec3 axis){}
  private static Vec3 v(double x,double y,double z){return new Vec3(x,y,z);}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var uf=StuckContactOracle.field(sun.misc.Unsafe.class,"theUnsafe");var u=(sun.misc.Unsafe)uf.get(null);
    var p=(StuckContactOracle.Probe)u.allocateInstance(StuckContactOracle.Probe.class);var w=(StuckContactOracle.ProbeLevel)u.allocateInstance(StuckContactOracle.ProbeLevel.class);p.world=w;w.random=RandomSource.create(15018);
    var a=new Abilities();StuckContactOracle.field(Player.class,"abilities").set(p,a);StuckContactOracle.field(Entity.class,"type").set(p,EntityTypes.PLAYER);StuckContactOracle.field(Entity.class,"visitedBlocks").set(p,new LongOpenHashSet());
    var position=StuckContactOracle.field(Entity.class,"position");var dimensions=(Map<Pose,EntityDimensions>)StuckContactOracle.field(Avatar.class,"POSES").get(null);
    var inside=Entity.class.getDeclaredMethod("checkInsideBlocks",List.class,InsideBlockEffectApplier.StepBasedCollector.class);inside.setAccessible(true);
    var movement=Class.forName("net.minecraft.world.entity.Entity$Movement");var linear=movement.getDeclaredConstructor(Vec3.class,Vec3.class);linear.setAccessible(true);var axis=movement.getDeclaredConstructor(Vec3.class,Vec3.class,Vec3.class);axis.setAccessible(true);
    var batches=new ArrayList<List<Segment>>();
    batches.add(List.of(new Segment(v(.5,64,.5),v(1.5,64,.5),null),new Segment(v(1.5,64,.5),v(2.5,64,.5),null),new Segment(v(2.5,64,.5),v(1.5,64,.5),null)));
    batches.add(List.of(new Segment(v(.5,64,.5),v(2.5,65,1.5),v(10,1,.1))));
    batches.add(List.of(new Segment(v(.5,64,.5),v(2.5,65,1.5),v(.1,1,10))));
    batches.add(List.of(new Segment(v(.5,64,.5),v(64.5,64,.5),null)));
    batches.add(List.of(new Segment(v(.5,64,.5),v(64.5,0,64.5),v(64,-64,64))));
    batches.add(List.of(new Segment(v(.5,64.95,.5),v(3.2,64.95,.5),v(2.7,0,0)),new Segment(v(3.2,64.95,.5),v(.5,64.95,.5),null)));
    var random=new Random(15019);
    for(int n=0;n<12;n++){
      var batch=new ArrayList<Segment>();var from=v(.5,64,.5);
      for(int j=0;j<8;j++){var to=from.add(random.nextDouble()*4-2,random.nextDouble()*2-1,random.nextDouble()*4-2);batch.add(new Segment(from,to,j%2==0?to.subtract(from):null));from=to;}
      batches.add(batch);
    }
    var cases=new JsonArray();
    for(int scene=0;scene<4;scene++){
      w.blocks=new HashMap<>();
      for(int y=63;y<=66;y++)for(int z=-1;z<=2;z++){
        w.blocks.put(new BlockPos(1,y,z),Blocks.COBWEB.defaultBlockState());w.blocks.put(new BlockPos(2,y,z),Blocks.SWEET_BERRY_BUSH.defaultBlockState());
        if(scene>0)w.blocks.put(new BlockPos(3,y,z),Blocks.POWDER_SNOW.defaultBlockState());
      }
      if(scene==1){w.blocks.put(new BlockPos(4,64,0),Blocks.COBWEB.defaultBlockState());w.blocks.put(new BlockPos(20,64,0),Blocks.SWEET_BERRY_BUSH.defaultBlockState());}
      if(scene==2){w.blocks.put(new BlockPos(20,64,0),Blocks.COBWEB.defaultBlockState());w.blocks.put(new BlockPos(64,64,0),Blocks.SWEET_BERRY_BUSH.defaultBlockState());w.blocks.put(new BlockPos(64,0,64),Blocks.COBWEB.defaultBlockState());}
      if(scene==3){w.blocks.put(new BlockPos(0,63,0),Blocks.COBWEB.defaultBlockState());w.blocks.put(new BlockPos(64,0,64),Blocks.SWEET_BERRY_BUSH.defaultBlockState());}
      for(var batch:batches)for(var pose:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING))for(double fall:new double[]{0,5})for(int flags=0;flags<8;flags++){
        p.feet=batch.getLast().to();position.set(p,p.feet);p.dimensions=dimensions.get(pose);p.weaving=(flags&1)!=0;p.spectator=(flags&2)!=0;p.noPhysics=p.spectator;p.fallDistance=fall;a.flying=(flags&4)!=0;p.clear();w.observed=new LinkedHashMap<>();
        var movements=new ArrayList<Object>();var ps=new JsonArray();
        for(var segment:batch){movements.add(segment.axis()==null?linear.newInstance(segment.from(),segment.to()):axis.newInstance(segment.from(),segment.to(),segment.axis()));var x=new JsonObject();x.add("from",StuckContactOracle.vec(segment.from()));x.add("to",StuckContactOracle.vec(segment.to()));x.add("axis",segment.axis()==null?JsonNull.INSTANCE:StuckContactOracle.vec(segment.axis()));ps.add(x);}
        try{inside.invoke(p,movements,new InsideBlockEffectApplier.StepBasedCollector());}catch(InvocationTargetException e){throw new RuntimeException(e.getCause());}
        w.observed.put(BlockPos.containing(p.feet),p.getInBlockState());var c=new JsonObject();c.addProperty("scene",scene);c.add("paths",ps);c.add("feet",StuckContactOracle.vec(p.feet));c.addProperty("pose",pose.toString().toLowerCase(Locale.ROOT));c.addProperty("fall",fall);c.addProperty("flying",a.flying);c.addProperty("spectator",p.spectator);c.addProperty("weaving",p.weaving);
        var blocks=new JsonArray();for(var entry:w.observed.entrySet()){var b=StuckContactOracle.pos(entry.getKey());b.add(Block.getId(entry.getValue()));blocks.add(b);}c.add("blocks",blocks);
        c.add("multiplier",p.multiplier()==null?JsonNull.INSTANCE:StuckContactOracle.vec(p.multiplier()));c.addProperty("fall_after",p.fallDistance);c.add("last_position",p.lastPos==null?JsonNull.INSTANCE:StuckContactOracle.pos(p.lastPos));c.addProperty("last_state",p.lastState==null?-1:Block.getId(p.lastState));cases.add(c);
      }
    }
    Files.writeString(Path.of(args[0]),new GsonBuilder().serializeNulls().create().toJson(cases));System.out.println("PASS: "+cases.size()+" actual native contact batches with revisits, axis order and long-move fallback.");
  }
}
