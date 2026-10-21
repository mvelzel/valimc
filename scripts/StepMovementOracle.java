import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;
import sun.misc.Unsafe;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;

/** Controlled collider providers invoke the whole native Entity.collide method. */
public class StepMovementOracle {
  private static class ProbeEntity extends ItemEntity {
    float step;boolean grounded;
    private ProbeEntity(){super(EntityTypes.ITEM,null);}
    public float maxUpStep(){return step;}
    public boolean onGround(){return grounded;}
  }
  private static class ProbeBorder extends WorldBorder {
    public boolean isInsideCloseToBorder(Entity entity,AABB box){return false;}
  }
  private static class ProbeLevel extends ServerLevel {
    List<VoxelShape> initial,steps;List<AABB> queries;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public List<VoxelShape> getEntityCollisions(Entity entity,AABB box){return List.of();}
    public WorldBorder getWorldBorder(){return border;}
    public Iterable<VoxelShape> getBlockCollisions(Entity entity,AABB box) {
      queries.add(box);return queries.size()==1?initial:steps;
    }
  }
  private static final ProbeBorder border=new ProbeBorder();
  private static final Gson gson=new Gson();
  private static final JsonArray geometries=new JsonArray(),cases=new JsonArray(),heightCases=new JsonArray();
  private static final Map<String,Integer> ids=new LinkedHashMap<>();
  private static Unsafe unsafe;private static Method collide,candidates;
  private static Field levelField,boxField;
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  private static JsonArray box(AABB b){return vector(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ);}
  private static JsonArray bits(Vec3 v){var a=new JsonArray();for(double d:new double[]{v.x,v.y,v.z})a.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(d)));return a;}
  private static Field field(Class<?> c,String name) throws Exception {var f=c.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonArray shapeIds(List<VoxelShape> shapes) throws Exception {
    var a=new JsonArray();for(var shape:shapes) {
      var geometry=BlockFactsOracle.geometry(shape);String key=gson.toJson(geometry);
      int id=ids.computeIfAbsent(key,k->{geometries.add(geometry);return geometries.size()-1;});a.add(id);
    }return a;
  }
  private static void probe(AABB box,List<VoxelShape> initial,List<VoxelShape> steps,Vec3 request,float maxStep,boolean ground,Vec3 offset) throws Exception {
    var e=(ProbeEntity)unsafe.allocateInstance(ProbeEntity.class);var level=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    e.step=maxStep;e.grounded=ground;level.queries=new ArrayList<>();
    level.initial=initial.stream().map(s->s.move(offset.x,offset.y,offset.z)).toList();
    level.steps=steps.stream().map(s->s.move(offset.x,offset.y,offset.z)).toList();
    var worldBox=box.move(offset);levelField.set(e,level);boxField.set(e,worldBox);
    var result=(Vec3)collide.invoke(e,request);var c=new JsonObject();
    c.add("box",box(worldBox));c.add("offset",vector(offset.x,offset.y,offset.z));c.add("initial",shapeIds(initial));c.add("steps",shapeIds(steps));
    c.add("request",vector(request.x,request.y,request.z));c.addProperty("max_step",maxStep);c.addProperty("grounded",ground);
    c.add("result_bits",bits(result));var queries=new JsonArray();for(var q:level.queries)queries.add(box(q));c.add("queries",queries);cases.add(c);
    if(level.queries.size()>2)throw new AssertionError("Unexpected native query phases");
  }
  private static void heights(AABB box,List<VoxelShape> shapes,float max,float previous) throws Exception {
    var result=(float[])candidates.invoke(null,box,shapes,max,previous);var c=new JsonObject();
    c.add("box",box(box));c.add("shapes",shapeIds(shapes));c.addProperty("max_step",max);c.addProperty("previous",previous);
    var bits=new JsonArray();for(float value:result)bits.add(HexFormat.of().toHexDigits(Float.floatToRawIntBits(value)));
    c.add("height_bits",bits);heightCases.add(c);
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    unsafe=(Unsafe)field(Unsafe.class,"theUnsafe").get(null);levelField=field(Entity.class,"level");boxField=field(Entity.class,"bb");
    collide=Entity.class.getDeclaredMethod("collide",Vec3.class);collide.setAccessible(true);
    candidates=Entity.class.getDeclaredMethod("collectCandidateStepUpHeights",AABB.class,List.class,float.class,float.class);candidates.setAccessible(true);
    var cacheField=field(BlockBehaviour.BlockStateBase.class,"cache");var grids=new LinkedHashMap<String,VoxelShape>();
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      var cache=cacheField.get(state);if(cache==null)continue;
      var shape=(VoxelShape)field(cache.getClass(),"collisionShape").get(cache);
      grids.putIfAbsent(gson.toJson(BlockFactsOracle.geometry(shape)),shape);
    }
    if(grids.size()!=330)throw new AssertionError("Cached coverage differs");
    var floor=Shapes.box(-4,-1,-4,4,0,4);var standing=new AABB(-.3,0,-.3,.3,1.8,.3);
    for(var shape:grids.values()) {
      var list=List.of(floor,shape.move(1,0,0));
      for(var offset:List.of(Vec3.ZERO,new Vec3(-17,1000000,17),new Vec3(29999990,-64,-29999990)))
        for(boolean ground:new boolean[]{false,true})for(float step:new float[]{.6f,1f})
          for(var motion:List.of(new Vec3(2,-.08,0),new Vec3(2,0,2),new Vec3(0,-.08,2),new Vec3(1,-1,2),new Vec3(1,.3,0)))
            probe(standing,list,list,motion,step,ground,offset);
      for(float previous:new float[]{-1f,-0f,0f,.5f})for(float step:new float[]{0f,.6f,1f,2f})
        heights(standing,List.of(shape),step,previous);
    }
    var low=Shapes.box(1,0,-1,1.5,.25,1);var high=Shapes.box(1.5,0,-1,2,.5,1);
    var slab=Shapes.box(1,0,-1,2,.5,1);var ceiling=Shapes.box(-1,2,-1,4,3,1);
    var internal=Shapes.or(Shapes.box(1,0,-1,1.5,.25,1),Shapes.box(1.5,0,-1,2,.5,1));
    List<List<VoxelShape>> layouts=List.of(List.of(),List.of(Shapes.empty()),List.of(floor,slab),List.of(floor,low,high),
      List.of(floor,internal),List.of(floor,slab,ceiling),List.of(floor,high),Collections.nCopies(128,slab));
    for(var initial:layouts)for(var steps:layouts)for(double y:new double[]{-.2,0,.2})
      for(var motion:List.of(new Vec3(2,-1,0),new Vec3(2,0,0),new Vec3(1,-.2,2),new Vec3(-2,-1,-2),
          new Vec3(-0.0,-0.0,-0.0),new Vec3(1e-200,-1e-200,0)))
        for(boolean ground:new boolean[]{false,true})for(float step:new float[]{0,.6f,1f})
          probe(standing.move(0,y,0),initial,steps,motion,step,ground,Vec3.ZERO);
    for(double edge:new double[]{-1e-60,-0.0,0.0,1e-60,Math.nextDown(.6),.6,Math.nextUp(.6),Math.nextDown((double).6f),(double).6f,Math.nextUp((double).6f)}) {
      var shape=Shapes.create(new AABB(1,edge,-1,2,1,1));
      for(float previous:new float[]{-1f,-0.0f,0f,.6f})heights(standing,List.of(shape,Shapes.empty()),.6f,previous);
      probe(standing,List.of(floor,shape),List.of(floor,shape),new Vec3(2,-.08,0),.6f,true,Vec3.ZERO);
    }
    var result=new JsonObject();result.add("shapes",geometries);result.add("cases",cases);result.add("heights",heightCases);
    Files.writeString(Path.of(args[0]),gson.toJson(result));
    System.out.println("PASS: "+cases.size()+" actual native step movement cases / "+heightCases.size()+" candidate sets; all 330 cached grids.");
  }
}
