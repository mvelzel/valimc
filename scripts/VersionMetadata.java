import com.google.gson.*;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.HexFormat;
import net.minecraft.SharedConstants;

/** Emits the pinned release identity: name, data version, protocol and official server jar SHA-1. */
public class VersionMetadata {
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();var version=SharedConstants.getCurrentVersion();
    var facts=new JsonObject();facts.addProperty("minecraft",version.id());
    facts.addProperty("data_version",version.dataVersion().version());
    facts.addProperty("protocol",version.protocolVersion());facts.addProperty("server_sha1",serverSha1());
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");
    System.out.println("PASS: "+facts);
  }

  /** SHA-1 of the official server jar the oracles run on. */
  static String serverSha1()throws Exception{
    var jar=Path.of("research/server-"+SharedConstants.getCurrentVersion().id()+".jar");
    return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-1").digest(Files.readAllBytes(jar)));
  }
}
