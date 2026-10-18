import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.animal.feline.Cat;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.block.state.properties.ChestType;
import net.minecraft.world.phys.AABB;

/** Original menu-provider/obstruction observations; game-mode dispatch/menu mutation excluded. */
public class ChestOpeningOracle {
  static class ProbeCat extends Cat {
    boolean sitting;
    private ProbeCat(){super(null,null);}
    public boolean isInSittingPose(){return sitting;}
  }
  static class World extends ServerLevel {
    BlockState state,cover,filler;BlockPos root;ChestBlockEntity chest;boolean present;ProbeCat cat;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockState getBlockState(BlockPos pos){return pos.equals(root)?state:pos.equals(root.above())?cover:filler;}
    public BlockEntity getBlockEntity(BlockPos pos){return present&&pos.equals(root)?chest:null;}
    @SuppressWarnings("unchecked") public <T extends Entity> List<T> getEntitiesOfClass(Class<T> type,AABB box){return cat==null?List.of():List.of((T)cat);}
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
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.addProperty("cover_contexts",checked);out.add("covers",covers);out.add("contexts",contexts);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+covers.size()+" native above-block states/"+checked+" position-neighbor contexts and "+contexts.size()+" single-chest entity/cat contexts; dispatch/locks/loot/menu mutation excluded.");
  }
}
