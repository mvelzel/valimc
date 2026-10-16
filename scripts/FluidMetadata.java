import com.google.gson.*;
import java.nio.file.*;
import java.io.ByteArrayOutputStream;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.material.*;
import net.minecraft.core.BlockPos;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.level.block.state.BlockState;

/** Emits scalar fluid observations, independently dense and compact; no implementation export. */
public class FluidMetadata {
  private static class Probe extends ServerLevel {
    FluidState fluid;BlockState replacement;int flags,calls;
    private Probe(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public FluidState getFluidState(BlockPos position){if(!position.equals(BlockPos.ZERO))throw new AssertionError(position);return fluid;}
    public boolean setBlock(BlockPos position,BlockState state,int flags){if(!position.equals(BlockPos.ZERO))throw new AssertionError(position);replacement=state;this.flags=flags;calls++;return true;}
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var gson=new Gson();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var probe=(Probe)((sun.misc.Unsafe)field.get(null)).allocateInstance(Probe.class);
    var properties=new JsonArray();var replacements=new JsonArray();var indexes=new LinkedHashMap<String,Integer>();
    var packed=new ByteArrayOutputStream();var cases=new JsonArray();int count=0;
    for(var state:Block.BLOCK_STATE_REGISTRY){
      if(Block.getId(state)!=count++)throw new AssertionError("Non-contiguous block states");
      var fluid=state.getFluidState();var type=fluid.getType();
      int kind=fluid.isEmpty()?0:(type==Fluids.WATER||type==Fluids.FLOWING_WATER)?1:(type==Fluids.LAVA||type==Fluids.FLOWING_LAVA)?2:-1;
      if(kind<0)throw new AssertionError("Unknown native fluid "+type);
      var facts=new JsonObject();facts.addProperty("kind",kind);
      facts.addProperty("amount",fluid.getAmount());facts.addProperty("height",(double)fluid.getOwnHeight());
      facts.addProperty("source",fluid.isSource());
      facts.addProperty("falling",fluid.hasProperty(FlowingFluid.FALLING)&&fluid.getValue(FlowingFluid.FALLING));
      int replacement=Block.getId(fluid.createLegacyBlock());
      for(boolean moving:new boolean[]{false,true}){
        probe.fluid=fluid;probe.calls=0;
        if(!probe.removeBlock(BlockPos.ZERO,moving)||probe.calls!=1||Block.getId(probe.replacement)!=replacement||probe.flags!=(moving?67:3))throw new AssertionError("Native base removal "+state);
      }
      var c=new JsonObject();c.addProperty("id",Block.getId(state));c.add("properties",facts);c.addProperty("replacement",replacement);cases.add(c);
      String key=gson.toJson(facts);Integer index=indexes.get(key);
      if(index==null){index=properties.size();indexes.put(key,index);properties.add(facts);replacements.add(replacement);}
      else if(replacements.get(index).getAsInt()!=replacement)throw new AssertionError("Fluid properties do not determine removal state");
      if(index>=256)throw new AssertionError("Fluid property byte overflow");packed.write(index);
    }
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);
    result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    result.addProperty("state_count",count);result.add("properties",properties);result.add("replacement_states",replacements);
    result.addProperty("states",HexFormat.of().formatHex(packed.toByteArray()));
    Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");
    Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+count+" native fluid facts and "+count*2+" actual base-removal callbacks / "+properties.size()+" property sets / "+packed.size()+" packed bytes.");
    for(var block:List.of(Blocks.AIR,Blocks.WATER,Blocks.LAVA,Blocks.OAK_SLAB))System.out.println(BuiltInRegistries.BLOCK.getKey(block)+" state="+Block.getId(block.defaultBlockState()));
  }
}
