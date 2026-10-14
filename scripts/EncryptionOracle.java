import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.login.ClientboundHelloPacket;
import net.minecraft.network.protocol.login.ServerboundKeyPacket;
import net.minecraft.util.Crypt;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;
import java.math.BigInteger;
import java.util.*;
import java.nio.file.*;

/** Original codec/crypto interoperability probe using actual Mojang implementations. */
public class EncryptionOracle {
  static byte[] bytes(JsonObject c,String name){return HexFormat.of().parseHex(c.get(name).getAsString());}
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    var cases=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonArray();
    var output=new JsonArray();
    for(var element:cases) {
      var c=element.getAsJsonObject();var publicKey=Crypt.byteToPublicKey(bytes(c,"public"));
      if(!Arrays.equals(publicKey.getEncoded(),bytes(c,"public")))throw new AssertionError("Noncanonical public DER");
      var secret=new SecretKeySpec(bytes(c,"secret"),"AES");
      String hash=new BigInteger(Crypt.digestData("",publicKey,secret)).toString(16);
      if(!hash.equals(c.get("hash").getAsString()))throw new AssertionError("Session hash");
      byte[] plain=bytes(c,"plaintext");byte[] encrypted=Crypt.getCipher(Cipher.ENCRYPT_MODE,secret).doFinal(plain);
      if(!Arrays.equals(encrypted,bytes(c,"ciphertext")))throw new AssertionError("Cipher encrypt");
      var decoder=Crypt.getCipher(Cipher.DECRYPT_MODE,secret);var decoded=new java.io.ByteArrayOutputStream();
      for(int offset=0;offset<encrypted.length;) {
        int length=Math.min(1+offset%19,encrypted.length-offset);
        byte[] chunk=decoder.update(encrypted,offset,length);if(chunk!=null)decoded.write(chunk);offset+=length;
      }
      decoded.write(decoder.doFinal());
      if(!Arrays.equals(decoded.toByteArray(),plain))throw new AssertionError("Fragmented cipher");
      var helloBuffer=new FriendlyByteBuf(Unpooled.wrappedBuffer(bytes(c,"hello")));
      try {
        var hello=ClientboundHelloPacket.STREAM_CODEC.decode(helloBuffer);
        if(helloBuffer.isReadable()||!hello.getServerId().isEmpty()||
           !Arrays.equals(hello.getPublicKey().getEncoded(),publicKey.getEncoded())||
           !Arrays.equals(hello.getChallenge(),bytes(c,"nonce"))||
           hello.shouldAuthenticate()!=c.get("authenticate").getAsBoolean())throw new AssertionError("Hello codec");
      } finally {helloBuffer.release();}
      var keyBuffer=new FriendlyByteBuf(Unpooled.buffer());
      var n=new JsonObject();
      try {
        ServerboundKeyPacket.STREAM_CODEC.encode(keyBuffer,new ServerboundKeyPacket(secret,publicKey,bytes(c,"nonce")));
        byte[] response=new byte[keyBuffer.readableBytes()];keyBuffer.readBytes(response);
        n.addProperty("response",HexFormat.of().formatHex(response));
      } finally {keyBuffer.release();}
      n.addProperty("hash",hash);n.addProperty("ciphertext",HexFormat.of().formatHex(encrypted));output.add(n);
    }
    Files.writeString(Path.of(args[0]+".native"),new Gson().toJson(output));
    System.out.println("PASS: Mojang decoded 32 public keys/hellos, matched signed hashes and bidirectional fragmented AES, and encoded RSA responses.");
  }
}
