import com.google.gson.*;
import java.io.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.Bootstrap;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;

/** Original scalar observations of pinned climb tags and ladder/trapdoor properties. */
public class ClimbMetadata {
  private static Set<Block> tag(String name,Set<String> visiting)throws Exception{
    if(!visiting.add(name))throw new AssertionError("Cyclic pinned block tag "+name);
    var id=Identifier.parse(name);var result=new HashSet<Block>();
    try(var in=ClimbMetadata.class.getResourceAsStream("/data/"+id.getNamespace()+"/tags/block/"+id.getPath()+".json")){
      if(in==null)throw new AssertionError("Missing pinned block tag "+name);
      for(var item:JsonParser.parseReader(new InputStreamReader(in,java.nio.charset.StandardCharsets.UTF_8)).getAsJsonObject().getAsJsonArray("values")){
        String value=item.isJsonPrimitive()?item.getAsString():item.getAsJsonObject().get("id").getAsString();
        if(value.startsWith("#"))result.addAll(tag(value.substring(1),visiting));
        else result.add(BuiltInRegistries.BLOCK.getOptional(Identifier.parse(value)).orElseThrow());
      }
    }
    visiting.remove(name);return result;
  }
  public static void bindTags()throws Exception{
    var climb=tag("minecraft:climbable",new HashSet<>());var glide=tag("minecraft:can_glide_through",new HashSet<>());
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    for(var block:BuiltInRegistries.BLOCK){var tags=new ArrayList<Object>();if(climb.contains(block))tags.add(BlockTags.CLIMBABLE);if(glide.contains(block))tags.add(BlockTags.CAN_GLIDE_THROUGH);bind.invoke(block.builtInRegistryHolder(),tags);}
  }
  public static JsonObject facts(BlockState state){
    var block=state.getBlock();var f=new JsonObject();f.addProperty("climbable",state.is(BlockTags.CLIMBABLE));f.addProperty("glide_through",state.is(BlockTags.CAN_GLIDE_THROUGH));
    f.addProperty("scaffolding",block==Blocks.SCAFFOLDING);f.addProperty("ladder_facing",block==Blocks.LADDER?state.getValue(LadderBlock.FACING).ordinal():-1);
    f.addProperty("trapdoor_facing",block instanceof TrapDoorBlock?state.getValue(TrapDoorBlock.FACING).ordinal():-1);
    f.addProperty("trapdoor_open",block instanceof TrapDoorBlock&&state.getValue(TrapDoorBlock.OPEN));return f;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();bindTags();var gson=new Gson();var properties=new JsonArray();var ids=new LinkedHashMap<String,Integer>();var packed=new ByteArrayOutputStream();var cases=new JsonArray();int count=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=count++)throw new AssertionError("Noncontiguous block states");var f=facts(state);String key=gson.toJson(f);var id=ids.get(key);
      if(id==null){id=properties.size();ids.put(key,id);properties.add(f);}if(id>255)throw new AssertionError("Too many climb property sets");packed.write(id);
      var c=new JsonObject();c.addProperty("id",Block.getId(state));c.add("properties",f);cases.add(c);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("state_count",count);out.add("properties",properties);out.addProperty("states",HexFormat.of().formatHex(packed.toByteArray()));
    Files.writeString(Path.of(args[0]),gson.toJson(out)+"\n");Files.writeString(Path.of(args[1]),gson.toJson(cases));System.out.println("PASS: "+count+" native climb states / "+properties.size()+" property sets.");
  }
}
