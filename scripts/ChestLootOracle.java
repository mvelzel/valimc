import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.network.chat.Component;
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
import net.minecraft.world.level.block.entity.BaseContainerBlockEntity;
import net.minecraft.world.level.block.entity.ChestBlockEntity;
import net.minecraft.world.level.storage.loot.*;
import net.minecraft.world.level.storage.loot.parameters.*;
import net.minecraft.world.phys.Vec3;

/** Original observation of chest block loot, separate from stored-content removal. */
public class ChestLootOracle {
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
  public static void main(String[] args)throws Exception {
    var base=MiningToolOracle.initialize(); var cases=new JsonArray();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); field.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)field.get(null);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
      var server=(ProbeServer)unsafe.allocateInstance(ProbeServer.class); server.registries=new ReloadableServerRegistries.Holder(lookup);
      var level=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class); level.server=server;
      var tools=new ArrayList<ItemStack>(); tools.add(ItemStack.EMPTY); tools.add(new ItemStack(Items.DIAMOND_AXE));
      tools.add(new ItemStack(Items.STONE));
      for(var enchantment:List.of(Enchantments.SILK_TOUCH,Enchantments.FORTUNE)) {
        for(boolean stored:List.of(false,true)) {
          var tool=new ItemStack(Items.DIAMOND_PICKAXE);
          var enchantments=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);
          enchantments.set(lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(enchantment),255);
          tool.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,enchantments.toImmutable()); tools.add(tool);
        }
      }
      for(var state:Blocks.CHEST.getStateDefinition().getPossibleStates()) {
        for(int metadata=0;metadata<4;metadata++) for(int tool=0;tool<tools.size();tool++) {
          var chest=new ChestBlockEntity(BlockPos.ZERO,state);
          if(metadata==2) {
            var name=BaseContainerBlockEntity.class.getDeclaredField("name"); name.setAccessible(true);
            name.set(chest,Component.literal("Probe chest"));
          }
          if(metadata==3)chest.setItem(0,new ItemStack(Items.STONE,3));
          server.random=RandomSource.create(77L+Block.getId(state));
          var params=new LootParams.Builder(level).withParameter(LootContextParams.ORIGIN,Vec3.ZERO)
            .withParameter(LootContextParams.BLOCK_STATE,state).withParameter(LootContextParams.TOOL,tools.get(tool));
          if(metadata>0)params.withParameter(LootContextParams.BLOCK_ENTITY,chest);
          var drops=state.getDrops(params);
          if(drops.size()!=1||!drops.getFirst().is(Items.CHEST)||drops.getFirst().getCount()!=1)
            throw new AssertionError("Unexpected chest self drop "+state+" "+drops);
          var drop=drops.getFirst();
          if((drop.get(DataComponents.CUSTOM_NAME)!=null)!=(metadata==2))throw new AssertionError("Changed custom-name copy");
          if(metadata!=2&&!drop.getComponentsPatch().isEmpty())throw new AssertionError("Unexpected stock chest components");
          var row=new JsonObject(); row.addProperty("state",Block.getId(state)); row.addProperty("tool",tool);
          row.addProperty("metadata",metadata); row.addProperty("item",BuiltInRegistries.ITEM.getId(drop.getItem()));
          row.addProperty("count",drop.getCount()); row.addProperty("named",drop.get(DataComponents.CUSTOM_NAME)!=null);
          cases.add(row);
        }
      }
    }
    var result=new JsonObject(); result.addProperty("version","26.3"); result.addProperty("data_version",5023);
    result.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"); result.add("cases",cases);
    Files.writeString(Path.of(args[0]),new Gson().toJson(result)+"\n");
    System.out.println("PASS: "+cases.size()+" native chest self-drop contexts; stored contents are not self loot, custom names copy separately.");
  }
}
