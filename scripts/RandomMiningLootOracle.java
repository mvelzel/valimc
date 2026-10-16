import com.google.gson.*;
import java.io.*;
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
import net.minecraft.server.packs.resources.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.level.storage.loot.*;
import net.minecraft.world.level.storage.loot.parameters.*;
import net.minecraft.world.phys.Vec3;

/** Original bounded stock-cube classifier and controlled actual native drop observations. */
public class RandomMiningLootOracle {
  private static class ProbeServer extends DedicatedServer {
    ReloadableServerRegistries.Holder registries; RandomSource random;
    private ProbeServer(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
    public RandomSource getRandomSequence(Identifier id){return random;}
  }
  private static class ProbeLevel extends ServerLevel {
    ProbeServer server;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return server.random;}
    public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
  }
  private static class Draws implements InvocationHandler {
    int[] values; int cursor; float chance; JsonArray trace=new JsonArray();
    Draws(int base,int bonus,float chance){values=new int[]{base,bonus};this.chance=chance;}
    public Object invoke(Object proxy,Method method,Object[] args){
      if(method.getName().equals("nextInt")&&args.length==1){
        int bound=(int)args[0];
        // Bound-one draws make no probabilistic decision; omit these from both traces.
        if(bound==1)return 0;
        if(cursor>=values.length)throw new AssertionError("Unexpected integer draw "+bound);
        int value=values[cursor++];
        if(value<0||value>=bound)throw new AssertionError("Invalid controlled draw "+value+"/"+bound);
        var row=new JsonArray();row.add("int");row.add(bound);row.add(value);trace.add(row);return value;
      }
      if(method.getName().equals("nextFloat")){
        var row=new JsonArray();row.add("float");row.add((double)chance);trace.add(row);return chance;
      }
      throw new AssertionError("Unexpected RNG call "+method);
    }
    RandomSource source(){return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},this);}
  }
  private static void keys(JsonObject value,String...names){
    if(!new HashSet<>(Arrays.asList(names)).equals(value.keySet()))throw new AssertionError("Changed stock loot structure "+value);
  }
  private static void type(JsonObject value,String type){if(!value.get("type").getAsString().equals("minecraft:"+type))throw new AssertionError(value);}
  private static int item(String name){return BuiltInRegistries.ITEM.getId(BuiltInRegistries.ITEM.getValue(Identifier.parse(name)));}
  private static JsonObject profile(Block block)throws Exception{
    if(!MiningLootOracle.ordinaryCube(block)||!MiningLootOracle.baseDrops(block))throw new AssertionError("Not ordinary base loot "+block);
    MiningLootOracle.simpleCallbacks(block);
    var key=block.getLootTable().orElseThrow().identifier();
    JsonObject table;
    try(var input=RandomMiningLootOracle.class.getResourceAsStream("/data/"+key.getNamespace()+"/loot_table/"+key.getPath()+".json")){
      table=JsonParser.parseReader(new InputStreamReader(input,java.nio.charset.StandardCharsets.UTF_8)).getAsJsonObject();
    }
    keys(table,"type","pools","random_sequence");type(table,"block");
    if(table.getAsJsonArray("pools").size()!=1)throw new AssertionError(table);
    var pool=table.getAsJsonArray("pools").get(0).getAsJsonObject();keys(pool,"entries","rolls");
    if(pool.get("rolls").getAsInt()!=1||pool.getAsJsonArray("entries").size()!=1)throw new AssertionError(pool);
    var alternatives=pool.getAsJsonArray("entries").get(0).getAsJsonObject();keys(alternatives,"type","children");type(alternatives,"alternatives");
    if(alternatives.getAsJsonArray("children").size()!=2)throw new AssertionError(alternatives);
    var silk=alternatives.getAsJsonArray("children").get(0).getAsJsonObject();keys(silk,"type","condition","name");type(silk,"item");
    if(!silk.get("condition").getAsString().equals("minecraft:tool/can_silk_touch")||item(silk.get("name").getAsString())!=BuiltInRegistries.ITEM.getId(block.asItem()))throw new AssertionError(silk);
    var normal=alternatives.getAsJsonArray("children").get(1).getAsJsonObject();
    var result=new JsonObject();result.addProperty("state",Block.getId(block.defaultBlockState()));result.addProperty("silk",BuiltInRegistries.ITEM.getId(block.asItem()));
    JsonObject count;
    if(block==Blocks.GILDED_BLACKSTONE){
      keys(normal,"type","children","condition");type(normal,"alternatives");
      var condition=normal.getAsJsonObject("condition");keys(condition,"type");type(condition,"survives_explosion");
      if(normal.getAsJsonArray("children").size()!=2)throw new AssertionError(normal);
      var nuggets=normal.getAsJsonArray("children").get(0).getAsJsonObject();keys(nuggets,"type","condition","modifier","name");type(nuggets,"item");
      var fallback=normal.getAsJsonArray("children").get(1).getAsJsonObject();keys(fallback,"type","name");type(fallback,"item");
      if(item(fallback.get("name").getAsString())!=BuiltInRegistries.ITEM.getId(block.asItem()))throw new AssertionError(fallback);
      condition=nuggets.getAsJsonObject("condition");keys(condition,"type","chances","enchantment");type(condition,"table_bonus");
      if(!condition.get("enchantment").getAsString().equals("minecraft:fortune"))throw new AssertionError(condition);
      var chances=new JsonArray();for(var chance:condition.getAsJsonArray("chances"))chances.add((double)chance.getAsFloat());
      result.add("chances",chances);result.addProperty("item",item(nuggets.get("name").getAsString()));count=nuggets.getAsJsonObject("modifier");
    }else{
      keys(normal,"type","modifier","name");type(normal,"item");
      var modifiers=normal.getAsJsonArray("modifier");if(modifiers.size()!=4)throw new AssertionError(modifiers);
      count=modifiers.get(0).getAsJsonObject();var bonus=modifiers.get(1).getAsJsonObject();
      keys(bonus,"type","enchantment","formula","parameters");type(bonus,"apply_bonus");
      if(!bonus.get("enchantment").getAsString().equals("minecraft:fortune")||!bonus.get("formula").getAsString().equals("minecraft:uniform_bonus_count"))throw new AssertionError(bonus);
      keys(bonus.getAsJsonObject("parameters"),"bonusMultiplier");if(bonus.getAsJsonObject("parameters").get("bonusMultiplier").getAsInt()!=1)throw new AssertionError(bonus);
      var limit=modifiers.get(2).getAsJsonObject();keys(limit,"type","limit");type(limit,"limit_count");
      var bounds=limit.getAsJsonObject("limit");if(block==Blocks.MELON)keys(bounds,"max");else{keys(bounds,"max","min");if(bounds.get("min").getAsInt()!=1)throw new AssertionError(bounds);}
      result.addProperty("cap",bounds.get("max").getAsInt());
      var explosion=modifiers.get(3).getAsJsonObject();keys(explosion,"type");type(explosion,"explosion_decay");
      result.addProperty("item",item(normal.get("name").getAsString()));
    }
    keys(count,"type","count");type(count,"set_count");var range=count.getAsJsonObject("count");keys(range,"type","min","max");type(range,"uniform");
    result.addProperty("min",range.get("min").getAsInt());result.addProperty("max",range.get("max").getAsInt());return result;
  }
  private static ItemStack tool(HolderLookup.Provider lookup,int variant,int level){
    if(variant==4)return ItemStack.EMPTY;
    var stack=new ItemStack(variant==3||variant==5?Items.STONE:Items.DIAMOND_PICKAXE);
    var patch=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);var enchantments=lookup.lookupOrThrow(Registries.ENCHANTMENT);
    patch.set(enchantments.getOrThrow(Enchantments.FORTUNE),level);
    if(variant==2||variant==5||variant==6)patch.set(enchantments.getOrThrow(Enchantments.SILK_TOUCH),1);
    stack.set(variant==1||variant==6?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,patch.toImmutable());return stack;
  }
  private static void observe(JsonArray cases,ProbeLevel world,BlockState state,ItemStack tool,int variant,int level,int base,int bonus,float chance){
    var draws=new Draws(base,bonus,chance);world.server.random=draws.source();
    var params=new LootParams.Builder(world).withParameter(LootContextParams.ORIGIN,Vec3.ZERO).withParameter(LootContextParams.BLOCK_STATE,state).withParameter(LootContextParams.TOOL,tool);
    var items=new JsonArray();for(var stack:state.getDrops(params)){
      if(!stack.getComponentsPatch().isEmpty()||stack.getCount()<1||stack.getCount()>stack.getMaxStackSize())throw new AssertionError(stack);
      var item=new JsonArray();item.add(BuiltInRegistries.ITEM.getId(stack.getItem()));item.add(stack.getCount());items.add(item);
    }
    var row=new JsonArray();row.add(Block.getId(state));row.add(variant);row.add(level);row.add(draws.trace);row.add(items);cases.add(row);
  }
  public static void main(String[] args)throws Exception{
    var base=MiningToolOracle.initialize();var gson=new Gson();var cases=new JsonArray();var profiles=new JsonArray();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var loadedKeys=loaded.listRegistryKeys().collect(java.util.stream.Collectors.toSet());
      var lookup=HolderLookup.Provider.create(java.util.stream.Stream.concat(base.listRegistries().filter(r->!loadedKeys.contains(r.key())),loaded.listRegistries()));
      var server=(ProbeServer)unsafe.allocateInstance(ProbeServer.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
      var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);world.server=server;
      for(var block:List.of(Blocks.MELON,Blocks.GLOWSTONE,Blocks.SEA_LANTERN,Blocks.GILDED_BLACKSTONE)){
        var profile=profile(block);profiles.add(profile);int range=profile.get("max").getAsInt()-profile.get("min").getAsInt()+1;
        for(int level=0;level<=255;level++)for(int variant=0;variant<7;variant++){
          var tool=tool(lookup,variant,level);
          if(block==Blocks.GILDED_BLACKSTONE){
            var chances=profile.getAsJsonArray("chances");float chance=chances.get(Math.min(level,chances.size()-1)).getAsFloat();
            for(float value:new float[]{0,Math.max(0,Math.nextDown(chance)),Math.min(.99999994f,chance),Math.min(.99999994f,Math.nextUp(chance)),.99999994f})
              for(int first=0;first<range;first++)observe(cases,world,block.defaultBlockState(),tool,variant,level,first,0,value);
          }else{
            for(int first=0;first<range;first++)for(int bonus=0;bonus<=(variant==0?level:0);bonus++)
              observe(cases,world,block.defaultBlockState(),tool,variant,level,first,bonus,.5f);
          }
        }
      }
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");facts.add("blocks",profiles);
    Files.writeString(Path.of(args[0]),gson.toJson(facts)+"\n");Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+cases.size()+" actual native random-loot contexts, four base-callback cubes, Fortune0..255 and Silk/stored/empty/custom-tool controls.");
  }
}
