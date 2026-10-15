import com.google.gson.*;
import java.nio.file.*;
import java.io.ByteArrayOutputStream;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.Blocks;

/** Extracts scalar block motion facts; no implementation or world state is exported. */
public class BlockMotionMetadata {
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var gson=new Gson();
    var tags=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject();
    var suppresses=new HashSet<Integer>();
    for(var id:tags.getAsJsonObject("minecraft:block").getAsJsonArray("minecraft:suppresses_bounce"))suppresses.add(id.getAsInt());
    var properties=new JsonArray();var indexes=new LinkedHashMap<String,Integer>();var packed=new ByteArrayOutputStream();var cases=new JsonArray();
    int states=0,pending=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=states++)throw new AssertionError("Non-contiguous state registry");
      var block=state.getBlock();var facts=new JsonObject();
      facts.addProperty("friction",(double)block.getFriction());facts.addProperty("speed_factor",(double)block.getSpeedFactor());
      facts.addProperty("jump_factor",(double)block.getJumpFactor());facts.addProperty("bounciness",(double)block.getBounceRestitution());
      facts.addProperty("suppresses_bounce",suppresses.contains(BuiltInRegistries.BLOCK.getId(block)));
      facts.addProperty("fluid_empty",state.getFluidState().isEmpty());
      var c=new JsonObject();c.addProperty("id",Block.getId(state));c.add("properties",facts);cases.add(c);
      String key=gson.toJson(facts);Integer index=indexes.get(key);
      if(index==null){index=properties.size();indexes.put(key,index);properties.add(facts);}
      if(index>=16)throw new AssertionError("More than sixteen motion property sets");
      if((Block.getId(state)&1)==0)pending=index<<4;else packed.write(pending|index);
    }
    if((states&1)!=0)packed.write(pending);
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);
    result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    result.addProperty("state_count",states);result.add("properties",properties);result.addProperty("states",HexFormat.of().formatHex(packed.toByteArray()));
    Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");
    Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+states+" native block motion states / "+properties.size()+" property sets / "+packed.size()+" packed bytes; suppression from pinned block tags.");
    for(var block:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK,Blocks.HONEY_BLOCK,Blocks.WATER))
      System.out.println(BuiltInRegistries.BLOCK.getKey(block)+" state="+Block.getId(block.defaultBlockState()));
  }
}
