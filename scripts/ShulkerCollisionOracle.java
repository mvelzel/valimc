import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.BlockPos;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.core.Direction;
import net.minecraft.core.Direction.Axis;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundBlockEventPacket;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.shapes.*;
import java.lang.reflect.Proxy;
import java.nio.file.*;
import java.util.*;

/** Actual native world-dependent block lookup, with explicit block-entity fixtures. */
public class ShulkerCollisionOracle {
  private static JsonArray vector(double... v){var a=new JsonArray();for(double x:v)a.add(x);return a;}
  private static final CollisionContext CONTEXT=CollisionContext.empty();
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var catalog=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();
    var oldField=ShulkerBoxBlockEntity.class.getDeclaredField("progressOld");oldField.setAccessible(true);
    var currentField=ShulkerBoxBlockEntity.class.getDeclaredField("progress");currentField.setAccessible(true);
    var pairs=new ArrayList<float[]>();
    for(float progress:new float[]{0f,0.1f,0.2f,0.25f,0.5f,0.9f,1f}) {
      pairs.add(new float[]{0f,progress});pairs.add(new float[]{progress,progress});pairs.add(new float[]{1f,progress});
    }
    for(float progress:new float[]{Math.nextDown(2e-7f),2e-7f,Math.nextUp(2e-7f),Float.MIN_VALUE})
      pairs.add(new float[]{0f,progress});
    var random=new Random(2603144);
    for(int i=0;i<8;i++)pairs.add(new float[]{random.nextFloat(),random.nextFloat()});
    var cases=new JsonArray();
    for(var entry:catalog.getAsJsonObject("shulker_box").getAsJsonArray("states")) {
      int id=entry.getAsJsonArray().get(0).getAsInt();var state=Block.BLOCK_STATE_REGISTRY.byId(id);
      for(var pos:List.of(new BlockPos(0,64,0),new BlockPos(-17,-384,17),new BlockPos(1000000,1000000,-1000000))) {
        for(int variant=0;variant<pairs.size()+2;variant++) {
          var facts=new JsonObject();BlockEntity entity;
          if(variant==0){entity=null;facts.addProperty("kind","absent");}
          else if(variant==1){entity=new ChestBlockEntity(pos,Blocks.CHEST.defaultBlockState());facts.addProperty("kind","other");}
          else {
            var shulker=new ShulkerBoxBlockEntity(pos,state);var pair=pairs.get(variant-2);
            oldField.setFloat(shulker,pair[0]);currentField.setFloat(shulker,pair[1]);entity=shulker;
            facts.addProperty("kind","shulker");facts.addProperty("old",pair[0]);facts.addProperty("current",pair[1]);
          }
          var world=(BlockGetter)Proxy.newProxyInstance(BlockGetter.class.getClassLoader(),new Class<?>[]{BlockGetter.class},
            (proxy,method,arguments)->{
              if(method.getName().equals("getBlockEntity")&&arguments[0].equals(pos))return entity;
              throw new AssertionError("Unexpected world query: "+method);
            });
          var shape=state.getCollisionShape(world,pos,CONTEXT);var worldShape=shape.move(pos.getX(),pos.getY(),pos.getZ());
          var c=new JsonObject();c.addProperty("state",id);c.add("position",vector(pos.getX(),pos.getY(),pos.getZ()));
          c.add("context",facts);c.add("geometry",CollisionMetadata.geometry(shape));var queries=new JsonArray();
          for(var axis:Axis.values())for(int direction:new int[]{-1,1}) {
            double[] origin={pos.getX(),pos.getY(),pos.getZ()};
            double[] lo={origin[0]+0.2,origin[1]+0.1,origin[2]+0.2};
            double[] hi={origin[0]+0.8,origin[1]+1.9,origin[2]+0.8};int a=axis.ordinal();
            if(direction>0){hi[a]=origin[a]-0.75;lo[a]=hi[a]-0.6;}
            else{lo[a]=origin[a]+1.75;hi[a]=lo[a]+0.6;}
            var box=new AABB(lo[0],lo[1],lo[2],hi[0],hi[1],hi[2]);double delta=direction*4.0;
            double result=Shapes.collide(axis,box,List.of(worldShape),delta);var q=new JsonObject();
            q.addProperty("axis",axis.getName());q.addProperty("delta",delta);
            q.add("box",vector(box.minX,box.minY,box.minZ,box.maxX,box.maxY,box.maxZ));
            q.addProperty("result_bits",HexFormat.of().toHexDigits(Double.doubleToRawLongBits(result)));queries.add(q);
          }
          c.add("queries",queries);cases.add(c);
        }
      }
    }
    Files.writeString(Path.of(args[1]),new Gson().toJson(cases));
    if(args.length>2) {
      var registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
      var events=new JsonObject();var state=Blocks.SHULKER_BOX.defaultBlockState().setValue(ShulkerBoxBlock.FACING,Direction.UP);
      events.addProperty("state",Block.getId(state));
      for(int count:new int[]{0,1}) {
        var packet=new ClientboundBlockEventPacket(new BlockPos(0,64,0),Blocks.SHULKER_BOX,1,count);
        var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
        try {
          ClientboundBlockEventPacket.STREAM_CODEC.encode(buf,packet);byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);
          var input=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(bytes),registries);
          try {
            var decoded=ClientboundBlockEventPacket.STREAM_CODEC.decode(input);
            if(input.isReadable()||decoded.getB0()!=1||decoded.getB1()!=count||decoded.getBlock()!=Blocks.SHULKER_BOX)
              throw new AssertionError("Event codec mismatch");
          }
          finally {input.release();}
          events.addProperty(count==1?"open":"close",HexFormat.of().formatHex(bytes));
        } finally {buf.release();}
      }
      Files.writeString(Path.of(args[2]),new Gson().toJson(events));
    }
    System.out.println("PASS: "+cases.size()+" native shulker snapshots / "+cases.size()*6+" clipping queries across 102 states.");
  }
}
