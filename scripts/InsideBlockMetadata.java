import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.BlockPos;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.phys.shapes.Shapes;

/** Pinned scalar classification and static inside-block shapes, not collision shapes. */
public class InsideBlockMetadata {
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();write(Path.of(args[0]));
  }
  static void write(Path path)throws Exception{
    var air=new JsonArray();var fire=new JsonArray();var soul=new JsonArray();var custom=new JsonArray();var owners=new TreeMap<String,Integer>();
    for(var block:net.minecraft.core.registries.BuiltInRegistries.BLOCK){
      Class<?> owner=block.getClass();
      while(true){try{owner.getDeclaredMethod("getEntityInsideCollisionShape",BlockState.class,BlockGetter.class,BlockPos.class,Entity.class);break;}catch(NoSuchMethodException e){owner=owner.getSuperclass();}}
      owners.merge(owner.getName(),1,Integer::sum);
    }
    for(var state:Block.BLOCK_STATE_REGISTRY){
      int id=Block.getId(state);
      if(state.isAir())air.add(id);
      if(state.is(Blocks.FIRE))fire.add(id);
      else if(state.is(Blocks.SOUL_FIRE))soul.add(id);
      else if(state.getBlock() instanceof BaseFireBlock)throw new AssertionError("Unknown fire block");
      if(state.is(Blocks.POWDER_SNOW))continue; // Requires the existing entity collision context.
      var shape=state.getEntityInsideCollisionShape(EmptyBlockGetter.INSTANCE,BlockPos.ZERO,null);
      if(shape!=Shapes.block()){
        var boxes=new JsonArray();
        for(var b:shape.toAabbs()){var box=new JsonArray();for(double n:new double[]{b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ})box.add(n);boxes.add(box);}
        var entry=new JsonArray();entry.add(id);entry.add(boxes);custom.add(entry);
        if(!shape.toAabbs().equals(state.getEntityInsideCollisionShape(EmptyBlockGetter.INSTANCE,new BlockPos(31,-7,19),null).toAabbs()))throw new AssertionError("Position-dependent inside shape");
      }
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.addProperty("state_count",Block.BLOCK_STATE_REGISTRY.size());
    facts.add("air",air);facts.add("fire",fire);facts.add("soul_fire",soul);facts.addProperty("powder_snow",Block.getId(Blocks.POWDER_SNOW.defaultBlockState()));facts.add("custom_shapes",custom);facts.add("shape_owners",new Gson().toJsonTree(owners));
    Files.writeString(path,new Gson().toJson(facts));System.out.println("PASS: "+Block.BLOCK_STATE_REGISTRY.size()+" inside-state facts; "+custom.size()+" static exceptions plus contextual powder snow; shape owners "+owners);
  }
}
