import com.google.gson.*;
import com.mojang.serialization.JsonOps;
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
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.component.CookingFuel;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;

/** Original stock fuel declarations and actual native contextual furnace callbacks. */
public class CookingFuelOracle {
  private static class Server extends DedicatedServer {
    ReloadableServerRegistries.Holder registries; RandomSource random;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
    public RandomSource getRandomSequence(Identifier id){return random;}
  }
  private static class World extends ServerLevel {
    Server server;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return server.random;}
    public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    public RegistryAccess registryAccess(){return RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);}
  }
  public static void main(String[] args)throws Exception {
    var lookup=MiningToolOracle.initialize(); var ops=lookup.createSerializationContext(JsonOps.INSTANCE);
    var items=new JsonArray(); int fuels=0;
    for(var item:BuiltInRegistries.ITEM) {
      var row=new JsonObject(); row.addProperty("id",BuiltInRegistries.ITEM.getId(item));
      row.addProperty("name",BuiltInRegistries.ITEM.getKey(item).toString());
      var stack=new ItemStack(item); var fuel=stack.get(DataComponents.COOKING_FUEL);
      if(fuel==null)row.add("fuel",JsonNull.INSTANCE);
      else {fuels++;row.add("fuel",CookingFuel.CODEC.encodeStart(ops,fuel).getOrThrow());}
      items.add(row);
    }
    var callbacks=new JsonArray();
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); unsafeField.setAccessible(true); var unsafe=(sun.misc.Unsafe)unsafeField.get(null);
    var burn=AbstractFurnaceBlockEntity.class.getDeclaredMethod("getBurnDuration",ServerLevel.class,ItemStack.class); burn.setAccessible(true);
    var speed=AbstractFurnaceBlockEntity.class.getDeclaredMethod("getSpeedMultiplier",ServerLevel.class,ItemStack.class); speed.setAccessible(true);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var loaded=RegistryDataLoader.load(resources,lookup.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
      var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var combined=HolderLookup.Provider.create(Stream.concat(lookup.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
      var server=(Server)unsafe.allocateInstance(Server.class); server.registries=new ReloadableServerRegistries.Holder(combined); server.random=RandomSource.create(42);
      var world=(World)unsafe.allocateInstance(World.class); world.server=server;
      var furnaces=new ArrayList<AbstractFurnaceBlockEntity>();
      for(var state:Blocks.FURNACE.getStateDefinition().getPossibleStates())furnaces.add(new FurnaceBlockEntity(BlockPos.ZERO,state));
      for(var state:Blocks.SMOKER.getStateDefinition().getPossibleStates())furnaces.add(new SmokerBlockEntity(BlockPos.ZERO,state));
      for(var state:Blocks.BLAST_FURNACE.getStateDefinition().getPossibleStates())furnaces.add(new BlastFurnaceBlockEntity(BlockPos.ZERO,state));
      for(var furnace:furnaces) {
        furnace.setLevel(world);
        for(var item:BuiltInRegistries.ITEM) for(boolean removed:List.of(false,true)) {
          var stack=new ItemStack(item); if(removed)stack.remove(DataComponents.COOKING_FUEL);
          var row=new JsonObject(); row.addProperty("item",BuiltInRegistries.ITEM.getId(item));
          row.addProperty("block",BuiltInRegistries.BLOCK.getKey(furnace.getBlockState().getBlock()).toString());
          row.addProperty("state",Block.getId(furnace.getBlockState()));
          row.addProperty("removed",removed); row.addProperty("burn",(Integer)burn.invoke(furnace,world,stack));
          row.addProperty("speed",(Float)speed.invoke(furnace,world,stack)); callbacks.add(row);
        }
      }
    }
    var out=new JsonObject(); out.addProperty("version","26.3"); out.addProperty("data_version",5023);
    out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    out.addProperty("fuel_items",fuels); out.add("items",items); out.add("callbacks",callbacks);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+items.size()+" stock items, "+fuels+" cooking-fuel declarations, "+callbacks.size()+" actual burn/speed callbacks; no live cooking claim.");
  }
}
