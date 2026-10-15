import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundInitializeBorderPacket;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.level.CollisionGetter;
import net.minecraft.world.level.border.WorldBorder;
import net.minecraft.world.phys.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;

/** Original fixtures invoke native stationary-border geometry and collision policy. */
public class BorderCollisionOracle {
  private static JsonArray bits(double... values) {
    var a=new JsonArray();for(double v:values)a.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(v)));return a;
  }
  private static JsonArray box(AABB b){return bits(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ);}
  private static String packet(WorldBorder border) {
    var buf=new FriendlyByteBuf(Unpooled.buffer());
    try {
      ClientboundInitializeBorderPacket.STREAM_CODEC.encode(buf,new ClientboundInitializeBorderPacket(border));
      byte[] b=new byte[buf.readableBytes()];buf.readBytes(b);return HexFormat.of().formatHex(b);
    }finally {buf.release();}
  }
  public static void main(String[] args) throws Throwable {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var u=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");u.setAccessible(true);var unsafe=(sun.misc.Unsafe)u.get(null);
    var entity=(Entity)unsafe.allocateInstance(ItemEntity.class);
    var position=Entity.class.getDeclaredField("position");position.setAccessible(true);
    var cases=new JsonArray();var fixtures=new JsonArray();
    for(var center:List.of(new Vec3(0,0,0),new Vec3(-17.25,0,31.5),new Vec3(29999980,0,-29999980)))
      for(double diameter:new double[]{0,1,3.5,16,100,59999968})for(int absolute:new int[]{0,32,29999984}) {
        var border=new WorldBorder();border.setCenter(center.x,center.z);border.setAbsoluteMaxSize(absolute);border.setSize(diameter);
        var getter=(CollisionGetter)Proxy.newProxyInstance(CollisionGetter.class.getClassLoader(),new Class<?>[]{CollisionGetter.class},
          (p,m,a)->m.isDefault()?InvocationHandler.invokeDefault(p,m,a):m.getName().equals("getWorldBorder")?border:null);
        double x0=border.getMinX(),z0=border.getMinZ(),x1=border.getMaxX(),z1=border.getMaxZ();
        var locations=List.of(new Vec3(center.x,64,center.z),new Vec3(x0,64,z0),new Vec3(x1,64,z1),
          new Vec3(x0-.3,64,(z0+z1)/2),new Vec3(x0+.3,64,(z0+z1)/2),
          new Vec3(x1-.3,64,(z0+z1)/2),new Vec3(x1+.3,64,(z0+z1)/2),
          new Vec3((x0+x1)/2,64,z0-.3),new Vec3((x0+x1)/2,64,z0+.3),
          new Vec3((x0+x1)/2,64,z1-.3),new Vec3((x0+x1)/2,64,z1+.3),
          new Vec3(x0-1,64,z0),new Vec3(x1+1,64,z1),new Vec3(x0-2,64,z0),new Vec3(x1+2,64,z1));
        for(var pos:locations)for(double half:new double[]{0,1e-8,5e-8,1e-7,.3,1}) {
          var b=new AABB(pos.x-half,64,pos.z-half,pos.x+half,65.8,pos.z+half);position.set(entity,pos);
          var c=new JsonObject();c.add("center",bits(center.x,center.z));c.addProperty("diameter",diameter);c.addProperty("absolute_max",absolute);
          c.add("bounds",bits(x0,z0,x1,z1));c.add("point",bits(pos.x,pos.z));c.add("box",box(b));
          c.addProperty("contains_point",border.isWithinBounds(pos));c.addProperty("contains_box",border.isWithinBounds(b));
          c.add("distance",bits(border.getDistanceToBorder(entity)));c.addProperty("clear",getter.noBorderCollision(entity,b));
          c.addProperty("anonymous_clear",getter.noBorderCollision(null,b));cases.add(c);
        }
      }
    // Small native packets are private fixtures for the separate actual-client gate.
    for(double size:new double[]{8,59999968}) {
      var b=new WorldBorder();b.setCenter(.25,-.25);b.setSize(size);
      var f=new JsonObject();f.addProperty("diameter",size);f.addProperty("initialize_payload",packet(b));fixtures.add(f);
    }
    var result=new JsonObject();result.add("cases",cases);result.add("client_fixtures",fixtures);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" native stationary border/collision cases and two private client packets.");
  }
}
