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
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.tags.BlockTags;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.level.block.state.BlockState;
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
  private record Drop(String name,int count) {}
  private record Expansion(boolean matches,List<Drop> items) {}
  private record Profile(List<List<Integer>> ordinary,List<List<Integer>> silk) {}
  private static void keys(JsonObject object,String...allowed){
    if(!Set.of(allowed).containsAll(object.keySet()))throw new Unsupported();
  }
  private static boolean condition(JsonElement value,boolean silk,BlockState state){
    if(value==null)return true;
    if(value.isJsonPrimitive()&&value.getAsJsonPrimitive().isString()){
      if(value.getAsString().equals("minecraft:tool/can_silk_touch"))return silk;
      throw new Unsupported();
    }
    if(!value.isJsonObject())throw new Unsupported();
    var object=value.getAsJsonObject();var type=object.get("type").getAsString();
    if(type.equals("minecraft:survives_explosion")){keys(object,"type");return true;}
    if(type.equals("minecraft:match_block")){
      keys(object,"type","blocks","state");var blocks=object.get("blocks");
      if(!blocks.isJsonPrimitive()||!blocks.getAsJsonPrimitive().isString()||blocks.getAsString().startsWith("#"))throw new Unsupported();
      if(!BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString().equals(blocks.getAsString()))return false;
      if(object.has("state"))for(var entry:object.getAsJsonObject("state").entrySet()){
        if(!entry.getValue().isJsonPrimitive())throw new Unsupported();
        var property=state.getBlock().getStateDefinition().getProperty(entry.getKey());
        if(property==null||!propertyValue(state,property).equals(entry.getValue().getAsString()))return false;
      }
      return true;
    }
    throw new Unsupported();
  }
  private static <T extends Comparable<T>> String propertyValue(BlockState state,net.minecraft.world.level.block.state.properties.Property<T> property){return property.getName(state.getValue(property));}
  private static int modifier(JsonElement value,int count,boolean silk,BlockState state){
    if(value==null)return count;
    if(value.isJsonArray()){for(var next:value.getAsJsonArray())count=modifier(next,count,silk,state);return count;}
    var object=value.getAsJsonObject();var type=object.get("type").getAsString();
    if(type.equals("minecraft:explosion_decay")){keys(object,"type","condition");condition(object.get("condition"),silk,state);return count;}
    if(type.equals("minecraft:set_count")){
      keys(object,"type","count","condition");var number=object.get("count");
      if(!number.isJsonPrimitive()||!number.getAsJsonPrimitive().isNumber()||number.getAsDouble()!=number.getAsInt()||number.getAsInt()<0||number.getAsInt()>64)throw new Unsupported();
      return condition(object.get("condition"),silk,state)?number.getAsInt():count;
    }
    throw new Unsupported();
  }
  private static Expansion expand(JsonObject entry,boolean silk,BlockState state){
    var type=entry.get("type").getAsString();
    if(type.equals("minecraft:item")){
      keys(entry,"type","name","condition","modifier");
      int count=modifier(entry.get("modifier"),1,silk,state);var name=entry.get("name").getAsString();
      var item=BuiltInRegistries.ITEM.getValue(Identifier.parse(name));
      if(count>item.getDefaultInstance().getMaxStackSize())throw new Unsupported();
      return condition(entry.get("condition"),silk,state)?new Expansion(true,count==0?List.of():List.of(new Drop(name,count))):new Expansion(false,List.of());
    }
    if(type.equals("minecraft:empty")){
      keys(entry,"type","condition");return new Expansion(condition(entry.get("condition"),silk,state),List.of());
    }
    if(type.equals("minecraft:alternatives")){
      keys(entry,"type","children","condition");
      if(condition(entry.get("condition"),silk,state))for(var child:entry.getAsJsonArray("children")){
        var result=expand(child.getAsJsonObject(),silk,state);if(result.matches())return result;
      }
      return new Expansion(false,List.of());
    }
    throw new Unsupported();
  }
  private static List<List<Integer>> evaluate(JsonObject table,boolean silk,BlockState state){
    keys(table,"type","pools","random_sequence");
    if(!table.get("type").getAsString().equals("minecraft:block"))throw new Unsupported();
    var items=new ArrayList<Drop>();
    if(table.has("pools"))for(var value:table.getAsJsonArray("pools")){
      var pool=value.getAsJsonObject();keys(pool,"rolls","entries","condition");
      if(!pool.get("rolls").isJsonPrimitive()||pool.get("rolls").getAsDouble()!=1||pool.getAsJsonArray("entries").size()!=1)throw new Unsupported();
      var result=expand(pool.getAsJsonArray("entries").get(0).getAsJsonObject(),silk,state);
      if(condition(pool.get("condition"),silk,state)&&result.matches())items.addAll(result.items());
    }
    if(items.size()>256)throw new Unsupported();
    return items.stream().map(drop->List.of(BuiltInRegistries.ITEM.getId(BuiltInRegistries.ITEM.getValue(Identifier.parse(drop.name()))),drop.count())).toList();
  }
  private static int index(Profile profile,JsonArray profiles,Map<String,Integer> indexes,Gson gson){
    var value=new JsonArray();value.add(gson.toJsonTree(profile.ordinary()));value.add(gson.toJsonTree(profile.silk()));
    var key=gson.toJson(value);Integer index=indexes.get(key);
    if(index==null){index=profiles.size();indexes.put(key,index);profiles.add(value);}return index;
  }
  static boolean baseDrops(Block block)throws NoSuchMethodException{
    for(Class<?> type=block.getClass();type!=null;type=type.getSuperclass()){
      try{return type.getDeclaredMethod("getDrops",net.minecraft.world.level.block.state.BlockState.class,LootParams.Builder.class).getDeclaringClass()==BlockBehaviour.class;}
      catch(NoSuchMethodException missing){}
    }
    throw new NoSuchMethodException("Missing block drop method");
  }
  static void simpleCallbacks(Block block)throws NoSuchMethodException{
    if(block.getClass().getMethod("destroy",net.minecraft.world.level.LevelAccessor.class,net.minecraft.core.BlockPos.class,BlockState.class).getDeclaringClass()!=Block.class
      ||block.getClass().getMethod("playerDestroy",ServerLevel.class,ServerPlayer.class,net.minecraft.core.BlockPos.class,BlockState.class,net.minecraft.world.level.block.entity.BlockEntity.class,ItemStack.class).getDeclaringClass()!=Block.class
      ||block.getClass().getMethod("playerWillDestroy",net.minecraft.world.level.Level.class,net.minecraft.core.BlockPos.class,BlockState.class,net.minecraft.world.entity.player.Player.class).getDeclaringClass()!=Block.class)throw new AssertionError("Specialized destruction: "+block);
    callbackOwner(block,"spawnAfterBreak",BlockState.class,ServerLevel.class,BlockPos.class,ItemStack.class,boolean.class);
    callbackOwner(block,"affectNeighborsAfterRemoval",BlockState.class,ServerLevel.class,BlockPos.class,boolean.class);
    callbackOwner(block,"attack",BlockState.class,net.minecraft.world.level.Level.class,BlockPos.class,net.minecraft.world.entity.player.Player.class);
  }
  private static void callbackOwner(Block block,String name,Class<?>...parameters)throws NoSuchMethodException{
    for(Class<?> type=block.getClass();type!=null;type=type.getSuperclass())try{
      if(type.getDeclaredMethod(name,parameters).getDeclaringClass()!=BlockBehaviour.class)throw new AssertionError("Specialized "+name+": "+block);
      return;
    }catch(NoSuchMethodException missing){}
    throw new NoSuchMethodException(name);
  }
  static boolean ordinaryCube(Block block){
    return block==Blocks.GLASS||(block.getClass()==Block.class&&block.getStateDefinition().getPossibleStates().size()==1&&block.asItem().getClass()==BlockItem.class&&!block.defaultBlockState().canBeReplaced()&&block.defaultBlockState().isCollisionShapeFullBlock(net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO));
  }
  private static ItemStack enchanted(HolderLookup.Provider lookup,Item item,boolean stored,Map<net.minecraft.resources.ResourceKey<Enchantment>,Integer> levels){
    var stack=new ItemStack(item);var patch=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);
    for(var entry:levels.entrySet())patch.set(lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(entry.getKey()),entry.getValue());
    stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,patch.toImmutable());return stack;
  }
  public static void main(String[] args)throws Exception{
    var base=MiningToolOracle.initialize();var gson=new Gson();var profiles=new JsonArray();profiles.add(JsonNull.INSTANCE);
    var indexes=new LinkedHashMap<String,Integer>();var blocks=new JsonArray();var overrides=new JsonArray();var cases=new JsonArray();var ordinaryMining=new JsonArray();var pillarMining=new JsonArray();int supported=0,states=0;
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
        boolean slab=block.builtInRegistryHolder().is(BlockTags.SLABS);
        if(slab&&!(block instanceof SlabBlock))throw new AssertionError("Non-slab in native slab tag: "+block);
        boolean ordinary=ordinaryCube(block),pillar=block.getClass()==RotatedPillarBlock.class;if(slab||ordinary||pillar)simpleCallbacks(block);
        if(!baseDrops(block)){if(slab||pillar)throw new AssertionError("Specialized admitted block drops: "+block);blocks.add(0);continue;}
        var choices=new LinkedHashMap<BlockState,Profile>();
        try{
          JsonObject table=null;
          if(block.getLootTable().isPresent()){
            var key=block.getLootTable().get().identifier();var path="/data/"+key.getNamespace()+"/loot_table/"+key.getPath()+".json";
            try(var input=MiningLootOracle.class.getResourceAsStream(path)){
              if(input==null)throw new Unsupported();table=JsonParser.parseReader(new InputStreamReader(input,java.nio.charset.StandardCharsets.UTF_8)).getAsJsonObject();
            }
          }
          for(var state:block.getStateDefinition().getPossibleStates())choices.put(state,table==null?new Profile(List.of(),List.of()):new Profile(evaluate(table,false,state),evaluate(table,true,state)));
        }catch(Unsupported unsupported){if(slab||pillar)throw new AssertionError("Unsupported admitted block loot: "+block);blocks.add(0);continue;}
        if(ordinary&&block.defaultBlockState().getDestroySpeed(net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO)>=0)ordinaryMining.add(Block.getId(block.defaultBlockState()));
        if(pillar)for(var state:block.getStateDefinition().getPossibleStates())pillarMining.add(Block.getId(state));
        var frequencies=new LinkedHashMap<Profile,Integer>();for(var profile:choices.values())frequencies.merge(profile,1,Integer::sum);
        Profile baseProfile=null;int frequency=0;for(var entry:frequencies.entrySet())if(entry.getValue()>frequency){baseProfile=entry.getKey();frequency=entry.getValue();}
        int baseIndex=index(baseProfile,profiles,indexes,gson);blocks.add(baseIndex);supported++;
        for(var choice:choices.entrySet()){
          var state=choice.getKey();var profile=choice.getValue();int profileIndex=index(profile,profiles,indexes,gson);
          if(profileIndex!=baseIndex){var override=new JsonArray();override.add(Block.getId(state));override.add(profileIndex);overrides.add(override);}
          for(int variant=0;variant<tools.size();variant++){
            server.random=RandomSource.create(17L+Block.getId(state));var tool=tools.get(variant);
            var params=new LootParams.Builder(level).withParameter(LootContextParams.ORIGIN,Vec3.ZERO).withParameter(LootContextParams.BLOCK_STATE,state).withParameter(LootContextParams.TOOL,tool);
            var drops=state.getDrops(params);var actual=new ArrayList<List<Integer>>();
            for(var stack:drops){if(stack.getCount()<1||stack.getCount()>stack.getMaxStackSize()||!stack.getComponentsPatch().isEmpty())throw new AssertionError("Unexpected deterministic stack "+state+" "+stack);actual.add(List.of(BuiltInRegistries.ITEM.getId(stack.getItem()),stack.getCount()));}
            var expected=variant==1||variant==2||variant==6?profile.silk():profile.ordinary();
            if(!actual.equals(expected))throw new AssertionError("Native loot differs "+state+" variant="+variant+" expected="+expected+" actual="+actual);
            var row=new JsonArray();row.add(Block.getId(state));row.add(variant);row.add(gson.toJsonTree(actual));cases.add(row);states++;
          }
        }
      }
    }
    var result=new JsonObject();result.addProperty("version","26.3");result.addProperty("data_version",5023);result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    if(ordinaryMining.size()!=178)throw new AssertionError("Changed deterministic ordinary mining admission");
    if(pillarMining.size()!=180)throw new AssertionError("Changed deterministic pillar mining admission");
    result.addProperty("state_count",Block.BLOCK_STATE_REGISTRY.size());result.addProperty("block_count",blocks.size());result.addProperty("supported_blocks",supported);result.add("profiles",profiles);result.add("block_profiles",blocks);result.add("state_profiles",overrides);result.add("ordinary_mining",ordinaryMining);result.add("pillar_mining",pillarMining);
    Files.writeString(Path.of(args[0]),gson.toJson(result)+"\n");Files.writeString(Path.of(args[1]),gson.toJson(cases)+"\n");
    System.out.println("PASS: "+supported+" deterministic block families, "+states+" actual native state/tool drop contexts, "+ordinaryMining.size()+" finite ordinary states with verified base destruction; random/context/function rules excluded.");
  }
}
