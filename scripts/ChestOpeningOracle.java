import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.MenuProvider;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.inventory.PlayerEnderChestContainer;
import net.minecraft.world.level.Level;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import net.minecraft.world.entity.animal.feline.Cat;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.ChestType;
import net.minecraft.world.phys.AABB;

/** Original menu-provider/obstruction observations, the ender chest's use included; game-mode dispatch/menu mutation excluded. */
public class ChestOpeningOracle {
  static class ProbeCat extends Cat {
    boolean sitting;
    private ProbeCat(){super(null,null);}
    public boolean isInSittingPose(){return sitting;}
  }
  static class World extends ServerLevel {
    BlockState state,cover,filler;BlockPos root;ChestBlockEntity chest;EnderChestBlockEntity ender;boolean present;ProbeCat cat;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){return pos.equals(root)?state:pos.equals(root.above())?cover:filler;}
    public BlockEntity getBlockEntity(BlockPos pos){return present&&pos.equals(root)?(ender!=null?ender:chest):null;}
    @SuppressWarnings("unchecked") public <T extends Entity> List<T> getEntitiesOfClass(Class<T> type,AABB box){return cat==null||type!=Cat.class?List.of():List.of((T)cat);}
  }
  /** A player using an ender chest (VMC-032c3): counts the menus it opens, nothing else. */
  static class Opener extends ServerPlayer {
    int opened;World world;PlayerEnderChestContainer enderItems;
    private Opener(){super(null,null,null,null);}
    public OptionalInt openMenu(MenuProvider provider){opened++;return OptionalInt.empty();}
    public PlayerEnderChestContainer getEnderChestInventory(){return enderItems;}
    public void awardStat(net.minecraft.stats.Stat<?> stat,int count){}
    public ServerLevel level(){return world;}
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var world=(World)u.allocateInstance(World.class);world.present=true;world.root=BlockPos.ZERO;world.filler=Blocks.AIR.defaultBlockState();
    world.state=Blocks.CHEST.defaultBlockState();world.chest=new ChestBlockEntity(BlockPos.ZERO,world.state);world.chest.setLevel(world);
    var method=ChestBlock.class.getDeclaredMethod("getMenuProvider",BlockState.class,net.minecraft.world.level.Level.class,BlockPos.class);method.setAccessible(true);
    var covers=new JsonArray();
    for(var cover:Block.BLOCK_STATE_REGISTRY) {
      world.cover=cover;world.cat=null;
      boolean conductor=cover.isRedstoneConductor(world,BlockPos.ZERO.above());
      boolean blocked=ChestBlock.isChestBlockedAt(world,BlockPos.ZERO);
      boolean provider=method.invoke(Blocks.CHEST,world.state,world,BlockPos.ZERO)!=null;
      if(blocked!=conductor||provider==blocked)throw new AssertionError("Unexpected native cover/provider relation");
      var row=new JsonArray();row.add(Block.getId(cover));row.add(blocked);row.add(provider);covers.add(row);
    }
    int checked=covers.size();
    for(var root:List.of(BlockPos.ZERO,new BlockPos(29999984,64,-29999984),new BlockPos(-1,318,15)))
    for(var filler:List.of(Blocks.AIR.defaultBlockState(),Blocks.STONE.defaultBlockState())) {
      if(root.equals(BlockPos.ZERO)&&filler.is(Blocks.AIR))continue;
      world.root=root;world.filler=filler;world.chest=new ChestBlockEntity(root,world.state);world.chest.setLevel(world);
      for(var cover:Block.BLOCK_STATE_REGISTRY) {
        world.cover=cover;var expected=covers.get(Block.getId(cover)).getAsJsonArray();
        if(ChestBlock.isChestBlockedAt(world,root)!=expected.get(1).getAsBoolean()||
           (method.invoke(Blocks.CHEST,world.state,world,root)!=null)!=expected.get(2).getAsBoolean())
          throw new AssertionError("Context-dependent cover needs a contextual implementation: "+cover);
        checked++;
      }
    }
    world.root=BlockPos.ZERO;world.filler=Blocks.AIR.defaultBlockState();
    var contexts=new JsonArray();world.cover=Blocks.AIR.defaultBlockState();
    for(var state:Blocks.CHEST.getStateDefinition().getPossibleStates())if(state.getValue(ChestBlock.TYPE)==ChestType.SINGLE)
    for(boolean present:new boolean[]{false,true})for(int cat:new int[]{0,1,2}) {
      world.state=state;world.present=present;world.chest=new ChestBlockEntity(BlockPos.ZERO,state);world.chest.setLevel(world);
      world.cat=cat==0?null:(ProbeCat)u.allocateInstance(ProbeCat.class);if(world.cat!=null)world.cat.sitting=cat==2;
      var row=new JsonArray();row.add(Block.getId(state));row.add(present);row.add(cat);
      row.add(ChestBlock.isChestBlockedAt(world,BlockPos.ZERO));row.add(method.invoke(Blocks.CHEST,state,world,BlockPos.ZERO)!=null);contexts.add(row);
    }
    // `EnderChestBlock.useWithoutItem` opens the player's menu unless a redstone conductor sits on
    // it, exactly the chest's cover bits; a sitting cat does not keep it shut.
    var opener=(Opener)u.allocateInstance(Opener.class);opener.world=world;opener.enderItems=new PlayerEnderChestContainer();
    var bb=Entity.class.getDeclaredField("bb");bb.setAccessible(true);bb.set(opener,new AABB(0,1,2,1,2,3));
    var use=EnderChestBlock.class.getDeclaredMethod("useWithoutItem",BlockState.class,Level.class,BlockPos.class,Player.class,BlockHitResult.class);use.setAccessible(true);
    var hit=new BlockHitResult(Vec3.atCenterOf(BlockPos.ZERO),Direction.UP,BlockPos.ZERO,false);
    var enderState=Blocks.ENDER_CHEST.defaultBlockState();
    world.present=true;world.ender=new EnderChestBlockEntity(BlockPos.ZERO,enderState);world.ender.setLevel(world);
    var enderCovers=new JsonArray();
    for(var cover:Block.BLOCK_STATE_REGISTRY) {
      world.cover=cover;world.cat=null;opener.opened=0;
      use.invoke(Blocks.ENDER_CHEST,enderState,world,BlockPos.ZERO,opener,hit);
      var expected=covers.get(Block.getId(cover)).getAsJsonArray();
      if((opener.opened==1)!=expected.get(2).getAsBoolean())throw new AssertionError("Ender chest cover differs from the chest's: "+cover);
      enderCovers.add(opener.opened==1);
    }
    world.cover=Blocks.AIR.defaultBlockState();world.cat=(ProbeCat)u.allocateInstance(ProbeCat.class);world.cat.sitting=true;opener.opened=0;
    use.invoke(Blocks.ENDER_CHEST,enderState,world,BlockPos.ZERO,opener,hit);
    boolean enderCat=opener.opened==1;
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("cover_contexts",checked);out.add("covers",covers);out.add("contexts",contexts);out.add("ender_covers",enderCovers);out.addProperty("ender_sitting_cat_opens",enderCat);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+covers.size()+" native above-block states/"+checked+" position-neighbor contexts and "+contexts.size()+" single-chest entity/cat contexts, "+enderCovers.size()+" ender chest covers; dispatch/locks/loot/menu mutation excluded.");
  }
}
