import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;
import net.minecraft.world.phys.Vec3;
import net.minecraft.util.RandomSource;
/** Original native item-launch observations; world ID allocation is controlled. */
public class ItemDropOracle {
 static class World extends ServerLevel {
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
 }
 static class Probe extends Player {
  World world; float yaw,pitch,eye;
  private Probe(){super(null,null);}
  public World level(){return world;}
  public net.minecraft.world.level.GameType gameMode(){return net.minecraft.world.level.GameType.SURVIVAL;}
  public float getYRot(){return yaw;}
  public float getXRot(){return pitch;}
  public double getEyeY(){return 80.0+(double)eye;}
 }
 static void put(Class<?> type,Object owner,String name,Object value)throws Exception {var f=type.getDeclaredField(name);f.setAccessible(true);f.set(owner,value);}
 public static void main(String[]args)throws Exception {
  MiningToolOracle.initialize();
  var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);
  var player=(Probe)unsafe.allocateInstance(Probe.class);player.world=(World)unsafe.allocateInstance(World.class);
  put(Entity.class,player,"position",new Vec3(10.5,80,10.5));put(Entity.class,player,"uuid",new UUID(0,1));
  var cases=new JsonArray();
  for(float yaw:new float[]{0,45,90,180,-90,359.9f})for(float pitch:new float[]{-90,-30,0,15,90})for(float eye:new float[]{1.62f,1.27f,.4f})for(boolean scatter:new boolean[]{false,true})for(int seed=0;seed<4;seed++) {
   player.yaw=yaw;player.pitch=pitch;player.eye=eye;var random=RandomSource.create(seed);put(Entity.class,player,"random",random);
   var draws=new float[4];var copy=RandomSource.create(seed);for(int i=0;i<4;i++)draws[i]=copy.nextFloat();
   ItemEntity item=player.createItemStackToDrop(new ItemStack(Items.OAK_PLANKS,4),scatter,true);
   var delay=ItemEntity.class.getDeclaredField("pickupDelay");delay.setAccessible(true);
   var row=new JsonObject();row.addProperty("yaw",yaw);row.addProperty("pitch",pitch);row.addProperty("eye",eye);row.addProperty("scatter",scatter);row.add("random",new Gson().toJsonTree(draws));row.add("position",new Gson().toJsonTree(new double[]{item.getX(),item.getY(),item.getZ()}));row.add("velocity",new Gson().toJsonTree(new double[]{item.getDeltaMovement().x,item.getDeltaMovement().y,item.getDeltaMovement().z}));row.addProperty("pickup_delay",delay.getInt(item));cases.add(row);
  }
  Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS:"+cases.size()+" actual native directed/scattered drop launches.");
 }
}
