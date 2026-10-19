import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.resources.RegistryDataLoader;
import net.minecraft.core.registries.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundRecipeBookAddPacket;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.*;
import net.minecraft.tags.TagLoader;
import net.minecraft.world.item.crafting.*;
import net.minecraft.world.item.crafting.display.*;

/** Original native display/ingredient/category codec observations for the supported cooking registry. */
public class CookingRecipeBookOracle {
 static RegistryAccess.Frozen registries;
 static String entry(ClientboundRecipeBookAddPacket.Entry entry){
  var b=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
  try{
   ClientboundRecipeBookAddPacket.Entry.STREAM_CODEC.encode(b,entry);
   byte[] bytes=new byte[b.readableBytes()];b.getBytes(0,bytes);
   var decoded=ClientboundRecipeBookAddPacket.Entry.STREAM_CODEC.decode(b);
   if(b.isReadable() || !decoded.contents().id().equals(entry.contents().id()) || decoded.flags()!=entry.flags())throw new AssertionError();
   return HexFormat.of().formatHex(bytes);
  }finally{b.release();}
 }
 static String packet(List<ClientboundRecipeBookAddPacket.Entry> entries,boolean replace){
  var b=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
  try{
   ClientboundRecipeBookAddPacket.STREAM_CODEC.encode(b,new ClientboundRecipeBookAddPacket(entries,replace));
   byte[] bytes=new byte[b.readableBytes()];b.getBytes(0,bytes);
   var decoded=ClientboundRecipeBookAddPacket.STREAM_CODEC.decode(b);
   if(b.isReadable() || decoded.entries().size()!=entries.size() || decoded.replace()!=replace)throw new AssertionError();
   return HexFormat.of().formatHex(bytes);
  }finally{b.release();}
 }
 public static void main(String[] args)throws Exception{
  var initial=MiningToolOracle.initialize();
  registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
  try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
   var pending=TagLoader.loadTagsForExistingRegistries(resources,registries);
   var statics=TagLoader.buildUpdatedLookups(registries,pending);
   var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
   var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
   var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
   var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
   var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
   for(var tags:pending)tags.apply();
   var manager=new RecipeManager(lookup);
   var byName=manager.getRecipes().stream().collect(Collectors.toMap(h->h.id().identifier().toString(),h->h.value()));
   var metadata=JsonParser.parseString(Files.readString(Path.of("priv/crafting/cooking.json"))).getAsJsonObject();
   var rows=new JsonArray();var quiet=new ArrayList<ClientboundRecipeBookAddPacket.Entry>();var notify=new ArrayList<ClientboundRecipeBookAddPacket.Entry>();
   var groups=new HashMap<String,Integer>();int id=0;
   for(var element:metadata.getAsJsonArray("recipes")){
    String name=element.getAsJsonObject().get("recipe").getAsString();var recipe=byName.get(name);
    if(!(recipe instanceof AbstractCookingRecipe) || recipe.display().size()!=1)throw new AssertionError(name);
    var group=recipe.group().isEmpty()?OptionalInt.empty():OptionalInt.of(groups.computeIfAbsent(recipe.group(),k->groups.size()));
    var requirements=recipe.placementInfo().isImpossibleToPlace()?Optional.<List<Ingredient>>empty():Optional.of(recipe.placementInfo().ingredients());
    var contents=new RecipeDisplayEntry(new RecipeDisplayId(id++),recipe.display().getFirst(),group,recipe.recipeBookCategory(),requirements);
    var a=new ClientboundRecipeBookAddPacket.Entry(contents,false,false);
    var b=new ClientboundRecipeBookAddPacket.Entry(contents,recipe.showNotification(),true);
    quiet.add(a);notify.add(b);
    var row=new JsonObject();row.addProperty("recipe",name);row.addProperty("quiet",entry(a));row.addProperty("notify",entry(b));
    row.addProperty("single",packet(List.of(b),false));rows.add(row);
   }
   Files.writeString(Path.of(args[0]),new Gson().toJson(Map.of("version","26.3","server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c","entries",rows,
    "quiet_all",packet(quiet,true),"notify_all",packet(notify,false),"empty",packet(List.of(),true))));
   System.out.println("PASS: "+id+" native cooking displays, quiet/notification entry round trips and complete recipe-book packet bodies.");
  }
 }
}
