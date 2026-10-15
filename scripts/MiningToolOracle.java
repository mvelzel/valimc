import com.google.gson.*;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.Tool;
import net.minecraft.world.level.block.Block;
import net.minecraft.world.level.block.state.BlockState;

/** Original stock-tool facts and actual ItemStack speed/harvest/creative observations. */
public class MiningToolOracle {
  private static class Probe extends ServerPlayer {
    Abilities abilities;
    private Probe(){super(null,null,null,null);}
    public Abilities getAbilities(){return abilities;}
    public boolean canUseGameMasterBlocks(){return false;}
  }
  private static JsonElement tool(Tool value){
    if(value==null)return JsonNull.INSTANCE;
    var row=new JsonObject();row.addProperty("default_speed",(double)value.defaultMiningSpeed());
    row.addProperty("damage_per_block",value.damagePerBlock());row.addProperty("creative",value.canDestroyBlocksInCreative());
    var rules=new JsonArray();
    for(var rule:value.rules()){
      var r=new JsonObject();var blocks=new JsonArray();
      for(var block:BuiltInRegistries.BLOCK)if(rule.blocks().contains(block.builtInRegistryHolder()))blocks.add(BuiltInRegistries.BLOCK.getId(block));
      r.add("blocks",blocks);rule.speed().ifPresent(speed->r.addProperty("speed",(double)speed));rule.correctForDrops().ifPresent(correct->r.addProperty("correct",correct));rules.add(r);
    }
    row.add("rules",rules);return row;
  }
  private static void uint16(ByteArrayOutputStream bytes,int value){if(value<0||value>65535)throw new AssertionError("Registry exceeds uint16");bytes.write(value>>>8);bytes.write(value);}
  private static String hex(ByteArrayOutputStream bytes){return HexFormat.of().formatHex(bytes.toByteArray());}
  static HolderLookup.Provider initialize()throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.BLOCK.key(),(id,required)->BuiltInRegistries.BLOCK.get(id));
      var memberships=new HashMap<Holder<Block>,List<TagKey<Block>>>();
      tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
      for(var block:BuiltInRegistries.BLOCK)bind.invoke(block.builtInRegistryHolder(),memberships.getOrDefault(block.builtInRegistryHolder(),List.of()));
    }
    return lookup;
  }
  public static void main(String[] args)throws Exception{
    initialize();
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");unsafeField.setAccessible(true);
    var player=(Probe)((sun.misc.Unsafe)unsafeField.get(null)).allocateInstance(Probe.class);player.abilities=new Abilities();
    var profiles=new JsonArray();var indexes=new LinkedHashMap<String,Integer>();var representatives=new ArrayList<ItemStack>();var items=new ByteArrayOutputStream();
    int removed=0;var blocked=new JsonArray();var permissions=new JsonArray();
    for(var item:BuiltInRegistries.ITEM){
      if(BuiltInRegistries.ITEM.getId(item)!=items.size()/2)throw new AssertionError("Noncontiguous item registry");
      for(var method:Item.class.getMethods())if(Set.of("getDestroySpeed","isCorrectToolForDrops","canDestroyBlock").contains(method.getName())){
        var owner=item.getClass().getMethod(method.getName(),method.getParameterTypes()).getDeclaringClass();
        if(owner!=Item.class&&!(item==Items.DEBUG_STICK&&method.getName().equals("canDestroyBlock")&&owner==DebugStickItem.class))throw new AssertionError("Specialized item needs explicit observations: "+item+" "+method.getName());
      }
      var stack=new ItemStack(item);var facts=tool(stack.get(DataComponents.TOOL));var key=facts.toString();Integer index=indexes.get(key);
      if(index==null){index=profiles.size();indexes.put(key,index);profiles.add(facts);representatives.add(stack.copy());}
      uint16(items,index);
      boolean denied=item==Items.DEBUG_STICK;if(denied)blocked.add(BuiltInRegistries.ITEM.getId(item));
      var permission=new JsonObject();permission.addProperty("item",BuiltInRegistries.ITEM.getId(item));var stock=new JsonArray();
      for(boolean creative:new boolean[]{false,true}){player.abilities.instabuild=creative;stock.add(stack.canDestroyBlock(net.minecraft.world.level.block.Blocks.STONE.defaultBlockState(),null,BlockPos.ZERO,player));}permission.add("stock",stock);permissions.add(permission);
      stack.remove(DataComponents.TOOL);
      for(var state:List.of(net.minecraft.world.level.block.Blocks.STONE.defaultBlockState(),net.minecraft.world.level.block.Blocks.COBWEB.defaultBlockState())){
        if(stack.getDestroySpeed(state)!=1||stack.isCorrectToolForDrops(state))throw new AssertionError("Unexpected absent-tool behavior: "+item);
        for(boolean creative:new boolean[]{false,true}){player.abilities.instabuild=creative;if(stack.canDestroyBlock(state,null,BlockPos.ZERO,player)==denied)throw new AssertionError("Unexpected absent-tool destruction: "+item);}
        removed++;
      }
    }
    var states=new ByteArrayOutputStream();for(var state:Block.BLOCK_STATE_REGISTRY){if(Block.getId(state)!=states.size()/2)throw new AssertionError("Noncontiguous block states");uint16(states,BuiltInRegistries.BLOCK.getId(state.getBlock()));}
    var cases=new JsonArray();int count=0;
    for(int index=0;index<representatives.size();index++){
      var stack=representatives.get(index);var speeds=new ByteArrayOutputStream();var correct=new ByteArrayOutputStream();
      for(var state:Block.BLOCK_STATE_REGISTRY){int bits=Float.floatToIntBits(stack.getDestroySpeed(state));speeds.write(bits>>>24);speeds.write(bits>>>16);speeds.write(bits>>>8);speeds.write(bits);correct.write(stack.isCorrectToolForDrops(state)?1:0);count++;}
      var row=new JsonObject();row.addProperty("profile",index);row.addProperty("item",BuiltInRegistries.ITEM.getId(stack.getItem()));row.addProperty("speed_bits",hex(speeds));row.addProperty("correct",hex(correct));
      var creative=new JsonArray();for(boolean infinite:new boolean[]{false,true}){player.abilities.instabuild=infinite;creative.add(stack.canDestroyBlock(net.minecraft.world.level.block.Blocks.STONE.defaultBlockState(),null,BlockPos.ZERO,player));}row.add("can_destroy",creative);cases.add(row);
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    facts.addProperty("state_count",states.size()/2);facts.addProperty("block_count",BuiltInRegistries.BLOCK.size());facts.addProperty("item_count",items.size()/2);facts.addProperty("states",hex(states));facts.addProperty("items",hex(items));facts.add("profiles",profiles);facts.add("blocked_items",blocked);
    var observed=new JsonObject();observed.add("profiles",cases);observed.add("permissions",permissions);
    Files.writeString(Path.of(args[0]),new Gson().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(observed));
    System.out.println("PASS: "+items.size()/2+" native item method declarations, "+profiles.size()+" stock profiles, "+count+" actual state speed/harvest pairs and "+removed+" absent-tool controls; attributes/effects/loot excluded.");
  }
}
