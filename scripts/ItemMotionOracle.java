import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.core.BlockPos;
import net.minecraft.tags.TagKey;
import net.minecraft.world.level.material.Fluid;
/** Original native tick observations; collision, contacts and refresh phase are supplied. */
public class ItemMotionOracle {
 static class World extends ServerLevel {
  Block support;
  private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public int getNextEntityId(){return 1;}
  public boolean noCollision(Entity e,AABB box){return true;}
  public BlockState getBlockState(BlockPos pos){return support.defaultBlockState();}
 }
 static class Item extends ItemEntity {
  boolean grounded; int fluid; double depth; Vec3 requested;
  Item(World w,Vec3 velocity){super(w,10.5,80,10.5,new ItemStack(Items.OAK_PLANKS,4),velocity.x,velocity.y,velocity.z);}
  public void baseTick(){}
  public boolean onGround(){return grounded;}
  public boolean isInWater(){return fluid==1;}
  public boolean isInLava(){return fluid==2;}
  public double getFluidHeight(TagKey<Fluid> type){return depth;}
  public boolean updateFluidInteraction(){return false;}
  public void move(MoverType kind,Vec3 velocity){requested=velocity;}
  public void applyEffectsFromBlocks(){}
  public void applyEffectsFromBlocksForLastMovements(){}
  public BlockPos getBlockPosBelowThatAffectsMyMovement(){return BlockPos.ZERO;}
 }
 static double[] vector(Vec3 v){return new double[]{v.x,v.y,v.z};}
 public static void main(String[]args)throws Exception {
  MiningToolOracle.initialize();var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
  var world=(World)unsafe.allocateInstance(World.class);var cases=new JsonArray();
  var age=ItemEntity.class.getDeclaredField("age");age.setAccessible(true);var delay=ItemEntity.class.getDeclaredField("pickupDelay");delay.setAccessible(true);
  for(Block support:new Block[]{Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK})for(int fluid=0;fluid<3;fluid++)for(double depth:new double[]{0,(double).1f,(double)Math.nextUp(.1f),.5})for(boolean ground:new boolean[]{false,true})for(boolean noGravity:new boolean[]{false,true})for(int tick:new int[]{1,3})for(Vec3 input:List.of(Vec3.ZERO,new Vec3(.3,.1,-.2),new Vec3(.000001,-.04,0),new Vec3(0,-1,0))) {
   world.support=support;var item=new Item(world,input);item.grounded=ground;item.fluid=fluid;item.depth=depth;item.tickCount=tick;item.setNoGravity(noGravity);item.setPickUpDelay(40);item.tick();
   var row=new JsonObject();row.addProperty("friction",support.getFriction());row.addProperty("fluid",fluid);row.addProperty("depth",depth);row.addProperty("ground",ground);row.addProperty("no_gravity",noGravity);row.addProperty("tick",tick);row.add("input",new Gson().toJsonTree(vector(input)));row.add("requested",item.requested==null?JsonNull.INSTANCE:new Gson().toJsonTree(vector(item.requested)));row.add("velocity",new Gson().toJsonTree(vector(item.getDeltaMovement())));row.addProperty("age",age.getInt(item));row.addProperty("pickup_delay",delay.getInt(item));cases.add(row);
  }
  Files.writeString(Path.of(args[0]),new Gson().toJson(cases));System.out.println("PASS:"+cases.size()+" actual native item physics ticks; supplied collision/contacts, merge scheduling excluded.");
 }
}
