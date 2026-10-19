import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundSetExperiencePacket;

/** Original calls to native XP arithmetic and the native packet codec. World/sound I/O is excluded. */
public class PlayerExperienceOracle {
 static class Probe extends Player {
  private Probe(){super(null,null);}
  public GameType gameMode(){return GameType.SURVIVAL;}
  public void increaseScore(int n){} // score/advancement plumbing is outside this arithmetic probe
 }
 static String packet(Player p){
  var b=new FriendlyByteBuf(Unpooled.buffer());
  try{
   var packet=new ClientboundSetExperiencePacket(p.experienceProgress,p.totalExperience,p.experienceLevel);
   ClientboundSetExperiencePacket.STREAM_CODEC.encode(b,packet);
   byte[] bytes=new byte[b.readableBytes()]; b.getBytes(0,bytes);
   var decoded=ClientboundSetExperiencePacket.STREAM_CODEC.decode(b);
   if(b.isReadable() || decoded.getExperienceLevel()!=p.experienceLevel || decoded.getTotalExperience()!=p.totalExperience || decoded.getExperienceProgress()!=p.experienceProgress)throw new AssertionError();
   return HexFormat.of().formatHex(bytes);
  }finally{b.release();}
 }
 static JsonObject state(Player p){
  var s=new JsonObject();s.addProperty("level",p.experienceLevel);s.addProperty("progress",(double)p.experienceProgress);s.addProperty("total",p.totalExperience);return s;
 }
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();
  var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
  var levelSound=Player.class.getDeclaredField("lastLevelUpTime");levelSound.setAccessible(true);
  var rows=new JsonArray();
  for(int level:new int[]{0,1,14,15,16,29,30,31,99,1000,21863})
   for(float progress:new float[]{0f,Float.MIN_VALUE,.1f,.5f,Math.nextDown(1f)})
    for(int amount:new int[]{0,1,3,7,17,37,73,149,307,617,1237,2477}){
     var p=(Probe)u.allocateInstance(Probe.class);levelSound.setInt(p,Integer.MAX_VALUE);
     p.experienceLevel=level;p.experienceProgress=progress;p.totalExperience=13;
     var row=new JsonObject();row.add("before",state(p));row.addProperty("amount",amount);
     p.giveExperiencePoints(amount);row.add("after",state(p));row.addProperty("packet",packet(p));rows.add(row);
    }
  Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
  var contact = new JsonArray();
  var dimensions = net.minecraft.world.entity.EntityTypes.EXPERIENCE_ORB.getDimensions();
  for(double height:new double[]{1.8,1.5,.6})
   for(double x:new double[]{-1.551,-1.55,-1.549,-1,0,1,1.549,1.55,1.551})
    for(double y:new double[]{-.501,-.5,-.499,0,1,2.299,2.3,2.301})
     for(double z:new double[]{-1.551,-1.55,-1,0,1,1.55,1.551}){
      var query=new net.minecraft.world.phys.AABB(-.3,64,-.3,.3,64+height,.3).inflate(1,.5,1);
      var box=dimensions.makeBoundingBox(x,64+y,z);
      contact.add(new Gson().toJsonTree(Map.of("height",height,"at",new double[]{x,64+y,z},"contact",query.intersects(box))));
     }
  Files.writeString(Path.of(args[0]+".contact.json"),new Gson().toJson(contact));
  System.out.println("Native XP dimensions "+dimensions.width()+" x "+dimensions.height()+"; "+contact.size()+" actual AABB contacts.");
  System.out.println("PASS: "+rows.size()+" native positive XP arithmetic and packet round trips; score/sound and overflow excluded.");
 }
}
