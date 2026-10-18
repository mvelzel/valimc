import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.tags.TagLoader;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.world.flag.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;
import net.minecraft.world.level.block.state.BlockState;

/** Original actual furnace serverTick observations with controlled world I/O only. */
public class CookingTickOracle {
  static RegistryAccess.Frozen access;
  static class Server extends DedicatedServer {
    ReloadableServerRegistries.Holder registries; RandomSource random;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
    public RandomSource getRandomSequence(Identifier id){return random;}
  }
  static class World extends ServerLevel {
    Server server; RecipeManager manager; BlockState state; List<ItemStack> drops;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return server.random;}
    public FeatureFlagSet enabledFeatures(){return FeatureFlags.DEFAULT_FLAGS;}
    public RegistryAccess registryAccess(){return access;}
    public RecipeManager recipeAccess(){return manager;}
    public int getNextEntityId(){return 1;}
    public boolean addFreshEntity(Entity entity){drops.add(((ItemEntity)entity).getItem().copy());return true;}
    public BlockState getBlockState(BlockPos pos){return state;}
    public boolean setBlockAndUpdate(BlockPos pos,BlockState next){state=next;return true;}
    public void blockEntityChanged(BlockPos pos){}
    public void updateNeighbourForOutputSignal(BlockPos pos,Block block){}
  }
  static java.lang.reflect.Field field(String name)throws Exception {var f=AbstractFurnaceBlockEntity.class.getDeclaredField(name);f.setAccessible(true);return f;}
  static String encode(ItemStack stack){var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);try{ItemStack.OPTIONAL_STREAM_CODEC.encode(buffer,stack);var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}}
  static JsonObject observe(AbstractFurnaceBlockEntity furnace,World world)throws Exception {
    var row=new JsonObject();for(var name:List.of("litTimeRemaining","litTotalTime","cookingTimer","cookingTotalTime"))row.addProperty(name,field(name).getInt(furnace));
    row.addProperty("speed",field("speedMultiplier").getFloat(furnace));row.addProperty("state",Block.getId(world.state));row.addProperty("lit",world.state.getValue(AbstractFurnaceBlock.LIT));
    var slots=new JsonArray();for(int i=0;i<3;i++)slots.add(encode(furnace.getItem(i)));row.add("slots",slots);
    var recipes=new JsonObject();var used=(Map<?,?>)field("recipesUsed").get(furnace);for(var entry:used.entrySet())recipes.addProperty(((ResourceKey<?>)entry.getKey()).identifier().toString(),(Integer)entry.getValue());row.add("recipes",recipes);return row;
  }
  static ItemStack stack(Item item,int count,boolean named){var s=new ItemStack(item,count);if(named)s.set(DataComponents.CUSTOM_NAME,Component.literal("Input"));return s;}
  public static void main(String[] args)throws Exception {
    var initial=MiningToolOracle.initialize();access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
    var u=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");u.setAccessible(true);var unsafe=(sun.misc.Unsafe)u.get(null);var cases=new JsonArray();
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var pending=TagLoader.loadTagsForExistingRegistries(resources,access);var statics=TagLoader.buildUpdatedLookups(access,pending);var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
      var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));for(var tags:pending)tags.apply();
      var server=(Server)unsafe.allocateInstance(Server.class);server.registries=new ReloadableServerRegistries.Holder(lookup);server.random=RandomSource.create(17);var manager=new RecipeManager(lookup);
      for(int kind=0;kind<3;kind++)for(int profile=0;profile<10;profile++)for(int left:new int[]{0,1,2,50})for(int progress:new int[]{0,1,99,199})for(int total:new int[]{0,100,200})for(float speed:new float[]{1f,2f}) {
        var world=(World)unsafe.allocateInstance(World.class);world.server=server;world.manager=manager;world.drops=new ArrayList<>();
        var block=kind==0?Blocks.FURNACE:kind==1?Blocks.SMOKER:Blocks.BLAST_FURNACE;world.state=block.defaultBlockState().setValue(AbstractFurnaceBlock.LIT,left>0);
        AbstractFurnaceBlockEntity furnace=kind==0?new FurnaceBlockEntity(BlockPos.ZERO,world.state):kind==1?new SmokerBlockEntity(BlockPos.ZERO,world.state):new BlastFurnaceBlockEntity(BlockPos.ZERO,world.state);furnace.setLevel(world);
        var input=profile==0?ItemStack.EMPTY:stack(profile==1?Items.STONE:profile==2?Items.COD:profile==3?Items.WET_SPONGE:Items.RAW_IRON,profile==9?1:3,profile==8);
        var fuel=profile==4?ItemStack.EMPTY:stack(profile==3?Items.LAVA_BUCKET:profile==5?Items.STONE:profile==6?Items.DRIED_KELP_BLOCK:Items.COAL,profile==3?1:3,false);
        var output=profile==7?new ItemStack(Items.IRON_INGOT,64):profile==8?stack(Items.IRON_INGOT,63,true):ItemStack.EMPTY;
        furnace.setItem(0,input);furnace.setItem(1,fuel);furnace.setItem(2,output);
        field("litTimeRemaining").setInt(furnace,left);field("litTotalTime").setInt(furnace,1600);field("cookingTimer").setInt(furnace,progress);field("cookingTotalTime").setInt(furnace,total);field("speedMultiplier").setFloat(furnace,speed);
        var row=new JsonObject();row.add("before",observe(furnace,world));AbstractFurnaceBlockEntity.serverTick(world,BlockPos.ZERO,world.state,furnace);row.add("after",observe(furnace,world));var drops=new JsonArray();for(var drop:world.drops)drops.add(encode(drop));row.add("drops",drops);cases.add(row);
      }
      for(int kind=0;kind<3;kind++)for(int profile=0;profile<5;profile++) {
        var world=(World)unsafe.allocateInstance(World.class);world.server=server;world.manager=manager;world.drops=new ArrayList<>();
        var block=kind==0?Blocks.FURNACE:kind==1?Blocks.SMOKER:Blocks.BLAST_FURNACE;world.state=block.defaultBlockState();
        AbstractFurnaceBlockEntity furnace=kind==0?new FurnaceBlockEntity(BlockPos.ZERO,world.state):kind==1?new SmokerBlockEntity(BlockPos.ZERO,world.state):new BlastFurnaceBlockEntity(BlockPos.ZERO,world.state);furnace.setLevel(world);
        var ingredient=kind==1?Items.COD:kind==0&&profile==1?Items.WET_SPONGE:Items.RAW_IRON;
        furnace.setItem(0,stack(ingredient,4,true));var fuel=stack(profile==1||profile==4?Items.LAVA_BUCKET:Items.COAL,profile==1?1:2,false);
        if(profile==4)fuel.set(DataComponents.MAX_STACK_SIZE,99);furnace.setItem(1,fuel);
        if(profile==2)furnace.setItem(2,new ItemStack(kind==1?Items.COOKED_COD:Items.IRON_INGOT,64));
        for(int tick=0;tick<850;tick++) {
          boolean edit=false;
          if(profile==2&&tick==75){furnace.setItem(2,ItemStack.EMPTY);edit=true;}
          if(profile==3&&tick==40){furnace.setItem(0,ItemStack.EMPTY);edit=true;}
          if(profile==3&&tick==80){furnace.setItem(0,stack(ingredient,4,true));edit=true;}
          world.drops.clear();var row=new JsonObject();row.addProperty("trace",kind*5+profile);row.addProperty("tick",tick);row.addProperty("external_edit",edit);row.add("before",observe(furnace,world));
          AbstractFurnaceBlockEntity.serverTick(world,BlockPos.ZERO,world.state,furnace);furnace.setBlockState(world.state);row.add("after",observe(furnace,world));var drops=new JsonArray();for(var drop:world.drops)drops.add(encode(drop));row.add("drops",drops);cases.add(row);
        }
      }
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+cases.size()+" actual native furnace serverTick boundary transitions; no durable runtime claim.");
  }
}
