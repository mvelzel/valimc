import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.server.Bootstrap;
import net.minecraft.tags.BlockTags;
import net.minecraft.world.level.block.Block;

/**
 * Observes actual fallOn damage calls (the block fact table's probe, `BlockFactsOracle.Landing`):
 * per state, both shift inputs at distance 8 and the legacy support height; per distinct rule,
 * threshold and remote distances. Block mutations, sound and health are excluded.
 */
public class LandingOracle {
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var tags=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject().getAsJsonObject("minecraft:block");
    var bindTags=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bindTags.setAccessible(true);
    for(var tag:List.of(BlockTags.FENCES,BlockTags.WALLS))for(var id:tags.getAsJsonArray(tag.location().toString())){
      var block=net.minecraft.core.registries.BuiltInRegistries.BLOCK.byId(id.getAsInt());
      bindTags.invoke(block.builtInRegistryHolder(),List.of(tag));
    }
    var entity=BlockFactsOracle.Landing.create();var gson=new Gson();var cases=new JsonArray();var representatives=new HashSet<String>();
    for(var state:Block.BLOCK_STATE_REGISTRY){
      boolean holds=entity.holdsY(state);
      for(boolean shift:new boolean[]{false,true}){
        var c=new JsonObject();c.addProperty("id",Block.getId(state));c.addProperty("shift",shift);c.addProperty("distance",8);
        c.addProperty("holds_y",holds);c.add("call",entity.observe(state,8,shift));cases.add(c);
      }
      // Independent thresholds and remote distances for each distinct rule pair.
      if(!representatives.add(gson.toJson(entity.rule(state,false))+gson.toJson(entity.rule(state,true))))continue;
      for(boolean shift:new boolean[]{false,true})for(double distance:new double[]{0,2.999999,3.999998,4,6,19.25,60000000}){
        var c=new JsonObject();c.addProperty("id",Block.getId(state));c.addProperty("shift",shift);c.addProperty("distance",distance);
        c.addProperty("holds_y",holds);c.add("call",entity.observe(state,distance,shift));cases.add(c);
      }
    }
    Files.writeString(Path.of(args[0]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+cases.size()+" native fallOn calls across "+Block.BLOCK_STATE_REGISTRY.size()+" states and "+representatives.size()+" rules. Nonliving observer excludes terrain mutations and powder-snow sounds.");
  }
}
