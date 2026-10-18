import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.item.*;
import net.minecraft.world.level.block.entity.AbstractFurnaceBlockEntity;

/** Original native three-slot completion and fuel remainder observations, without tick/recipe simulation. */
public class CookingItemsOracle {
  static RegistryAccess access;
  static class World extends ServerLevel {
    List<ItemStack> drops; RandomSource random;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public RandomSource getRandom(){return random;}
    public int getNextEntityId(){return 1;}
    public boolean addFreshEntity(Entity entity){drops.add(((ItemEntity)entity).getItem().copy());return true;}
  }
  static String encode(ItemStack stack){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try {ItemStack.OPTIONAL_STREAM_CODEC.encode(buffer,stack);var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}
    finally {buffer.release();}
  }
  static JsonArray encode(List<ItemStack> stacks){var rows=new JsonArray();for(var stack:stacks)rows.add(encode(stack));return rows;}
  static ItemStack item(Item item,int count,boolean named){var stack=new ItemStack(item,count);if(named)stack.set(DataComponents.CUSTOM_NAME,Component.literal("Cooked"));return stack;}
  public static void main(String[] args)throws Exception {
    MiningToolOracle.initialize();access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    var canBurn=AbstractFurnaceBlockEntity.class.getDeclaredMethod("canBurn",NonNullList.class,int.class,ItemStack.class);canBurn.setAccessible(true);
    var burn=AbstractFurnaceBlockEntity.class.getDeclaredMethod("burn",NonNullList.class,ItemStack.class,ItemStack.class);burn.setAccessible(true);
    var consume=AbstractFurnaceBlockEntity.class.getDeclaredMethod("consumeFuel",ServerLevel.class,BlockPos.class,NonNullList.class,ItemStack.class);consume.setAccessible(true);
    var profiles=new ArrayList<ItemStack>();
    for(var type:List.of(Items.IRON_INGOT,Items.EGG,Items.DIAMOND_SWORD))for(boolean named:List.of(false,true))profiles.add(item(type,1,named));
    for(int max:new int[]{1,16,64,99}) {var stack=item(Items.IRON_INGOT,1,false);stack.set(DataComponents.MAX_STACK_SIZE,max);profiles.add(stack);}
    var removed=item(Items.IRON_INGOT,1,false);removed.remove(DataComponents.MAX_STACK_SIZE);profiles.add(removed);
    var completion=new JsonArray();
    var outputs=new ArrayList<ItemStack>();outputs.add(ItemStack.EMPTY);
    for(var profile:profiles)for(int count:new TreeSet<>(List.of(1,Math.max(1,profile.getMaxStackSize()-1),profile.getMaxStackSize())))outputs.add(profile.copyWithCount(count));
    for(var profile:profiles)for(int resultCount:new TreeSet<>(List.of(1,Math.min(4,profile.getMaxStackSize())))) {
      var result=profile.copyWithCount(resultCount);
      for(var output:outputs)for(int limit:new int[]{1,16,64,99})for(boolean wet:List.of(false,true))for(int inputCount:new int[]{1,2})for(int fuelProfile=0;fuelProfile<5;fuelProfile++) {
        var input=item(wet?Items.WET_SPONGE:Items.RAW_IRON,inputCount,true);
        var fuel=fuelProfile==0?ItemStack.EMPTY:item(fuelProfile==4?Items.COAL:Items.BUCKET,fuelProfile==3?16:1,fuelProfile==2);
        var slots=NonNullList.withSize(3,ItemStack.EMPTY);slots.set(0,input);slots.set(1,fuel);slots.set(2,output.copy());
        var row=new JsonObject();row.add("before",encode(slots));row.addProperty("result",encode(result));row.addProperty("limit",limit);
        boolean allowed=(Boolean)canBurn.invoke(null,slots,limit,result);row.addProperty("allowed",allowed);
        if(allowed)burn.invoke(null,slots,input,result);row.add("after",encode(slots));completion.add(row);
      }
    }
    var consumption=new JsonArray();var remainders=new JsonObject();
    for(var type:BuiltInRegistries.ITEM) {
      var template=type.getCraftingRemainder();
      if(template!=null)remainders.addProperty(Integer.toString(BuiltInRegistries.ITEM.getId(type)),BuiltInRegistries.ITEM.getId(template.create().getItem()));
      if(new ItemStack(type).get(DataComponents.COOKING_FUEL)==null)continue;
      for(boolean named:List.of(false,true))for(int count:new TreeSet<>(List.of(1,Math.min(2,type.getDefaultMaxStackSize()),type.getDefaultMaxStackSize()))){
        var world=(World)unsafe.allocateInstance(World.class);world.drops=new ArrayList<>();world.random=RandomSource.create(7);
        var slots=NonNullList.withSize(3,ItemStack.EMPTY);var stack=item(type,count,named);slots.set(1,stack);
        var row=new JsonObject();row.addProperty("before",encode(stack));consume.invoke(null,world,BlockPos.ZERO,slots,stack);row.addProperty("after",encode(slots.get(1)));row.add("drops",encode(world.drops));consumption.add(row);
      }
    }
    // Valid patched stacks exercise overflow when a remainder cannot replace the fuel slot.
    for(boolean named:List.of(false,true))for(int count:new int[]{1,2,99}) {
      var world=(World)unsafe.allocateInstance(World.class);world.drops=new ArrayList<>();world.random=RandomSource.create(7);
      var slots=NonNullList.withSize(3,ItemStack.EMPTY);var stack=item(Items.LAVA_BUCKET,count,named);stack.set(DataComponents.MAX_STACK_SIZE,99);slots.set(1,stack);
      var row=new JsonObject();row.addProperty("before",encode(stack));consume.invoke(null,world,BlockPos.ZERO,slots,stack);row.addProperty("after",encode(slots.get(1)));row.add("drops",encode(world.drops));consumption.add(row);
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("completion",completion);out.add("consumption",consumption);out.add("remainders",remainders);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+completion.size()+" actual canBurn/burn transitions, "+consumption.size()+" actual consumeFuel transitions; no live cooking/recipes/timers/journal claim.");
  }
}
