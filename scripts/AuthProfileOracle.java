import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import com.mojang.authlib.GameProfile;
import com.mojang.authlib.minecraft.client.ObjectMapper;
import com.mojang.authlib.properties.PropertyMap;
import com.mojang.authlib.services.response.HasJoinedMinecraftServerResponse;
import io.netty.buffer.Unpooled;
import net.minecraft.core.RegistryAccess;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.login.ClientboundLoginFinishedPacket;
import net.minecraft.network.protocol.game.ClientboundPlayerInfoUpdatePacket;

/** Original synthetic test harness; no account credentials or copied native code. */
public final class AuthProfileOracle {
  public static void main(String[] args) throws Exception {
    if(args[0].equals("verify")) { verify(args[1]); return; }
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

  private static void check(GameProfile profile, JsonObject expected) {
    if(!profile.id().toString().replace("-","").equals(expected.get("uuid").getAsString()) ||
       !profile.name().equals(expected.get("name").getAsString()))throw new AssertionError("Profile identity mismatch");
    var actual=new ArrayList<String>();
    for(var property:profile.properties().values())actual.add(property.name()+"\u0001"+property.value()+"\u0001"+property.signature());
    var wanted=new ArrayList<String>();
    for(var element:expected.getAsJsonArray("properties")) {
      var property=element.getAsJsonObject();
      wanted.add(property.get("name").getAsString()+"\u0001"+property.get("value").getAsString()+"\u0001"+
        (property.has("signature")?property.get("signature").getAsString():"null"));
    }
    Collections.sort(actual);Collections.sort(wanted);
    if(!actual.equals(wanted))throw new AssertionError("Profile property mismatch");
  }

  private static void verify(String path) throws Exception {
    int count=0;
    for(String line:Files.readAllLines(Path.of(path))) {
      var fixture=JsonParser.parseString(line).getAsJsonObject();
      var expected=fixture.getAsJsonObject("expected");
      var login=Unpooled.wrappedBuffer(HexFormat.of().parseHex(fixture.get("login").getAsString()));
      var packet=ClientboundLoginFinishedPacket.STREAM_CODEC.decode(login);
      check(packet.gameProfile(),expected);
      if(login.isReadable() || !packet.sessionId().equals(new UUID(0,0)))throw new AssertionError("Login boundary mismatch");
      var info=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(fixture.get("info").getAsString())),RegistryAccess.EMPTY);
      var update=ClientboundPlayerInfoUpdatePacket.STREAM_CODEC.decode(info);
      if(update.entries().size()!=1 || info.isReadable())throw new AssertionError("Info boundary mismatch");
      check(update.entries().getFirst().profile(),expected);
      login.release();info.release();count++;
    }
    System.out.println("PASS: "+count+" native authenticated login/player-info profile property codecs.");
  }
}
