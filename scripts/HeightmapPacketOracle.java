import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundLevelChunkWithLightPacket;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.SimpleBitStorage;
import net.minecraft.world.level.levelgen.Heightmap;

/** Decode Elixir chunk packets and compare both heightmaps with actual native-update expectations. */
public class HeightmapPacketOracle {
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    var rows=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonArray();int checked=0;
    for(var value:rows){
      var row=value.getAsJsonObject();var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(row.get("wire").getAsString())),registries);
      try {
        var chunk=ClientboundLevelChunkWithLightPacket.STREAM_CODEC.decode(buffer);
        if(buffer.isReadable()||chunk.x()!=0||chunk.z()!=0)throw new AssertionError("Malformed chunk fixture");
        var maps=chunk.chunkData().getHeightmaps();
        if(!maps.keySet().equals(Set.of(Heightmap.Types.WORLD_SURFACE,Heightmap.Types.MOTION_BLOCKING)))throw new AssertionError("Wrong published heightmap types");
        var surface=new SimpleBitStorage(9,256,maps.get(Heightmap.Types.WORLD_SURFACE));
        var motion=new SimpleBitStorage(9,256,maps.get(Heightmap.Types.MOTION_BLOCKING));
        for(int i=0;i<256;i++){
          var pair=row.getAsJsonArray("expected").get(i).getAsJsonArray();
          if(surface.get(i)!=pair.get(0).getAsInt()||motion.get(i)!=pair.get(1).getAsInt())throw new AssertionError("Native chunk height differs at "+i+": "+surface.get(i)+"/"+motion.get(i)+" expected "+pair);
          checked+=2;
        }
      } finally {buffer.release();}
    }
    System.out.println("PASS: Mojang decoded "+rows.size()+" complete chunk packets and "+checked+" independent surface/motion height values from native update traces.");
  }
}
