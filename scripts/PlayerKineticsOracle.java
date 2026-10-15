import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.material.*;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.item.ItemStack;
import net.minecraft.tags.BlockTags;

/** Actual native jump/Player.travel branches with supplied dry observations and no collisions. */
public class PlayerKineticsOracle {
  private static class ProbeLevel extends ServerLevel {
    BlockState floor; Map<BlockPos,BlockState> blocks;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){return blocks==null?floor:blocks.getOrDefault(pos,Blocks.AIR.defaultBlockState());}
    public FluidState getFluidState(BlockPos pos){return Fluids.EMPTY.defaultFluidState();}
    public BlockGetter getChunkForCollisions(int x,int z){return this;}
    public net.minecraft.world.level.block.entity.BlockEntity getBlockEntity(BlockPos pos){return null;}
  }
  private static final RuntimeException STOP_INPUT=new RuntimeException("Stopped at native input boundary");
  private static class NormalizeProbe extends LivingEntity {
    ProbeLevel world;
    private NormalizeProbe(){super(EntityTypes.PLAYER,null);}
    public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    public ServerLevel level(){return world;}
    protected void applyInput(){throw STOP_INPUT;}
    public MoveSimulationType getMoveSimulationType(){return MoveSimulationType.SERVER_AND_CLIENT;}
    public boolean isDescending(){return false;}
    public boolean isShiftKeyDown(){return false;}
    public ItemStack getMainHandItem(){return ItemStack.EMPTY;}
  }
  private static class ProbePlayer extends Player {
    ProbeLevel world; Abilities abilities; boolean sprint,ground; float factor,yaw;
    private ProbePlayer(){super(null,null);}
    public GameType gameMode(){return GameType.CREATIVE;}
    public ServerLevel level(){return world;}
    public Abilities getAbilities(){return abilities;}
    public boolean isPassenger(){return false;}
    public boolean isSwimming(){return false;}
    public boolean isFallFlying(){return false;}
    public boolean isInLiquid(){return false;}
    public boolean isSprinting(){return sprint;}
    public float getYRot(){return yaw;}
    public boolean onGround(){return ground;}
    public BlockPos getBlockPosBelowThatAffectsMyMovement(){return BlockPos.ZERO;}
    protected float getBlockJumpFactor(){return factor;}
    public float getJumpBoostPower(){return 0;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(attribute==Attributes.JUMP_STRENGTH)return (double).42f;
      if(attribute==Attributes.FRICTION_MODIFIER||attribute==Attributes.AIR_DRAG_MODIFIER)return 1;
      throw new AssertionError("Unexpected attribute "+attribute);
    }
    public float getSpeed(){return 0;}
    protected float getFlyingSpeed(){return 0;}
    public boolean onClimbable(){return false;}
    protected double getEffectiveGravity(){return .08;}
    public MobEffectInstance getEffect(Holder<MobEffect> type){return null;}
    public boolean shouldDiscardFriction(){return false;}
    protected boolean omnidirectionalAirMover(){return false;}
    public void move(MoverType type,Vec3 requested){}
  }
  private static JsonArray vector(Vec3 v){var a=new JsonArray();a.add(v.x);a.add(v.y);a.add(v.z);return a;}
  private static JsonArray pos(BlockPos p){var a=new JsonArray();a.add(p.getX());a.add(p.getY());a.add(p.getZ());return a;}
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);
    var p=(ProbePlayer)unsafe.allocateInstance(ProbePlayer.class);p.world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    p.abilities=new Abilities();var jumps=new JsonArray();var air=new JsonArray();
    for(var initial:List.of(Vec3.ZERO,new Vec3(.2,-1,-.3),new Vec3(-.2,.8,.3)))
      for(float factor:new float[]{0,.00001f,.5f,1})for(boolean sprint:new boolean[]{false,true})
        for(float yaw:new float[]{0,12.345f,45,90,-90,180,-180,359,-359,1000000,-1000000}){
          p.factor=factor;p.sprint=sprint;p.yaw=yaw;p.setDeltaMovement(initial);p.jumpFromGround();
          var c=new JsonObject();c.add("initial",vector(initial));c.addProperty("factor",(double)factor);
          c.addProperty("sprint",sprint);c.addProperty("yaw",(double)yaw);c.add("velocity",vector(p.getDeltaMovement()));jumps.add(c);
        }
    for(var initial:List.of(Vec3.ZERO,new Vec3(.2,-1,-.3),new Vec3(-.2,.8,.3)))
      for(var block:List.of(Blocks.STONE,Blocks.ICE))for(boolean ground:new boolean[]{false,true})for(boolean flying:new boolean[]{false,true}){
        p.world.floor=block.defaultBlockState();p.ground=ground;p.abilities.flying=flying;p.setDeltaMovement(initial);p.travel(Vec3.ZERO);
        var c=new JsonObject();c.add("initial",vector(initial));c.addProperty("ground",ground);c.addProperty("flying",flying);
        c.addProperty("friction",(double)block.getFriction());c.add("velocity",vector(p.getDeltaMovement()));air.add(c);
      }
    var normal=(NormalizeProbe)unsafe.allocateInstance(NormalizeProbe.class);normal.world=p.world;
    field(Entity.class,"type").set(normal,EntityTypes.PLAYER);
    field(LivingEntity.class,"equipment").set(normal,new EntityEquipment());
    field(Entity.class,"interpolationHandler").set(normal,Proxy.newProxyInstance(InterpolationHandler.class.getClassLoader(),new Class<?>[]{InterpolationHandler.class},(proxy,method,a)->false));
    var normalization=new JsonArray();
    for(double x:new double[]{-.003,-.0029,-.002,0,.002,.0029,.003})
      for(double y:new double[]{-.003,-.0029,0,.0029,.003})for(double z:new double[]{-.003,-.0029,-.002,0,.002,.0029,.003}){
        var initial=new Vec3(x,y,z);normal.setDeltaMovement(initial);
        try{normal.aiStep();throw new AssertionError("Input boundary not reached");}catch(RuntimeException error){if(error!=STOP_INPUT)throw error;}
        var c=new JsonObject();c.add("initial",vector(initial));c.add("velocity",vector(normal.getDeltaMovement()));normalization.add(c);
      }
    var support=new JsonArray();var tags=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);tags.setAccessible(true);
    tags.invoke(Blocks.OAK_FENCE.builtInRegistryHolder(),List.of(BlockTags.FENCES));
    tags.invoke(Blocks.COBBLESTONE_WALL.builtInRegistryHolder(),List.of(BlockTags.WALLS));
    for(var floor:List.of(Blocks.STONE,Blocks.ICE,Blocks.SLIME_BLOCK,Blocks.OAK_FENCE,Blocks.COBBLESTONE_WALL,Blocks.STONE_SLAB))
      for(double y:new double[]{63.25,64,64.5,65.5})for(double x:new double[]{-.25,.25,.5,.9,1.1})for(double z:new double[]{-.25,.5,.9,1.1}){
        p.world.blocks=Map.of(new BlockPos(0,63,0),floor.defaultBlockState(),new BlockPos(1,63,0),Blocks.STONE.defaultBlockState());
        var position=new Vec3(x,y,z);var body=new AABB(x-(double).6f/2,y,z-(double).6f/2,x+(double).6f/2,y+(double)1.8f,z+(double).6f/2);
        field(Entity.class,"position").set(normal,position);field(Entity.class,"bb").set(normal,body);
        var thin=new AABB(body.minX,body.minY-1e-6,body.minZ,body.maxX,body.minY,body.maxZ);
        normal.mainSupportingBlockPos=p.world.findSupportingBlock(normal,thin);
        var below=normal.getBlockPosBelowThatAffectsMyMovement();var c=new JsonObject();var entries=new JsonArray();
        for(var e:p.world.blocks.entrySet()){var entry=new JsonObject();entry.add("position",pos(e.getKey()));entry.addProperty("state",Block.getId(e.getValue()));entries.add(entry);}
        c.add("states",entries);c.add("position",vector(position));var bounds=new JsonArray();
        for(double n:new double[]{body.minX,body.minY,body.minZ,body.maxX,body.maxY,body.maxZ})bounds.add(n);
        c.add("box",bounds);c.add("support",normal.mainSupportingBlockPos.map(PlayerKineticsOracle::pos).orElse(null));
        c.add("below",pos(below));support.add(c);
      }
    var result=new JsonObject();result.add("jumps",jumps);result.add("air",air);result.add("normalization",normalization);result.add("support",support);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));System.out.println("PASS: "+jumps.size()+" native jumps, "+air.size()+" player travel branches, "+normalization.size()+" native player dead zones and "+support.size()+" supporting-block selections.");
  }
}
