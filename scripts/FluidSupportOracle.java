import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.piston.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.phys.shapes.*;

/** Actual FULL support and contextual block-entity faces; no geometry algorithm is copied. */
public class FluidSupportOracle {
  private static JsonArray faces(VoxelShape shape){var a=new JsonArray();for(var d:Direction.values())a.add(Block.isFaceFull(shape,d));return a;}
  private static JsonArray sturdy(BlockState s,BlockGetter world,BlockPos p){var a=new JsonArray();for(var d:Direction.values())a.add(s.isFaceSturdy(world,p,d));return a;}
  private static Field field(Class<?> c,String name)throws Exception{var f=c.getDeclaredField(name);f.setAccessible(true);return f;}
  private static BlockGetter world(BlockEntity entity,BlockPos position){
    return (BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},(proxy,m,args)->{
      if(m.getName().equals("getBlockEntity")&&args[0].equals(position))return entity;
      throw new AssertionError("Unexpected support query "+m);
    });
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var gson=new Gson();var grids=new JsonArray();var unique=new HashSet<String>();var contexts=new JsonArray();
    for(var s:Block.BLOCK_STATE_REGISTRY){
      if(s.getBlock() instanceof MovingPistonBlock||s.getBlock() instanceof ShulkerBoxBlock)continue;
      var shape=s.getBlockSupportShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO);var geometry=CollisionMetadata.geometry(shape);
      if(unique.add(gson.toJson(geometry))){var c=new JsonObject();c.add("geometry",geometry);c.add("faces",faces(shape));grids.add(c);}
    }
    for(double lo:new double[]{-1e-7,0,1e-7,.25})for(double hi:new double[]{.9999998,.9999999,1,1.5})for(var axis:Direction.Axis.values()){
      var shape=Shapes.create(axis==Direction.Axis.X?lo:0,axis==Direction.Axis.Y?lo:0,axis==Direction.Axis.Z?lo:0,
        axis==Direction.Axis.X?hi:1,axis==Direction.Axis.Y?hi:1,axis==Direction.Axis.Z?hi:1);
      var c=new JsonObject();c.add("geometry",CollisionMetadata.geometry(shape));c.add("faces",faces(shape));grids.add(c);
    }
    var position=new BlockPos(0,64,0);var old=field(ShulkerBoxBlockEntity.class,"progressOld");var progress=field(ShulkerBoxBlockEntity.class,"progress");var status=field(ShulkerBoxBlockEntity.class,"animationStatus");
    for(var state:Block.BLOCK_STATE_REGISTRY)if(state.getBlock() instanceof ShulkerBoxBlock)
      for(var animation:ShulkerBoxBlockEntity.AnimationStatus.values())for(float p:new float[]{0,.5f,1}){
        var entity=new ShulkerBoxBlockEntity(position,state);old.setFloat(entity,p);progress.setFloat(entity,p);status.set(entity,animation);
        var w=world(entity,position);var c=new JsonObject();c.addProperty("state",Block.getId(state));c.addProperty("kind","shulker");
        c.addProperty("progress",(double)p);c.addProperty("closed",entity.isClosed());c.add("faces",sturdy(state,w,position));contexts.add(c);
      }
    var current=field(PistonMovingBlockEntity.class,"progress");var previous=field(PistonMovingBlockEntity.class,"progressO");
    for(var moving:Block.BLOCK_STATE_REGISTRY)if(moving.getBlock() instanceof MovingPistonBlock)
      for(var moved:List.of(Blocks.STONE.defaultBlockState(),Blocks.STONE_SLAB.defaultBlockState(),Blocks.PISTON.defaultBlockState()))
        for(var direction:Direction.values())for(boolean extending:new boolean[]{false,true})for(boolean source:new boolean[]{false,true})for(float p:new float[]{0,.25f,.75f,1}){
          var entity=new PistonMovingBlockEntity(position,moving,moved,direction,extending,source);current.setFloat(entity,p);previous.setFloat(entity,p);
          var w=world(entity,position);var c=new JsonObject();c.addProperty("state",Block.getId(moving));c.addProperty("kind","piston");
          c.addProperty("moved",Block.getId(moved));c.addProperty("direction",direction.getName());c.addProperty("extending",extending);c.addProperty("source",source);c.addProperty("progress",(double)p);
          var shape=moving.getBlockSupportShape(w,position);c.add("faces",sturdy(moving,w,position));contexts.add(c);
          var geometry=CollisionMetadata.geometry(shape);if(unique.add(gson.toJson(geometry))){var g=new JsonObject();g.add("geometry",geometry);g.add("faces",faces(shape));grids.add(g);}
        }
    var result=new JsonObject();result.add("grids",grids);result.add("contexts",contexts);Files.writeString(Path.of(args[0]),gson.toJson(result));
    System.out.println("PASS: "+grids.size()+" actual native support grids and "+contexts.size()+" shulker/piston face contexts.");
  }
}
