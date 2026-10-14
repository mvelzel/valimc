import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.entity.ai.attributes.RangedAttribute;
import java.nio.file.*;

/** Original extraction of builtin protocol facts, without a gameplay server. */
public class AttributeMetadata {
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var result=new JsonObject();
    for(var attribute:BuiltInRegistries.ATTRIBUTE) {
      var value=new JsonObject();
      value.addProperty("id",BuiltInRegistries.ATTRIBUTE.getId(attribute));
      value.addProperty("default",attribute.getDefaultValue());
      value.addProperty("syncable",attribute.isClientSyncable());
      if(attribute instanceof RangedAttribute ranged) {
        value.addProperty("min",ranged.getMinValue());value.addProperty("max",ranged.getMaxValue());
      }
      result.add(BuiltInRegistries.ATTRIBUTE.getKey(attribute).toString(),value);
    }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(result)+"\n");
  }
}
