import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;

/** Actual native pair callbacks; world discovery and scheduling are deliberately excluded. */
public class ItemMergeOracle {
 static class World extends ServerLevel {
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
 }
 static class Probe extends ItemEntity {
  boolean live=true, removed;
  Probe(World world,ItemStack stack){super(world,.5,64,.5,stack,0,0,0);}
  public boolean isAlive(){return live&&!removed;}
  public void remove(Entity.RemovalReason reason){removed=true;}
 }
 static RegistryAccess.Frozen registries;
 static Field field(String name)throws Exception{var f=ItemEntity.class.getDeclaredField(name);f.setAccessible(true);return f;}
 static Method method(String name,Class<?>... types)throws Exception{var m=ItemEntity.class.getDeclaredMethod(name,types);m.setAccessible(true);return m;}
 static String stack(ItemStack s){
  var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
  try{ItemStack.OPTIONAL_STREAM_CODEC.encode(buf,s);var bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buf.release();}
 }
 static JsonObject input(Probe p)throws Exception{
  var o=new JsonObject();o.addProperty("stack",stack(p.getItem()));o.addProperty("age",field("age").getInt(p));o.addProperty("delay",field("pickupDelay").getInt(p));o.addProperty("alive",p.isAlive());
  var target=(UUID)field("target").get(p);o.add("target",target==null?JsonNull.INSTANCE:new JsonPrimitive(target.toString()));return o;
 }
 static JsonObject pair(World world,ItemStack left,ItemStack right,int aa,int ba,int ad,int bd,boolean alive,int targets)throws Exception{
  var a=new Probe(world,left.copy());var b=new Probe(world,right.copy());a.live=alive;
  field("age").setInt(a,aa);field("age").setInt(b,ba);a.setPickUpDelay(ad);b.setPickUpDelay(bd);
  if(targets>0)field("target").set(a,new UUID(0,1));
  if(targets>0)field("target").set(b,new UUID(0,targets));
  var row=new JsonObject();row.add("a",input(a));row.add("b",input(b));
  boolean ae=(boolean)method("isMergable").invoke(a),be=(boolean)method("isMergable").invoke(b);
  boolean allowed=ae&&be&&Objects.equals(field("target").get(a),field("target").get(b))&&ItemEntity.areMergable(a.getItem(),b.getItem());
  row.addProperty("a_eligible",ae);row.addProperty("b_eligible",be);row.addProperty("allowed",allowed);
  if(allowed){
   boolean recipientA=right.getCount()<left.getCount();method("tryToMerge",ItemEntity.class).invoke(a,b);
   var recipient=recipientA?a:b;var donor=recipientA?b:a;
   row.addProperty("recipient",recipientA?"a":"b");row.addProperty("stack",stack(recipient.getItem()));row.addProperty("donor_stack",stack(donor.getItem()));
   row.addProperty("age",field("age").getInt(recipient));row.addProperty("delay",field("pickupDelay").getInt(recipient));row.addProperty("donor_removed",donor.removed);
  }
  return row;
 }
 public static void main(String[] args)throws Exception{
  MiningToolOracle.initialize();registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
  var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);var world=(World)u.allocateInstance(World.class);
  var stacks=new ArrayList<ItemStack>();
  for(var item:List.of(Items.STONE,Items.EGG))for(int count:new int[]{1,2,8,15,16})stacks.add(new ItemStack(item,count));
  for(int count:new int[]{1,2,32,63,64,65,98,99}){var s=new ItemStack(Items.STONE,count);s.set(DataComponents.MAX_STACK_SIZE,99);stacks.add(s);}
  for(int count:new int[]{1,2}){var s=new ItemStack(Items.STONE,count);s.set(DataComponents.CUSTOM_NAME,Component.literal("separate"));stacks.add(s);}
  var explicit=new ItemStack(Items.STONE,1);explicit.set(DataComponents.MAX_STACK_SIZE,64);stacks.add(explicit);
  var cases=new JsonArray();for(var a:stacks)for(var b:stacks)cases.add(pair(world,a,b,10,50,40,0,true,0));
  for(int aa:new int[]{-32768,-6000,0,5999,6000})for(int ba:new int[]{-32768,0,5999,6000})for(int ad:new int[]{0,1,40,32767})for(int bd:new int[]{0,40,32767})for(int target=0;target<3;target++)for(boolean alive:new boolean[]{true,false})
   cases.add(pair(world,new ItemStack(Items.STONE,2),new ItemStack(Items.STONE,3),aa,ba,ad,bd,alive,target));
  var near=new JsonArray();
  for(double x:new double[]{0,.75,Math.nextDown(.75),Math.nextUp(.75),-.75,Math.nextUp(-.75)})for(double y:new double[]{0,.25,Math.nextDown(.25),-.25,Math.nextUp(-.25)})for(double z:new double[]{0,.75,Math.nextDown(.75)}){
   var a=new Probe(world,new ItemStack(Items.STONE));var b=new Probe(world,new ItemStack(Items.STONE));a.setPos(0,0,0);b.setPos(x,y,z);
   var row=new JsonObject();row.add("b",new Gson().toJsonTree(new double[]{x,y,z}));row.addProperty("near",a.getBoundingBox().inflate(.5,0,.5).intersects(b.getBoundingBox()));near.add(row);
  }
  var result=new JsonObject();result.add("pairs",cases);result.add("proximity",near);Files.writeString(Path.of(args[0]),new Gson().toJson(result));
  System.out.println("PASS: "+cases.size()+" actual ItemEntity pair decisions and "+near.size()+" native AABB boundaries; discovery/scheduling excluded.");
 }
}
