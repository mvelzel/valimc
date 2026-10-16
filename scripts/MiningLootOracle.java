import com.google.gson.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.storage.loot.*;
import net.minecraft.world.level.storage.loot.parameters.*;
import net.minecraft.world.phys.Vec3;

/** Original deterministic-table classifier, verified through actual native block drops. */
public class MiningLootOracle {
  private static class Unsupported extends RuntimeException {}
  private static class ProbeServer extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;RandomSource random;
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
  private record Expansion(boolean matches,List<String> items) {}
  private static void keys(JsonObject object,String...allowed){
    if(!Set.of(allowed).containsAll(object.keySet()))throw new Unsupported();
  }
  private static boolean condition(JsonElement value,boolean silk){
    if(value==null)return true;
    if(value.isJsonPrimitive()&&value.getAsJsonPrimitive().isString()){
      if(value.getAsString().equals("minecraft:tool/can_silk_touch"))return silk;
      throw new Unsupported();
    }
    if(!value.isJsonObject())throw new Unsupported();
    var object=value.getAsJsonObject();keys(object,"type");
    if(object.get("type").getAsString().equals("minecraft:survives_explosion"))return true;
    throw new Unsupported();
  }
  private static Expansion expand(JsonObject entry,boolean silk){
    var type=entry.get("type").getAsString();
    if(type.equals("minecraft:item")){
      keys(entry,"type","name","condition");
      return condition(entry.get("condition"),silk)?new Expansion(true,List.of(entry.get("name").getAsString())):new Expansion(false,List.of());
    }
    if(type.equals("minecraft:empty")){
      keys(entry,"type","condition");return new Expansion(condition(entry.get("condition"),silk),List.of());
    }
    if(type.equals("minecraft:alternatives")){
      keys(entry,"type","children","condition");
      if(condition(entry.get("condition"),silk))for(var child:entry.getAsJsonArray("children")){
        var result=expand(child.getAsJsonObject(),silk);if(result.matches())return result;
      }
      return new Expansion(false,List.of());
    }
    throw new Unsupported();
  }
  private static List<String> evaluate(JsonObject table,boolean silk){
    keys(table,"type","pools","random_sequence");
    if(!table.get("type").getAsString().equals("minecraft:block"))throw new Unsupported();
    var items=new ArrayList<String>();
    if(table.has("pools"))for(var value:table.getAsJsonArray("pools")){
      var pool=value.getAsJsonObject();keys(pool,"rolls","entries","condition");
      if(!pool.get("rolls").isJsonPrimitive()||pool.get("rolls").getAsDouble()!=1||pool.getAsJsonArray("entries").size()!=1)throw new Unsupported();
      var result=expand(pool.getAsJsonArray("entries").get(0).getAsJsonObject(),silk);
      if(condition(pool.get("condition"),silk)&&result.matches())items.addAll(result.items());
    }
    if(items.size()>256)throw new Unsupported();return List.copyOf(items);
  }
  private static List<Integer> ids(List<String> names){
    return names.stream().map(name->BuiltInRegistries.ITEM.getId(BuiltInRegistries.ITEM.getValue(Identifier.parse(name)))).toList();
  }
  private static boolean baseDrops(Block block)throws NoSuchMethodException{
    for(Class<?> type=block.getClass();type!=null;type=type.getSuperclass()){
      try{return type.getDeclaredMethod("getDrops",net.minecraft.world.level.block.state.BlockState.class,LootParams.Builder.class).getDeclaringClass()==BlockBehaviour.class;}
      catch(NoSuchMethodException missing){}
    }
    throw new NoSuchMethodException("Missing block drop method");
  }
  private static ItemStack enchanted(HolderLookup.Provider lookup,Item item,boolean stored,Map<net.minecraft.resources.ResourceKey<Enchantment>,Integer> levels){
    var stack=new ItemStack(item);var patch=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);
    for(var entry:levels.entrySet())patch.set(lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(entry.getKey()),entry.getValue());
    stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,patch.toImmutable());return stack;
  }
  public static void main(String[] args)throws Exception{
    var base=MiningToolOracle.initialize();var gson=new Gson();var profiles=new JsonArray();profiles.add(JsonNull.INSTANCE);
    var indexes=new LinkedHashMap<String,Integer>();var blocks=new JsonArray();var cases=new JsonArray();int supported=0,states=0;
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var unsafe=(sun.misc.Unsafe)field.get(null);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var loadedKeys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!loadedKeys.contains(r.key())),loaded.listRegistries()));
      var server=(ProbeServer)unsafe.allocateInstance(ProbeServer.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
      var level=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);level.server=server;
      var tools=List.of(
        enchanted(lookup,Items.DIAMOND_PICKAXE,false,Map.of()),
        enchanted(lookup,Items.DIAMOND_PICKAXE,false,Map.of(Enchantments.SILK_TOUCH,1)),
        enchanted(lookup,Items.STONE,false,Map.of(Enchantments.SILK_TOUCH,255)),
        enchanted(lookup,Items.DIAMOND_PICKAXE,true,Map.of(Enchantments.SILK_TOUCH,1)),
        enchanted(lookup,Items.DIAMOND_PICKAXE,false,Map.of(Enchantments.FORTUNE,255)),
        ItemStack.EMPTY,
        enchanted(lookup,Items.DIAMOND_PICKAXE,false,Map.of(Enchantments.SILK_TOUCH,1,Enchantments.FORTUNE,255)));
      for(var block:BuiltInRegistries.BLOCK){
        if(BuiltInRegistries.BLOCK.getId(block)!=blocks.size())throw new AssertionError("Non-contiguous blocks");
        if(!baseDrops(block)){blocks.add(0);continue;}
        List<Integer> ordinary,silk;
        try{
          if(block.getLootTable().isEmpty()){ordinary=List.of();silk=List.of();}
          else{
            var key=block.getLootTable().get().identifier();var path="/data/"+key.getNamespace()+"/loot_table/"+key.getPath()+".json";
            try(var input=MiningLootOracle.class.getResourceAsStream(path)){
              if(input==null)throw new Unsupported();var table=JsonParser.parseReader(new InputStreamReader(input,java.nio.charset.StandardCharsets.UTF_8)).getAsJsonObject();
              ordinary=ids(evaluate(table,false));silk=ids(evaluate(table,true));
            }
          }
        }catch(Unsupported unsupported){blocks.add(0);continue;}
        supported++;
        for(var state:block.getStateDefinition().getPossibleStates())for(int variant=0;variant<tools.size();variant++){
          server.random=RandomSource.create(17L+Block.getId(state));var tool=tools.get(variant);
          var params=new LootParams.Builder(level).withParameter(LootContextParams.ORIGIN,Vec3.ZERO).withParameter(LootContextParams.BLOCK_STATE,state).withParameter(LootContextParams.TOOL,tool);
          var drops=state.getDrops(params);var actual=new ArrayList<Integer>();
          for(var stack:drops){if(stack.getCount()!=1||!stack.getComponentsPatch().isEmpty())throw new AssertionError("Unexpected deterministic stack "+state+" "+stack);actual.add(BuiltInRegistries.ITEM.getId(stack.getItem()));}
          var expected=variant==1||variant==2||variant==6?silk:ordinary;
          if(!actual.equals(expected))throw new AssertionError("Native loot differs "+state+" variant="+variant+" expected="+expected+" actual="+actual);
          var row=new JsonArray();row.add(Block.getId(state));row.add(variant);row.add(gson.toJsonTree(actual));cases.add(row);states++;
        }
        var profile=new JsonArray();profile.add(gson.toJsonTree(ordinary));profile.add(gson.toJsonTree(silk));var key=gson.toJson(profile);Integer index=indexes.get(key);
        if(index==null){index=profiles.size();indexes.put(key,index);profiles.add(profile);}blocks.add(index);
      }
    }
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    result.addProperty("state_count",Block.BLOCK_STATE_REGISTRY.size());result.addProperty("block_count",blocks.size());result.addProperty("supported_blocks",supported);result.add("profiles",profiles);result.add("block_profiles",blocks);
    Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+supported+" deterministic block families, "+states+" actual native state/tool drop contexts; random/context/function rules excluded.");
  }
}
