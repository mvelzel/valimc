import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.tags.TagLoader;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.RecipeManager;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.entity.*;

/** Original actual changed-slot setter observations; unchanged slots are not assigned. No storage/XP claim. */
public class CookingSlotEditOracle {
  static ItemStack stack(int profile){
    if(profile==0)return ItemStack.EMPTY;
    var stack=new ItemStack(profile==3?Items.COD:profile==4?Items.STONE:profile==6||profile==7?Items.COAL:Items.RAW_IRON,profile==2?1:profile==7?99:3);
    if(profile==5)stack.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
    if(profile==7)stack.set(DataComponents.MAX_STACK_SIZE,99);
    return stack;
  }
  static JsonObject observe(AbstractFurnaceBlockEntity storage)throws Exception {
    var row=new JsonObject();var slots=new JsonArray();for(int i=0;i<3;i++)slots.add(CookingTickOracle.encode(storage.getItem(i)));row.add("slots",slots);
    for(var name:List.of("litTimeRemaining","litTotalTime","cookingTimer","cookingTotalTime"))row.addProperty(name,CookingTickOracle.field(name).getInt(storage));
    row.addProperty("speed",CookingTickOracle.field("speedMultiplier").getFloat(storage));return row;
  }
  public static void main(String[] args)throws Exception {
    var initial=MiningToolOracle.initialize();CookingTickOracle.access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var unsafe=(sun.misc.Unsafe)f.get(null);var cases=new JsonArray();
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var pending=TagLoader.loadTagsForExistingRegistries(resources,CookingTickOracle.access);var statics=TagLoader.buildUpdatedLookups(CookingTickOracle.access,pending);var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
      var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();var keys=loaded.listRegistryKeys().collect(Collectors.toSet());var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));for(var tags:pending)tags.apply();var manager=new RecipeManager(lookup);
      for(int kind=0;kind<3;kind++)for(int old=0;old<8;old++)for(int replacement=0;replacement<8;replacement++)for(int slot=0;slot<3;slot++)for(float speed:new float[]{1f,2f})for(int progress:new int[]{0,49}) {
        var world=(CookingTickOracle.World)unsafe.allocateInstance(CookingTickOracle.World.class);world.manager=manager;world.state=(kind==0?Blocks.FURNACE:kind==1?Blocks.SMOKER:Blocks.BLAST_FURNACE).defaultBlockState();world.drops=new ArrayList<>();
        AbstractFurnaceBlockEntity storage=kind==0?new FurnaceBlockEntity(BlockPos.ZERO,world.state):kind==1?new SmokerBlockEntity(BlockPos.ZERO,world.state):new BlastFurnaceBlockEntity(BlockPos.ZERO,world.state);
        storage.setItem(0,stack(old));storage.setItem(1,new ItemStack(Items.COAL,2));storage.setItem(2,new ItemStack(Items.IRON_INGOT));
        CookingTickOracle.field("litTimeRemaining").setInt(storage,2);CookingTickOracle.field("litTotalTime").setInt(storage,1600);CookingTickOracle.field("cookingTimer").setInt(storage,progress);CookingTickOracle.field("cookingTotalTime").setInt(storage,123);CookingTickOracle.field("speedMultiplier").setFloat(storage,speed);storage.setLevel(world);
        var row=new JsonObject();row.addProperty("kind",kind);row.addProperty("slot",slot);row.add("before",observe(storage));var proposed=stack(replacement);row.addProperty("replacement",CookingTickOracle.encode(proposed));
        if(!ItemStack.matches(storage.getItem(slot),proposed))storage.setItem(slot,proposed);
        row.add("after",observe(storage));cases.add(row);
      }
    }
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("cases",cases);Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS: "+cases.size()+" actual cooking block-entity changed-slot assignments, count/identity/clear/fuel/output and contextual duration boundaries; live writes/XP excluded.");
  }
}
