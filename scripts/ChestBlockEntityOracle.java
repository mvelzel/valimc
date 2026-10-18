import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.*;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.game.ClientboundBlockEntityDataPacket;
import net.minecraft.network.protocol.game.ClientboundLevelChunkWithLightPacket;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.item.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.properties.ChestType;
import io.netty.buffer.Unpooled;

/** Original observations of empty chest presentation, including non-disclosure of stored items. */
public class ChestBlockEntityOracle {
  static RegistryAccess access;
  static class World extends ServerLevel {
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public RegistryAccess registryAccess(){return access;}
  }
  static String hex(RegistryFriendlyByteBuf buffer){var bytes=new byte[buffer.readableBytes()];buffer.getBytes(0,bytes);return HexFormat.of().formatHex(bytes);}
  @SuppressWarnings("unchecked")
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(World)u.allocateInstance(World.class);
    var info=Class.forName("net.minecraft.network.protocol.game.ClientboundLevelChunkPacketData$BlockEntityInfo");
    var create=info.getDeclaredMethod("create",BlockEntity.class);create.setAccessible(true);
    var codecField=info.getDeclaredField("STREAM_CODEC");codecField.setAccessible(true);
    var codec=(StreamCodec<RegistryFriendlyByteBuf,Object>)codecField.get(null);
    var cases=new JsonArray();
    for(var state:Blocks.CHEST.getStateDefinition().getPossibleStates())if(state.getValue(ChestBlock.TYPE)==ChestType.SINGLE)
    for(var pos:List.of(BlockPos.ZERO,new BlockPos(15,-64,15),new BlockPos(-1,319,-17),new BlockPos(29999983,63,-29999984)))
    for(boolean occupied:new boolean[]{false,true}) {
      var entity=new ChestBlockEntity(pos,state);
      if(occupied)entity.setItem(0,new ItemStack(Items.DIAMOND,64));
      entity.setLevel(world);
      var row=new JsonObject();row.addProperty("state",Block.getId(state));row.addProperty("occupied",occupied);
      row.add("position",new Gson().toJsonTree(List.of(pos.getX(),pos.getY(),pos.getZ())));
      var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try {
        codec.encode(buffer,create.invoke(null,entity));row.addProperty("chunk_hex",hex(buffer));
        codec.decode(buffer);if(buffer.isReadable())throw new AssertionError("Trailing chest entry bytes");buffer.clear();
        ClientboundBlockEntityDataPacket.STREAM_CODEC.encode(buffer,ClientboundBlockEntityDataPacket.create(entity));
        row.addProperty("update_hex",hex(buffer));
        var decoded=ClientboundBlockEntityDataPacket.STREAM_CODEC.decode(buffer);
        if(buffer.isReadable()||!decoded.getPos().equals(pos)||decoded.getType()!=BlockEntityTypes.CHEST||!decoded.getTag().isEmpty())throw new AssertionError("Chest update leaked stored items or changed identity");
      }finally{buffer.release();}
      cases.add(row);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("protocol",777);
    out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("block_entity_type",BuiltInRegistries.BLOCK_ENTITY_TYPE.getId(BlockEntityTypes.CHEST));out.add("cases",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    if(args.length==2) {
      var chunks=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for(var value:chunks) {
        var row=value.getAsJsonObject();var bytes=HexFormat.of().parseHex(row.get("wire").getAsString());
        var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(bytes),access);
        try {
          var packet=ClientboundLevelChunkWithLightPacket.STREAM_CODEC.decode(buffer);
          if(buffer.isReadable()||packet.x()!=row.get("x").getAsInt()||packet.z()!=row.get("z").getAsInt())throw new AssertionError("Bad complete chunk");
          var actual=new HashSet<String>();var expected=new HashSet<String>();
          for(var p:row.getAsJsonArray("positions"))expected.add(p.toString());
          packet.chunkData().forEachBlockEntityTag(packet.x(),packet.z(),(pos,type,tag)->{
            if(type!=BlockEntityTypes.CHEST||(tag!=null&&!tag.isEmpty()))throw new AssertionError("Incorrect chest data");
            if(!actual.add(new Gson().toJson(List.of(pos.getX(),pos.getY(),pos.getZ()))))throw new AssertionError("Duplicate chest entry");
          });
          if(!actual.equals(expected))throw new AssertionError("Wrong complete chunk entries: "+actual+" expected "+expected);
        }finally{buffer.release();}
      }
      System.out.println("PASS: Mojang decoded "+chunks.size()+" complete Elixir chest chunks with exact positions/types and no stored-item disclosure.");
    }
    System.out.println("PASS: "+cases.size()+" actual chest chunk-entry/update encodes/decodes, including stored-item non-disclosure; live chunk/render/menu/lifecycle excluded.");
  }
}
