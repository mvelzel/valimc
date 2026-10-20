import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockBehaviour;

/**
 * Original observation of which native block states carry a block entity, as
 * contiguous id runs per block with the block entity type each creates; the type
 * registry in network id order; and the blocks whose class overrides
 * `useItemOn`/`useWithoutItem` (an interaction vanilla may consume).
 */
public class BlockEntityOracle {
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var runs=new JsonArray();int count=Block.BLOCK_STATE_REGISTRY.size(),states=0;JsonArray run=null;
    var interactive=new TreeSet<String>();
    for(int id=0;id<count;id++){
      var state=Block.stateById(id);if(Block.getId(state)!=id)throw new AssertionError("Sparse state id "+id);
      if(!state.hasBlockEntity()){run=null;continue;}
      var block=state.getBlock();
      var name=BuiltInRegistries.BLOCK.getKey(block).getPath();states++;
      String typeName=null;
      for(var type:BuiltInRegistries.BLOCK_ENTITY_TYPE)
        if(type.isValid(state)){if(typeName!=null)throw new AssertionError("two types for "+name);typeName=BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(type).toString();}
      if(typeName==null){var made=((EntityBlock)block).newBlockEntity(BlockPos.ZERO,state);
        if(made==null)throw new AssertionError("no type for "+name);typeName=BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(made.getType()).toString();}
      if(overridesUse(block.getClass()))interactive.add(name);
      if(run!=null&&run.get(0).getAsString().equals(name)&&run.get(3).getAsString().equals(typeName)){run.set(2,new JsonPrimitive(id));continue;}
      run=new JsonArray();run.add(name);run.add(id);run.add(id);run.add(typeName);runs.add(run);
    }
    var types=new JsonArray();
    for(int id=0;id<BuiltInRegistries.BLOCK_ENTITY_TYPE.size();id++)
      types.add(BuiltInRegistries.BLOCK_ENTITY_TYPE.getKey(BuiltInRegistries.BLOCK_ENTITY_TYPE.byId(id)).toString());
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    facts.addProperty("state_count",count);facts.addProperty("block_entity_states",states);facts.add("runs",runs);
    facts.add("types",types);
    var used=new JsonArray();interactive.forEach(used::add);facts.add("interactive",used);
    Files.writeString(Path.of(args[0]),new GsonBuilder().create().toJson(facts)+"\n");
    System.out.println("PASS: "+states+" block-entity states in "+runs.size()+" runs of "+count+"; "+types.size()+" types; "+interactive.size()+" interactive blocks");
  }

  /** A class below BlockBehaviour declares useItemOn or useWithoutItem. */
  static boolean overridesUse(Class<?> c){
    for(;c!=null&&c!=BlockBehaviour.class;c=c.getSuperclass())
      for(var m:c.getDeclaredMethods())
        if(m.getName().equals("useItemOn")||m.getName().equals("useWithoutItem"))return true;
    return false;
  }
}
