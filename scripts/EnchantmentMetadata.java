import com.google.gson.*;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;

/**
 * The enchantment definitions of the pinned data pack (VMC-077d): per enchantment of the
 * registry, the equipment slot groups it acts in, its maximum level and its effect components
 * exactly as the data pack defines them (the damage protection and immunity effects with their
 * damage-source tag requirements, and every other component for later readers).
 * Usage: EnchantmentMetadata ENCHANTMENTS.json
 */
public class EnchantmentMetadata {
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var registry=VanillaRegistries.createWorldLookup().lookupOrThrow(Registries.ENCHANTMENT);
    var definitions=new TreeMap<String,JsonObject>();
    for(var key:registry.listElementIds().toList()){
      var id=key.identifier();var path="/data/"+id.getNamespace()+"/enchantment/"+id.getPath()+".json";
      try(var in=EnchantmentMetadata.class.getResourceAsStream(path)){
        if(in==null)throw new AssertionError("Missing data pack definition "+path);
        var json=JsonParser.parseReader(new InputStreamReader(in,StandardCharsets.UTF_8)).getAsJsonObject();
        var definition=new JsonObject();definition.add("slots",json.get("slots"));definition.add("max_level",json.get("max_level"));
        definition.add("effects",json.has("effects")?json.get("effects"):new JsonObject());
        definitions.put(id.toString(),definition);
      }
    }
    var enchantments=new JsonObject();definitions.forEach(enchantments::add);
    var out=new JsonObject();var version=SharedConstants.getCurrentVersion();
    out.addProperty("version",version.id());out.addProperty("data_version",version.dataVersion().version());
    out.addProperty("server_sha1",VersionMetadata.serverSha1());out.add("enchantments",enchantments);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out)+"\n");
    System.out.println("PASS: "+definitions.size()+" enchantment definitions");
  }
}
