import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.properties.Property;

/**
 * Emits the block registry: every block in registry order with its first and default
 * state, behaviour class and property definitions. Asserts that each block's states
 * are one contiguous run whose order is the mixed radix of its property values, the
 * last property varying fastest, so readers can decode a state id without a table.
 */
public class BlockRegistryMetadata {
  private static final String PACKAGE = "net.minecraft.world.level.block.";

  @SuppressWarnings({"rawtypes", "unchecked"})
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var version=SharedConstants.getCurrentVersion();
    var classes=new TreeSet<String>();var definitions=new LinkedHashMap<String,JsonArray>();
    for(var block:BuiltInRegistries.BLOCK){
      classes.add(className(block));
      for(Property property:block.getStateDefinition().getProperties())definitions.putIfAbsent(definitionKey(property),definition(property));
    }
    var classIndex=new HashMap<String,Integer>();for(var name:classes)classIndex.put(name,classIndex.size());
    var propertyIndex=new HashMap<String,Integer>();for(var key:definitions.keySet())propertyIndex.put(key,propertyIndex.size());
    var blocks=new JsonArray();int next=0,index=0;
    for(var block:BuiltInRegistries.BLOCK){
      if(BuiltInRegistries.BLOCK.getId(block)!=index++)throw new AssertionError("Sparse block registry "+block);
      var properties=new ArrayList<Property>(block.getStateDefinition().getProperties());
      var states=block.getStateDefinition().getPossibleStates();int first=Block.getId(states.get(0));
      if(first!=next)throw new AssertionError("Non-contiguous block states "+block);
      for(int offset=0;offset<states.size();offset++){
        var state=states.get(offset);int radix=0;
        for(Property property:properties)radix=radix*property.getPossibleValues().size()+property.getPossibleValues().indexOf(state.getValue(property));
        if(Block.getId(state)!=first+offset||radix!=offset)throw new AssertionError("State order is not the property radix "+state);
      }
      next+=states.size();
      var row=new JsonArray();row.add(BuiltInRegistries.BLOCK.getKey(block).getPath());row.add(first);
      row.add(Block.getId(block.defaultBlockState()));row.add(classIndex.get(className(block)));
      var ids=new JsonArray();for(Property property:properties)ids.add(propertyIndex.get(definitionKey(property)));row.add(ids);
      blocks.add(row);
    }
    if(next!=Block.BLOCK_STATE_REGISTRY.size())throw new AssertionError("Block states outside the registry");
    var facts=new JsonObject();facts.addProperty("version",version.id());
    facts.addProperty("data_version",version.dataVersion().version());
    facts.addProperty("server_sha1",VersionMetadata.serverSha1());
    facts.addProperty("state_count",next);facts.addProperty("block_count",blocks.size());
    var classList=new JsonArray();classes.forEach(classList::add);facts.add("classes",classList);
    var propertyList=new JsonArray();definitions.values().forEach(propertyList::add);facts.add("properties",propertyList);
    facts.add("blocks",blocks);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");
    System.out.println("PASS: "+blocks.size()+" blocks, "+next+" states, "+classes.size()+" classes, "+definitions.size()+" property definitions");
  }

  private static String className(Block block){
    var name=block.getClass().getName();
    if(!name.startsWith(PACKAGE)||name.indexOf('$')>=0)throw new AssertionError("Unnamed block class "+name);
    return name.substring(PACKAGE.length());
  }

  @SuppressWarnings({"rawtypes", "unchecked"})
  private static JsonArray definition(Property property){
    var values=new JsonArray();for(Object value:property.getPossibleValues())values.add(property.getName((Comparable)value));
    var row=new JsonArray();row.add(property.getName());row.add(values);return row;
  }

  private static String definitionKey(Property<?> property){return new Gson().toJson(definition(property));}
}
