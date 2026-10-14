import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import com.mojang.authlib.GameProfile;
import com.mojang.authlib.minecraft.client.ObjectMapper;
import com.mojang.authlib.properties.PropertyMap;
import com.mojang.authlib.services.response.HasJoinedMinecraftServerResponse;

/** Original synthetic test harness; no account credentials or copied native code. */
public final class AuthProfileOracle {
  public static void main(String[] args) throws Exception {
    var mapper=ObjectMapper.create();
    var gson=new Gson();
    var lines=new ArrayList<String>();
    for(int i=0;i<32;i++) {
      var input=new JsonObject();
      String id="123456781234567812345678abcdef12";
      if((i&1)!=0)id="12345678-1234-5678-1234-5678ABCDEF12";
      input.addProperty("id",id);
      input.addProperty("name","IgnoredName");
      if(i%4==0)input.add("properties",JsonNull.INSTANCE);
      else if(i%4!=1) {
        var properties=new JsonArray();
        int count=i%4==2?1:16;
        for(int j=0;j<count;j++) {
          var property=new JsonObject();
          property.addProperty("name",j%2==0?"textures":"other");
          property.addProperty("value","synthetic+/= λ\u0000😀 "+i+"/"+j);
          if(j%2==0)property.addProperty("signature","synthetic-signature+/= "+i+"/"+j);
          properties.add(property);
        }
        input.add("properties",properties);
      }
      var result=mapper.readValue(input.toString(),HasJoinedMinecraftServerResponse.class);
      var profile=new GameProfile(result.id(),"OracleOne",result.properties()==null?PropertyMap.EMPTY:result.properties());
      var expected=new JsonObject();
      expected.addProperty("uuid",profile.id().toString().replace("-",""));
      expected.addProperty("name",profile.name());
      expected.add("properties",gson.toJsonTree(profile.properties().values()));
      var fixture=new JsonObject();
      fixture.addProperty("body",input.toString());
      fixture.add("expected",expected);
      lines.add(fixture.toString());
    }
    Files.write(Path.of(args[0]),lines);
    System.out.println("PASS: generated 32 native authlib 10.0.77 hasJoined UUID/property cases.");
  }
}
