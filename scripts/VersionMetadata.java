import com.google.gson.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.HexFormat;
import net.minecraft.SharedConstants;

/** Emits the pinned release identity: name, data version, protocol and official server jar SHA-1. */
public class VersionMetadata {
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();var version=SharedConstants.getCurrentVersion();
    var jar=Path.of("research/server-"+version.id()+".jar");
    var sha1=HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(Files.readAllBytes(jar)));
    var facts=new JsonObject();facts.addProperty("minecraft",version.id());
    facts.addProperty("data_version",version.dataVersion().version());
    facts.addProperty("protocol",version.protocolVersion());facts.addProperty("server_sha1",sha1);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");
    System.out.println("PASS: "+facts);
  }
}
