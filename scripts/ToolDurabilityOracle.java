import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.Tool;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;

/** Actual stock Item.mineBlock -> ItemStack wear, with controlled random floats and break delivery. */
public class ToolDurabilityOracle {
  private static class ProbeServer extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private ProbeServer(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }
  private static class ProbeLevel extends ServerLevel {
    ProbeServer server; RandomSource random;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return random;}
  }
  private static class Probe extends Player {
    ProbeLevel world;ItemStack broken;int breaks;
    private Probe(){super(null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public void onEquippedItemBroken(ItemStack stack,EquipmentSlot slot){if(slot!=EquipmentSlot.MAINHAND)throw new AssertionError(slot);breaks++;broken=stack.copy();}
  }
  private static class InfiniteProbe extends ServerPlayer {
    boolean infinite;
    private InfiniteProbe(){super(null,null,null,null);}
    public boolean hasInfiniteMaterials(){return infinite;}
  }
  private static class Draws implements InvocationHandler {
    float[] values;int count;
    Draws(float[] values){this.values=values;}
    public Object invoke(Object proxy,Method method,Object[] args){
      if(!method.getName().equals("nextFloat"))throw new AssertionError("Unexpected RNG call "+method);
      if(count>=values.length)throw new AssertionError("Too many random draws");return values[count++];
    }
    RandomSource source(){return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},this);}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static JsonElement number(Integer value){return value==null?JsonNull.INSTANCE:new JsonPrimitive(value);}
  private static void observe(JsonArray cases,Probe player,ItemStack stack,JsonObject input,BlockState state,float[] values){
    var draws=new Draws(values);player.world.random=draws.source();player.breaks=0;player.broken=null;
    var row=input.deepCopy();row.addProperty("item",BuiltInRegistries.ITEM.getId(stack.getItem()));row.addProperty("state",Block.getId(state));
    var random=new JsonArray();for(float value:values)random.add((double)value);row.add("random",random);
    stack.getItem().mineBlock(stack,player.world,state,BlockPos.ZERO,player);
    row.addProperty("count",stack.getCount());row.add("damage",number(stack.get(DataComponents.DAMAGE)));
    row.addProperty("breaks",player.breaks);row.add("broken_damage",player.broken==null?JsonNull.INSTANCE:number(player.broken.get(DataComponents.DAMAGE)));row.addProperty("draws",draws.count);cases.add(row);
  }
  public static void main(String[] args)throws Exception{
    var lookup=MiningToolOracle.initialize();
    // Unbreaking tests item tags; the shared mining bootstrap already binds block tags.
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.ITEM.key(),(id,required)->BuiltInRegistries.ITEM.get(id));
      var memberships=new HashMap<Holder<Item>,List<TagKey<Item>>>();tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
      for(var item:BuiltInRegistries.ITEM)bind.invoke(item.builtInRegistryHolder(),memberships.getOrDefault(item.builtInRegistryHolder(),List.of()));
    }
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var server=(ProbeServer)unsafe.allocateInstance(ProbeServer.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);world.server=server;
    var player=(Probe)unsafe.allocateInstance(Probe.class);player.world=world;
    var enchantments=lookup.lookupOrThrow(Registries.ENCHANTMENT);var unbreaking=enchantments.getOrThrow(Enchantments.UNBREAKING);
    for(var entry:enchantments.listElements().toList())if(!entry.value().getEffects(EnchantmentEffectComponents.ITEM_DAMAGE).isEmpty()&&entry!=unbreaking)throw new AssertionError("Unexpected stock wear effect "+entry);
    var cases=new JsonArray();var states=List.of(Blocks.STONE.defaultBlockState(),Blocks.SHORT_GRASS.defaultBlockState(),Blocks.FIRE.defaultBlockState(),Blocks.SOUL_FIRE.defaultBlockState(),Blocks.BEDROCK.defaultBlockState());
    int declarations=0;
    for(var item:BuiltInRegistries.ITEM){
      var declaring=item.getClass().getMethod("mineBlock",ItemStack.class,Level.class,BlockState.class,BlockPos.class,LivingEntity.class).getDeclaringClass();
      if(declaring!=Item.class&&declaring!=ShearsItem.class)throw new AssertionError("Unhandled mining callback "+declaring);declarations++;
      if(item.builtInRegistryHolder().is(TagKey.create(Registries.ITEM,Identifier.parse("minecraft:enchantable/armor")))&&new ItemStack(item).has(DataComponents.TOOL))throw new AssertionError("Armor tool needs separate Unbreaking effect");
      for(var state:states)for(String removed:List.of("","minecraft:tool","minecraft:damage","minecraft:max_damage")){
        var stack=new ItemStack(item);var input=new JsonObject();if(!removed.isEmpty()){
          switch(removed){case "minecraft:tool"->stack.remove(DataComponents.TOOL);case "minecraft:damage"->stack.remove(DataComponents.DAMAGE);case "minecraft:max_damage"->stack.remove(DataComponents.MAX_DAMAGE);}
          input.addProperty("removed",removed);
        }observe(cases,player,stack,input,state,new float[]{0,.99999994f});
      }
    }
    for(var item:List.of(Items.IRON_PICKAXE,Items.DIAMOND_SWORD,Items.SHEARS))for(int level=0;level<=255;level++)for(boolean stored:new boolean[]{false,true})for(int pattern=0;pattern<4;pattern++){
      var stack=new ItemStack(item);var patch=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);patch.set(unbreaking,level);stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,patch.toImmutable());
      float chance=(float)level/(level+1);float adjacent=pattern==0?0:pattern==1?Math.max(0,Math.nextDown(chance)):pattern==2?chance:Math.min(.99999994f,Math.nextUp(chance));
      var input=new JsonObject();input.addProperty("level",level);input.addProperty("stored",stored);
      observe(cases,player,stack,input,Blocks.STONE.defaultBlockState(),new float[]{adjacent,.99999994f});
    }
    for(var item:List.of(Items.IRON_PICKAXE,Items.DIAMOND_SWORD,Items.SHEARS,Items.STONE))for(int maximum:new int[]{1,2,238,1561,Integer.MAX_VALUE})for(int damage:new int[]{0,1,maximum-1,maximum,Integer.MAX_VALUE})for(boolean unbreakable:new boolean[]{false,true})for(boolean addDamage:new boolean[]{false,true}){
      var stack=new ItemStack(item);stack.set(DataComponents.MAX_STACK_SIZE,1);stack.set(DataComponents.MAX_DAMAGE,maximum);if(addDamage)stack.set(DataComponents.DAMAGE,damage);if(unbreakable)stack.set(DataComponents.UNBREAKABLE,net.minecraft.util.Unit.INSTANCE);
      var input=new JsonObject();input.addProperty("maximum",maximum);if(addDamage)input.addProperty("initial_damage",damage);input.addProperty("unbreakable",unbreakable);
      observe(cases,player,stack,input,Blocks.STONE.defaultBlockState(),new float[]{0,.99999994f});
    }
    var infinite=(InfiniteProbe)unsafe.allocateInstance(InfiniteProbe.class);var process=ItemStack.class.getDeclaredMethod("processDurabilityChange",int.class,ServerLevel.class,ServerPlayer.class);process.setAccessible(true);int gates=0;
    for(boolean flag:new boolean[]{false,true})for(int cost:new int[]{0,1,2})for(var item:List.of(Items.IRON_PICKAXE,Items.SHEARS,Items.STONE)){
      infinite.infinite=flag;var stack=new ItemStack(item);int actual=(int)process.invoke(stack,cost,world,infinite);int expected=flag||!stack.isDamageableItem()?0:cost;if(actual!=expected)throw new AssertionError("Infinite-material gate");gates++;
    }
    var result=new JsonObject();result.add("cases",cases);result.addProperty("item_declarations",declarations);result.addProperty("infinite_gates",gates);Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" actual stock mining/wear callbacks, "+declarations+" item declarations and "+gates+" actual infinite-material gates. Criteria/stats and world destruction excluded.");
  }
}
