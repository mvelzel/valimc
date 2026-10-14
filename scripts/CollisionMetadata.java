import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.Direction.Axis;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.phys.shapes.*;
import java.nio.file.*;
import java.util.*;

/** Original extraction of cached collision grids; dynamic contexts are never guessed. */
public class CollisionMetadata {
  private static final Gson gson=new Gson();
  private static final java.lang.reflect.Field gridField;
  static {
    try {gridField=VoxelShape.class.getDeclaredField("shape");gridField.setAccessible(true);}
    catch(Exception e) {throw new RuntimeException(e);}
  }
  public static JsonObject geometry(VoxelShape shape) throws Exception {
    var result=new JsonObject();var coords=new JsonArray();var sizes=new JsonArray();var boxes=new JsonArray();
    var grid=(DiscreteVoxelShape)gridField.get(shape);
    int nx=grid.getXSize(),ny=grid.getYSize(),nz=grid.getZSize();
    if(shape.isEmpty()) {nx=ny=nz=0;for(int i=0;i<3;i++){var axis=new JsonArray();axis.add(0.0);coords.add(axis);}}
    else for(var axis:Axis.values()) {var values=new JsonArray();for(double v:shape.getCoords(axis))values.add(v);coords.add(values);}
    sizes.add(nx);sizes.add(ny);sizes.add(nz);byte[] bits=new byte[(nx*ny*nz+7)/8];
    for(int x=0;x<nx;x++)for(int y=0;y<ny;y++)for(int z=0;z<nz;z++)if(grid.isFull(x,y,z)) {
      int index=(x*ny+y)*nz+z;bits[index/8]|=(byte)(1<<(index%8));
    }
    for(var box:shape.toAabbs()) {
      var values=new JsonArray();for(double v:new double[]{box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ})values.add(v);
      boxes.add(values);
    }
    result.add("axes",coords);result.add("sizes",sizes);result.addProperty("bits",HexFormat.of().formatHex(bits));
    result.add("boxes",boxes);return result;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var cacheField=BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cacheField.setAccessible(true);
    var shapes=new JsonArray();var shapeIds=new LinkedHashMap<String,Integer>();var runs=new JsonArray();
    JsonElement previous=null;int runStart=0,runLength=0,dynamic=0,states=0,maxCells=0,maxBoxes=0;
    for(var state:Block.BLOCK_STATE_REGISTRY) {
      int id=Block.getId(state);if(id!=states++)throw new AssertionError("Non-contiguous block state registry");
      var cache=cacheField.get(state);JsonElement value;
      if(cache==null) {value=new JsonPrimitive(BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString());dynamic++;}
      else {
        var f=cache.getClass().getDeclaredField("collisionShape");f.setAccessible(true);
        var shape=geometry((VoxelShape)f.get(cache));String key=gson.toJson(shape);
        Integer index=shapeIds.get(key);if(index==null){index=shapes.size();shapeIds.put(key,index);shapes.add(shape);}
        value=new JsonPrimitive(index);
        var size=shape.getAsJsonArray("sizes");maxCells=Math.max(maxCells,size.get(0).getAsInt()*size.get(1).getAsInt()*size.get(2).getAsInt());
        maxBoxes=Math.max(maxBoxes,shape.getAsJsonArray("boxes").size());
      }
      if(value.equals(previous))runLength++;
      else {if(previous!=null){var run=new JsonArray();run.add(runStart);run.add(runLength);run.add(previous);runs.add(run);}
        runStart=id;runLength=1;previous=value;}
    }
    if(previous!=null){var run=new JsonArray();run.add(runStart);run.add(runLength);run.add(previous);runs.add(run);}
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);
    result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    result.addProperty("state_count",states);result.add("runs",runs);result.add("shapes",shapes);
    Files.createDirectories(Path.of(args[0]).getParent());Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");
    System.out.println("Cached collision facts: "+states+" states, "+dynamic+" contextual states, "+shapes.size()+" grids, "+runs.size()+" runs; max "+maxCells+" cells / "+maxBoxes+" boxes.");
  }
}
