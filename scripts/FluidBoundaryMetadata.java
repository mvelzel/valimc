import com.google.gson.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.lang.reflect.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.level.EmptyBlockGetter;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.piston.MovingPistonBlock;
import net.minecraft.world.level.block.state.*;

/** Original scalar flow/support observations; contextual block entities remain explicit. */
public class FluidBoundaryMetadata {
  private static Set<Block> tag(String name,Set<String> visiting)throws Exception{
    if(!visiting.add(name))throw new AssertionError("Cyclic block tag "+name);
    var id=Identifier.parse(name);var result=new HashSet<Block>();
    String path="/data/"+id.getNamespace()+"/tags/block/"+id.getPath()+".json";
    try(var in=FluidBoundaryMetadata.class.getResourceAsStream(path)){
      if(in==null)throw new AssertionError("Missing pinned tag "+name);
      for(var item:JsonParser.parseReader(new InputStreamReader(in,java.nio.charset.StandardCharsets.UTF_8)).getAsJsonObject().getAsJsonArray("values")){
        String value=item.isJsonPrimitive()?item.getAsString():item.getAsJsonObject().get("id").getAsString();
        if(value.startsWith("#"))result.addAll(tag(value.substring(1),visiting));
        else result.add(BuiltInRegistries.BLOCK.getOptional(Identifier.parse(value)).orElseThrow());
      }
    }
    visiting.remove(name);return result;
  }
  public static void bindFlowTag()throws Exception{
    var members=tag("minecraft:blocks_fluid_flow",new HashSet<>());
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var block:BuiltInRegistries.BLOCK)bind.invoke(block.builtInRegistryHolder(),members.contains(block)?List.of(BlockTags.BLOCKS_FLUID_FLOW):List.of());
  }
  public static int faces(BlockState state,net.minecraft.world.level.BlockGetter world,BlockPos p){
    int mask=0;for(var dir:Direction.values())if(state.isFaceSturdy(world,p,dir))mask|=1<<dir.ordinal();return mask;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();bindFlowTag();
    var cache=BlockBehaviour.BlockStateBase.class.getDeclaredField("cache");cache.setAccessible(true);
    var properties=new JsonArray();var ids=new LinkedHashMap<String,Integer>();var packed=new ByteArrayOutputStream();var cases=new JsonArray();
    int count=0,contextual=0;var gson=new Gson();
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=count++)throw new AssertionError("Non-contiguous states");
      var block=state.getBlock();String context="none";int faceMask=0,facing=-1;
      if(block instanceof MovingPistonBlock){context="piston";contextual++;}
      else if(block instanceof ShulkerBoxBlock){context="shulker";facing=state.getValue(ShulkerBoxBlock.FACING).ordinal();contextual++;}
      else{
        faceMask=faces(state,EmptyBlockGetter.INSTANCE,BlockPos.ZERO);
        if(cache.get(state)==null){
          if(!(block instanceof BambooStalkBlock||block instanceof PointedDripstoneBlock||block instanceof SulfurSpikeBlock||block instanceof ScaffoldingBlock||block instanceof PowderSnowBlock))
            throw new AssertionError("Unclassified dynamic support "+block);
          for(var p:List.of(new BlockPos(-17,-384,19),new BlockPos(1000000,1000000,-1000000)))
            if(faces(state,EmptyBlockGetter.INSTANCE,p)!=faceMask)throw new AssertionError("Position-dependent support "+state);
        }
      }
      var f=new JsonObject();f.addProperty("blocks_flow",state.is(BlockTags.BLOCKS_FLUID_FLOW));f.addProperty("ice",block instanceof IceBlock);
      f.addProperty("faces",faceMask);f.addProperty("context",context);f.addProperty("facing",facing);
      String key=gson.toJson(f);Integer index=ids.get(key);if(index==null){index=properties.size();ids.put(key,index);properties.add(f);}
      if(index>=256)throw new AssertionError("Too many boundary property sets");packed.write(index);
      var c=new JsonObject();c.addProperty("id",Block.getId(state));c.add("properties",f);cases.add(c);
    }
    if(contextual!=114)throw new AssertionError("Incomplete contextual support classification");
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);
    result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");result.addProperty("state_count",count);
    result.add("properties",properties);result.addProperty("states",HexFormat.of().formatHex(packed.toByteArray()));
    Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+count+" native fluid boundaries / "+properties.size()+" scalar sets / "+contextual+" contextual states.");
  }
}
