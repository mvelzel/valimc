import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.ItemStack;

/** Original actual ItemStack.consume observations for admitted placement items. */
public class PlacementConsumptionOracle {
  static class Probe extends ServerPlayer {
    private Probe(){super(null,null,null,null);}
  }
  public static void main(String[] args)throws Exception{
    MiningToolOracle.initialize();var uf=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");uf.setAccessible(true);
    var player=(Probe)((sun.misc.Unsafe)uf.get(null)).allocateInstance(Probe.class);var abilities=new Abilities();
    var nativeAbilities=Player.class.getDeclaredField("abilities");nativeAbilities.setAccessible(true);nativeAbilities.set(player,abilities);
    var facts=JsonParser.parseString(Files.readString(Path.of(args[0]))).getAsJsonObject();var items=new TreeSet<Integer>();
    for(var key:facts.getAsJsonObject("plain").keySet())items.add(Integer.parseInt(key));
    for(var slab:facts.getAsJsonArray("slabs"))items.add(slab.getAsJsonObject().get("item").getAsInt());
    if(items.size()!=106)throw new AssertionError("Changed placement admission");
    var rows=new JsonArray();
    for(int item:items)for(int count:new int[]{1,2,17,64,99})for(boolean infinite:new boolean[]{false,true}){
      abilities.instabuild=infinite;var stack=new ItemStack(BuiltInRegistries.ITEM.byId(item),count);
      stack.set(DataComponents.MAX_STACK_SIZE,99);stack.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);var before=stack.copy();
      stack.consume(1,player);
      if(!stack.isEmpty()&&!ItemStack.isSameItemSameComponents(before,stack))throw new AssertionError("Consumption changed item components");
      var row=new JsonObject();row.addProperty("item",item);row.addProperty("before",count);row.addProperty("infinite",infinite);row.addProperty("after",stack.getCount());row.addProperty("empty",stack.isEmpty());rows.add(row);
    }
    Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" actual native placement-item consume calls across 106 admitted items; exact nonempty components retained.");
  }
}
