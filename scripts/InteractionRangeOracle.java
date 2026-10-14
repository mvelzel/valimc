import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.core.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundUpdateAttributesPacket;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.*;
import java.nio.file.*;
import java.util.*;

/** Original pinned attribute codec/box-arithmetic probe. No gameplay server starts. */
public class InteractionRangeOracle {
  private static RegistryAccess.Frozen access;
  private static final Gson gson=new Gson();
  private static AttributeModifier nativeModifier(String field) throws Exception {
    var f=ServerPlayer.class.getDeclaredField(field);f.setAccessible(true);return (AttributeModifier)f.get(null);
  }
  private static List<AttributeInstance> attributes(GameType mode) throws Exception {
    var block=new AttributeInstance(Attributes.BLOCK_INTERACTION_RANGE,a -> {});
    var entity=new AttributeInstance(Attributes.ENTITY_INTERACTION_RANGE,a -> {});
    if(mode==GameType.CREATIVE) {
      block.addTransientModifier(nativeModifier("CREATIVE_BLOCK_INTERACTION_RANGE_MODIFIER"));
      entity.addTransientModifier(nativeModifier("CREATIVE_ENTITY_INTERACTION_RANGE_MODIFIER"));
    }
    return List.of(block,entity);
  }
  private static RegistryFriendlyByteBuf buffer() { return new RegistryFriendlyByteBuf(Unpooled.buffer(),access); }
  private static JsonArray vector(double... values) {var a=new JsonArray();for(double v:values)a.add(v);return a;}
  private static JsonObject geometry(GameType mode, BlockPos pos, Vec3 eye, double range) {
    double distance=new AABB(pos).distanceToSqr(eye);
    var c=new JsonObject();c.addProperty("mode",mode.getName());
    c.add("block",vector(pos.getX(),pos.getY(),pos.getZ()));c.add("eye",vector(eye.x,eye.y,eye.z));
    c.addProperty("distance",distance);c.addProperty("within",distance<(range+1.0)*(range+1.0));return c;
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    access=new RegistryAccess.ImmutableRegistryAccess(List.of(BuiltInRegistries.ATTRIBUTE)).freeze();
    if(args[0].equals("verify")) {verify(args[1]);return;}
    var output=new JsonObject();var packets=new JsonArray();var boxes=new JsonArray();var hits=new JsonArray();
    for(var mode:GameType.values()) {
      var attrs=attributes(mode);var buf=buffer();try {
        ClientboundUpdateAttributesPacket.STREAM_CODEC.encode(buf,new ClientboundUpdateAttributesPacket(42,attrs));
        byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);
        var c=new JsonObject();c.addProperty("mode",mode.getName());c.addProperty("body",HexFormat.of().formatHex(bytes));
        c.addProperty("block_range",attrs.get(0).getValue());c.addProperty("entity_range",attrs.get(1).getValue());packets.add(c);
      } finally {buf.release();}
      double range=attrs.get(0).getValue();
      for(int x:new int[]{0,-12345,30000000}) {
        var pos=new BlockPos(x,64,-7);
        for(double d:new double[]{0,range,range+1,Math.nextDown(range+1),Math.nextUp(range+1),8.5,-6.0}) {
          boxes.add(geometry(mode,pos,new Vec3(x+1+d,64.5,-6.5),range));
          boxes.add(geometry(mode,pos,new Vec3(x+0.5,65+d,-6.5),range));
          boxes.add(geometry(mode,pos,new Vec3(x+0.5,64.5,-6+d),range));
        }
      }
      var random=new Random(18301);
      for(int i=0;i<1024;i++) {
        var pos=new BlockPos(random.nextInt(100000)-50000,random.nextInt(384)-64,random.nextInt(100000)-50000);
        boxes.add(geometry(mode,pos,new Vec3(pos.getX()+random.nextDouble()*16-8,
          pos.getY()+random.nextDouble()*16-8,pos.getZ()+random.nextDouble()*16-8),range));
      }
    }
    for(int x:new int[]{0,-12345,30000000}) for(int axis=0;axis<3;axis++)
      for(float v:new float[]{-0.5000001f,-0.5f,-0.4999999f,0,0.5f,1,1.4999999f,1.5f,1.5000001f,
        Float.MAX_VALUE,Float.NaN,Float.POSITIVE_INFINITY,Float.NEGATIVE_INFINITY}) {
        double[] cursor={0.5,0.5,0.5};cursor[axis]=v;double[] pos={x,64,-7};boolean valid=true;
        for(int i=0;i<3;i++)valid&=Math.abs((pos[i]+cursor[i])-(pos[i]+0.5))<1.0000001;
        var bytes=java.nio.ByteBuffer.allocate(12);for(double value:cursor)bytes.putFloat((float)value);
        var c=new JsonObject();c.add("block",vector(pos));
        c.addProperty("cursor_hex",HexFormat.of().formatHex(bytes.array()));c.addProperty("valid",valid);hits.add(c);
      }
    output.add("packets",packets);output.add("boxes",boxes);output.add("hits",hits);
    Files.writeString(Path.of(args[0]),gson.toJson(output));
    System.out.println("PASS: four native mode-attribute bodies, "+boxes.size()+" box distances and "+hits.size()+" hit boundaries.");
  }
  private static void verify(String file) throws Exception {
    var cases=JsonParser.parseString(Files.readString(Path.of(file))).getAsJsonArray();int count=0;
    for(var element:cases) {
      var c=element.getAsJsonObject();var mode=GameType.byName(c.get("mode").getAsString(),GameType.SURVIVAL);
      var expected=new ClientboundUpdateAttributesPacket(42,attributes(mode));var buf=buffer();try {
        buf.writeBytes(HexFormat.of().parseHex(c.get("body").getAsString()));
        var actual=ClientboundUpdateAttributesPacket.STREAM_CODEC.decode(buf);
        if(buf.isReadable()||actual.getEntityId()!=42||actual.getValues().size()!=expected.getValues().size())
          throw new AssertionError("Elixir attribute header differs");
        for(int i=0;i<expected.getValues().size();i++) {
          var a=actual.getValues().get(i);var e=expected.getValues().get(i);
          if(!a.attribute().equals(e.attribute())||Double.doubleToLongBits(a.base())!=Double.doubleToLongBits(e.base())||
            !new HashSet<>(a.modifiers()).equals(new HashSet<>(e.modifiers())))
            throw new AssertionError("Elixir range holder/base/modifier differs");
        }
        count++;
      } finally {buf.release();}
    }
    System.out.println("PASS: native decoding of "+count+" Elixir interaction attribute packets.");
  }
}
