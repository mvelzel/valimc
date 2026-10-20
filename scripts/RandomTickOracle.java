import com.google.gson.*;
import java.nio.file.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.*;

/** Original observation of which native block states tick randomly, as contiguous id runs per block. */
public class RandomTickOracle {
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var runs=new JsonArray();int count=Block.BLOCK_STATE_REGISTRY.size(),states=0;JsonArray run=null;
    for(int id=0;id<count;id++){
      var state=Block.stateById(id);if(Block.getId(state)!=id)throw new AssertionError("Sparse state id "+id);
      if(!state.isRandomlyTicking()){run=null;continue;}
      var name=BuiltInRegistries.BLOCK.getKey(state.getBlock()).getPath();states++;
      if(run!=null&&run.get(0).getAsString().equals(name)){run.set(2,new JsonPrimitive(id));continue;}
      run=new JsonArray();run.add(name);run.add(id);run.add(id);runs.add(run);
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    facts.addProperty("state_count",count);facts.addProperty("random_ticking_states",states);facts.add("runs",runs);
    Files.writeString(Path.of(args[0]),new GsonBuilder().create().toJson(facts)+"\n");
    System.out.println("PASS: "+states+" randomly ticking states in "+runs.size()+" runs of "+count);
  }
}
