import com.google.gson.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.*;
import java.nio.file.*;
import java.util.*;

/** Original controlled-fit probe invokes native player pose selection and dimensions. */
public class PlayerPoseOracle {
  private static class ProbePlayer extends Player {
    int intent,fitMask;Pose pose;List<Pose> queries;
    private ProbePlayer(){super(null,null);}
    public GameType gameMode(){return (intent&64)!=0?GameType.SPECTATOR:GameType.CREATIVE;}
    public boolean isSleeping(){return (intent&1)!=0;}
    public boolean isSwimming(){return (intent&2)!=0;}
    public boolean isFallFlying(){return (intent&4)!=0;}
    public boolean isAutoSpinAttack(){return (intent&8)!=0;}
    public boolean isShiftKeyDown(){return (intent&16)!=0;}
    public boolean isPassenger(){return (intent&128)!=0;}
    public Pose getPose(){return pose;}
    public void setPose(Pose value){pose=value;}
    protected boolean canPlayerFitWithinBlocksAndEntitiesWhen(Pose value) {
      queries.add(value);return (fitMask&(1<<value.ordinal()))!=0;
    }
    void update(){updatePlayerPose();}
  }
  private static JsonArray bits(double... values) {
    var a=new JsonArray();for(double v:values)a.add(HexFormat.of().toHexDigits(Double.doubleToRawLongBits(v)));return a;
  }
  private static JsonArray box(AABB b){return bits(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ);}
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);
    var p=(ProbePlayer)unsafe.allocateInstance(ProbePlayer.class);var abilities=new Abilities();
    var af=Player.class.getDeclaredField("abilities");af.setAccessible(true);af.set(p,abilities);
    var poses=new JsonArray();var geometry=new JsonArray();var cases=new JsonArray();
    for(var pose:Pose.values()) {
      var dims=p.getDefaultDimensions(pose);var c=new JsonObject();c.addProperty("name",pose.getSerializedName());
      c.addProperty("id",pose.id());c.addProperty("width",(double)dims.width());c.addProperty("height",(double)dims.height());
      c.addProperty("eye_height",(double)dims.eyeHeight());c.addProperty("fixed",dims.fixed());poses.add(c);
      for(var pos:List.of(Vec3.ZERO,new Vec3(.5,64,.5),new Vec3(-17.125,-64,16.75),new Vec3(29999984,999999,-29999984))) {
        var g=new JsonObject();g.addProperty("pose",pose.getSerializedName());g.add("position",bits(pos.x,pos.y,pos.z));
        var b=dims.makeBoundingBox(pos);g.add("box",box(b));g.add("fit_box",box(b.deflate(1e-7)));
        g.add("eye",bits(pos.x,pos.y+(double)dims.eyeHeight(),pos.z));geometry.add(g);
      }
    }
    for(int intent=0;intent<256;intent++)for(int fits=0;fits<64;fits++)
      for(var initial:List.of(Pose.STANDING,Pose.CROUCHING,Pose.SWIMMING,Pose.DYING)) {
        p.intent=intent;p.fitMask=fits;p.pose=initial;p.queries=new ArrayList<>();abilities.flying=(intent&32)!=0;
        p.update();var c=new JsonObject();c.addProperty("intent",intent);c.addProperty("fits",fits);
        c.addProperty("current",initial.getSerializedName());c.addProperty("selected",p.pose.getSerializedName());
        var q=new JsonArray();for(var query:p.queries)q.add(query.getSerializedName());c.add("queries",q);cases.add(c);
      }
    var output=new JsonObject();output.add("poses",poses);output.add("geometry",geometry);output.add("cases",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: "+poses.size()+" native dimensions, "+geometry.size()+" exact box/eye fixtures and "+cases.size()+" pose-selection traces.");
  }
}
