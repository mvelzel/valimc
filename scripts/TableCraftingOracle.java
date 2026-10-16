/** Original native table-recipe observations; upstream resources stay private. */
import com.google.gson.*;
import java.util.*;
import java.util.stream.*;
import java.nio.file.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.*;
import net.minecraft.server.packs.resources.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;
public class TableCraftingOracle extends PlayerCraftingOracle {

 static void permutations9(int[] grid,int start) {
  if(start==9){add(grid);return;}
  var seen=new HashSet<Integer>();
  for(int i=start;i<9;i++)if(seen.add(grid[i])) {
   int v=grid[start];grid[start]=grid[i];grid[i]=v;
   permutations9(grid,start+1);
   v=grid[start];grid[start]=grid[i];grid[i]=v;
  }
 }
 static int[] base9(JsonObject row,int[] values,int x,int y,boolean mirror) {
  var grid=new int[9];int w=row.get("width").getAsInt();
  if(w==0)System.arraycopy(values,0,grid,0,values.length);
  else for(int i=0;i<values.length;i++)grid[(y+i/w)*3+x+(mirror?w-1-i%w:i%w)]=values[i];
  return grid;
 }
 static void variants9(JsonObject row,int[] values) {
  int w=row.get("width").getAsInt(),h=row.get("height").getAsInt();
  if(w==0)permutations9(base9(row,values,0,0,false),0);
  else for(int y=0;y<=3-h;y++)for(int x=0;x<=3-w;x++)for(boolean mirror:new boolean[]{false,true})add(base9(row,values,x,y,mirror));
 }
 static void cases9(RecipeManager manager,JsonArray profiles,Set<String> enabled,String path)throws Exception {
  var examples=new ArrayList<int[]>();
  for(var entry:profiles) {
   var row=entry.getAsJsonObject();var sets=row.getAsJsonArray("ingredients");
   var values=new int[sets.size()];int largest=0;
   for(int i=0;i<values.length;i++)if(!sets.get(i).isJsonNull()){var ids=sets.get(i).getAsJsonArray();values[i]=ids.get(0).getAsInt();largest=Math.max(largest,ids.size());}
   examples.add(base9(row,values,0,0,false));variants9(row,values);
   for(int i=0;i<values.length;i++)if(!sets.get(i).isJsonNull())for(var id:sets.get(i).getAsJsonArray()){
    int original=values[i];values[i]=id.getAsInt();variants9(row,values);values[i]=original;
   }
   for(int n=0;n<largest;n++){
    for(int i=0;i<values.length;i++)if(!sets.get(i).isJsonNull()){var ids=sets.get(i).getAsJsonArray();values[i]=ids.get((n+i)%ids.size()).getAsInt();}
    variants9(row,values);
   }
  }
  for(var grid:examples)for(int i=0;i<9;i++){
   var bad=grid.clone();bad[i]=BuiltInRegistries.ITEM.getId(Items.BEDROCK);add(bad);
   if(grid[i]!=0){bad=grid.clone();bad[i]=0;add(bad);}
  }
  for(int powder:new int[]{2,3}) {
   var firework=new int[9];firework[0]=BuiltInRegistries.ITEM.getId(Items.PAPER);
   for(int i=1;i<=powder;i++)firework[i]=BuiltInRegistries.ITEM.getId(Items.GUNPOWDER);
   permutations9(firework,0);
  }
  add(new int[9]);int count=0;
  try(var writer=new com.google.gson.stream.JsonWriter(Files.newBufferedWriter(Path.of(path)))) {
   writer.beginArray();
   for(var grid:grids.values())for(boolean patched:new boolean[]{false,true}) {
    var stacks=new ArrayList<ItemStack>();
    for(int id:grid){var stack=id==0?ItemStack.EMPTY:new ItemStack(BuiltInRegistries.ITEM.byId(id));if(patched&&!stack.isEmpty()){stack.setCount(Math.min(17,stack.getMaxStackSize()));stack.set(net.minecraft.core.component.DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);}stacks.add(stack);}
    var input=CraftingInput.of(3,3,stacks);var selected=manager.getRecipeFor(RecipeType.CRAFTING,input,null);
    var observed=new JsonArray();observed.add(new Gson().toJsonTree(grid));observed.add(patched);
    if(selected.isPresent()){
     var holder=selected.get();String name=holder.id().identifier().toString();observed.add(name);
     if(enabled.contains(name)){var result=holder.value().assemble(input);if(!result.getComponentsPatch().isEmpty())throw new AssertionError("Patched ordinary result");var outcome=new JsonArray();outcome.add(BuiltInRegistries.ITEM.getId(result.getItem()));outcome.add(result.getCount());observed.add(outcome);}
     else observed.add(JsonNull.INSTANCE);
    }else{observed.add(JsonNull.INSTANCE);observed.add(JsonNull.INSTANCE);}
    new Gson().toJson(observed,writer);count++;
   }
   writer.endArray();
  }
  if(count!=438672)throw new AssertionError("Changed native table crafting contexts");
  System.out.println("PASS: "+count+" native table contexts / "+grids.size()+" distinct grids.");
 }

 public static void main(String[] args)throws Exception {
  var initial=MiningToolOracle.initialize();
  try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
   var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
   var pending=net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources,access);
   var statics=net.minecraft.tags.TagLoader.buildUpdatedLookups(access,pending);
   var staticKeys=statics.stream().map(r->r.key()).collect(Collectors.toSet());
   var base=HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r->!staticKeys.contains(r.key())),statics.stream()));
   var loaded=RegistryDataLoader.load(resources,base.listRegistries().toList(),RegistryDataLoader.RELOADABLE_REGISTRIES,Runnable::run).join();
   var keys=loaded.listRegistryKeys().collect(Collectors.toSet());
   var lookup=HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r->!keys.contains(r.key())),loaded.listRegistries()));
   for(var tags:pending)tags.apply();
   var manager=new RecipeManager(lookup);
   var profiles=new JsonArray();int ordinary=0,remainder=0,patch=0,hook=0;
   for(var holder:manager.getRecipes()) {
    if(!(holder.value() instanceof CraftingRecipe recipe)||(recipe.getClass()!=ShapedRecipe.class&&recipe.getClass()!=ShapelessRecipe.class))continue;
    ordinary++;var ingredients=ingredients(recipe);int w=0,h=0;
    if(recipe instanceof ShapedRecipe shape){w=shape.getWidth();h=shape.getHeight();if(w>3||h>3)throw new AssertionError("Large shape");}
    else if(ingredients.size()>9)throw new AssertionError("Large bag");
    var sets=new JsonArray();boolean returns=false;
    for(var ingredient:ingredients) {
     if(ingredient.isEmpty()){sets.add(JsonNull.INSTANCE);continue;}
     var ids=new JsonArray();for(var item:ingredient.get().items().toList()){ids.add(BuiltInRegistries.ITEM.getId(item.value()));if(item.value().getCraftingRemainder()!=null)returns=true;}
     if(ids.isEmpty())throw new AssertionError("Empty ingredient");sets.add(ids);
    }
    if(returns){System.out.println("REMAINDER "+holder.id());remainder++;continue;}
    var output=recipe.assemble(CraftingInput.EMPTY);
    if(!output.getComponentsPatch().isEmpty()){patch++;continue;}
    boolean overridden=false;
    for(var method:List.of("onCraftedBy","onCraftedPostProcess")){
     var second=method.equals("onCraftedBy")?net.minecraft.world.entity.player.Player.class:net.minecraft.world.level.Level.class;
     var owner=output.getItem().getClass().getMethod(method,ItemStack.class,second).getDeclaringClass();
     if(owner!=Item.class){overridden=true;System.out.println("HOOK "+holder.id()+" "+method+" "+owner);}
    }
    if(overridden){hook++;continue;}
    var row=new JsonObject();row.addProperty("name",holder.id().identifier().toString());row.addProperty("width",w);row.addProperty("height",h);row.add("ingredients",sets);row.addProperty("result",BuiltInRegistries.ITEM.getId(output.getItem()));row.addProperty("count",output.getCount());profiles.add(row);
   }
   var enabledProfiles=new JsonArray();var enabled=new HashSet<String>();
   for(var row:profiles) {
    String name=row.getAsJsonObject().get("name").getAsString();
    if(!Set.of("minecraft:firework_rocket_simple","minecraft:decorated_pot_simple").contains(name)){enabledProfiles.add(row);enabled.add(name);}
   }
   if(ordinary!=1202||remainder!=3||patch!=17||hook!=0||profiles.size()!=1182||enabledProfiles.size()!=1180)throw new AssertionError("Changed ordinary table recipe classification");
   var normalized=new JsonObject();normalized.addProperty("version","26.3");normalized.addProperty("data_version",5023);normalized.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");normalized.add("recipes",enabledProfiles);
   Files.writeString(Path.of(args[0]),new Gson().toJson(normalized)+"\n");
   cases9(manager,profiles,enabled,args[1]);
   System.out.println("PASS:1180 ordinary table recipes;3 remainders,17 component outputs and2 shadowed recipes excluded.");
  }
 }
}
