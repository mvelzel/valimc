import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.Container;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.level.block.state.properties.ChestType;
import net.minecraft.world.phys.Vec3;

/** Original single-chest state identities and actual block-entity validity boundaries. */
public class ChestAccessOracle {
  static class World extends ServerLevel {
    ChestBlockEntity chest; boolean present;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public BlockEntity getBlockEntity(BlockPos pos){return present?chest:null;}
  }
  static void set(Object object,Class<?> type,String field,Object value)throws Exception {
    var f=type.getDeclaredField(field);f.setAccessible(true);f.set(object,value);
  }
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();
    var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("protocol",777);
    facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    var states=new JsonArray();var single=new JsonArray();
    for(var state:Blocks.CHEST.getStateDefinition().getPossibleStates()) {
      var row=new JsonObject();int id=Block.getId(state);row.addProperty("state",id);
      row.addProperty("facing",state.getValue(ChestBlock.FACING).getName());
      row.addProperty("part",state.getValue(ChestBlock.TYPE).getSerializedName());
      row.addProperty("waterlogged",state.getValue(ChestBlock.WATERLOGGED));states.add(row);
      if(state.getValue(ChestBlock.TYPE)==ChestType.SINGLE)single.add(id);
    }
    facts.add("states",states);facts.add("single_states",single);
    var cases=new JsonArray();
    for(var mode:net.minecraft.world.level.GameType.values())for(boolean present:new boolean[]{false,true})
    for(var pos:List.of(BlockPos.ZERO,new BlockPos(29999984,64,-29999984))) {
      var world=(World)u.allocateInstance(World.class);world.present=present;
      world.chest=new ChestBlockEntity(pos,Blocks.CHEST.defaultBlockState());world.chest.setLevel(world);
      var p=(CraftingTableAccessOracle.P)u.allocateInstance(CraftingTableAccessOracle.P.class);
      p.range=mode==net.minecraft.world.level.GameType.CREATIVE?5.0:4.5;
      set(p,Entity.class,"eyeHeight",0.0f);double reach=p.range+4.0;
      for(double x:new double[]{.5,1+reach-1e-6,1+reach,1+reach+1e-6,-reach+1e-6,-reach,-reach-1e-6}) {
        var eye=new Vec3(pos.getX()+x,pos.getY()+.5,pos.getZ()+.5);set(p,Entity.class,"position",eye);
        var row=new JsonObject();row.addProperty("mode",mode.getName());row.addProperty("present",present);
        row.add("position",new Gson().toJsonTree(List.of(pos.getX(),pos.getY(),pos.getZ())));
        row.add("eye",new Gson().toJsonTree(List.of(eye.x,eye.y,eye.z)));
        row.addProperty("valid",Container.stillValidBlockEntity(world.chest,p));cases.add(row);
      }
    }
    var output=new JsonObject();output.add("facts",facts);output.add("validity",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(output));
    System.out.println("PASS: "+states.size()+" native ordinary chest states and "+cases.size()+" actual block-entity validity cases; opening obstruction/entities/menus excluded.");
  }
}
