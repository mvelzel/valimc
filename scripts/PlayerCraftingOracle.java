/** Original native player-grid recipe observations; raw resources remain private. */
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
public class PlayerCraftingOracle {
  @SuppressWarnings("unchecked") static List<Optional<Ingredient>> ingredients(CraftingRecipe r)throws Exception {
    if(r instanceof ShapedRecipe s)return s.getIngredients();
    var f=ShapelessRecipe.class.getDeclaredField("ingredients");
    f.setAccessible(true);
    return ((List<Ingredient>)f.get(r)).stream().map(Optional::of).toList();
  }
  static final LinkedHashMap<String,int[]> grids=new LinkedHashMap<>();
  static void add(int[] grid) {
    grids.putIfAbsent(Arrays.toString(grid),grid.clone());
  }
  static void permutations(int[] grid,int start) {
    if(start==4) {
      add(grid);
      return;
    }
    for(int i=start;i<4;i++) {
      int value=grid[start];
      grid[start]=grid[i];
      grid[i]=value;
      permutations(grid,start+1);
      value=grid[start];
      grid[start]=grid[i];
      grid[i]=value;
    }
  }
  static void variants(JsonObject row,int[] values) {
    int w=row.get("width").getAsInt(),h=row.get("height").getAsInt();
    if(w==0) {
      var grid=new int[4];
      System.arraycopy(values,0,grid,0,values.length);
      permutations(grid,0);
    }
    else for(int y=0;y<=2-h;y++)for(int x=0;x<=2-w;x++)for(boolean mirror:new boolean[] {
      false,true
    }
    ) {
      var grid=new int[4];
      for(int i=0;i<values.length;i++)grid[(y+i/w)*2+x+(mirror?w-1-i%w:i%w)]=values[i];
      add(grid);
    }
  }
  static JsonArray cases(RecipeManager manager,JsonArray facts,Set<String> enabled) {
    for(var entry:facts) {
      var row=entry.getAsJsonObject();
      var sets=row.getAsJsonArray("ingredients");
      int[] values=new int[sets.size()];
      int largest=0;
      for(int i=0;i<sets.size();i++) {
        var set=sets.get(i);
        values[i]=set.isJsonNull()?0:set.getAsJsonArray().get(0).getAsInt();
        if(!set.isJsonNull())largest=Math.max(largest,set.getAsJsonArray().size());
      }
      variants(row,values);
      for(int i=0;i<sets.size();i++)if(!sets.get(i).isJsonNull())for(var id:sets.get(i).getAsJsonArray()) {
        int original=values[i];
        values[i]=id.getAsInt();
        variants(row,values);
        values[i]=original;
      }
      for(int n=0;n<largest;n++) {
        for(int i=0;i<sets.size();i++)if(!sets.get(i).isJsonNull()) {
          var set=sets.get(i).getAsJsonArray();
          values[i]=set.get((n+i)%set.size()).getAsInt();
        }
        variants(row,values);
      }
    }
    var positives=new ArrayList<>(grids.values());
    for(var grid:positives)for(int i=0;i<4;i++) {
      var wrong=grid.clone();
      wrong[i]=BuiltInRegistries.ITEM.getId(Items.BEDROCK);
      add(wrong);
      if(grid[i]!=0) {
        wrong=grid.clone();
        wrong[i]=0;
        add(wrong);
      }
    }
    add(new int[4]);
    var cases=new JsonArray();
    for(var grid:grids.values())for(boolean patched:new boolean[] {
      false,true
    }
    ) {
      var stacks=new ArrayList<ItemStack>();
      for(int id:grid) {
        var stack=id==0?ItemStack.EMPTY:new ItemStack(BuiltInRegistries.ITEM.byId(id));
        if(patched&&!stack.isEmpty()) {
          stack.setCount(Math.min(17,stack.getMaxStackSize()));
          stack.set(net.minecraft.core.component.DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
        }
        stacks.add(stack);
      }
      var input=CraftingInput.of(2,2,stacks);
      var selected=manager.getRecipeFor(RecipeType.CRAFTING,input,null);
      var observed=new JsonArray();
      observed.add(new Gson().toJsonTree(grid));
      observed.add(patched);
      if(selected.isPresent()) {
        var holder=selected.get();
        String name=holder.id().identifier().toString();
        observed.add(name);
        if(enabled.contains(name)) {
          var result=holder.value().assemble(input);
          if(!result.getComponentsPatch().isEmpty())throw new AssertionError("Unexpected input-dependent output "+holder.id());
          var outcome=new JsonArray();
          outcome.add(BuiltInRegistries.ITEM.getId(result.getItem()));
          outcome.add(result.getCount());
          observed.add(outcome);
        }
        else observed.add(JsonNull.INSTANCE);
      }
      else {
        observed.add(JsonNull.INSTANCE);
        observed.add(JsonNull.INSTANCE);
      }
      cases.add(observed);
    }
    return cases;
  }
  public static void main(String[]args)throws Exception {
    var initial=MiningToolOracle.initialize();
    var facts=new JsonArray();
    int ordinary=0,small=0,remainder=0,patch=0;
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
      for(var holder:manager.getRecipes()) {
        if(!(holder.value() instanceof CraftingRecipe recipe)||(recipe.getClass()!=ShapedRecipe.class&&recipe.getClass()!=ShapelessRecipe.class))continue;
        ordinary++;
        var ingredients=ingredients(recipe);
        int w=0,h=0;
        if(recipe instanceof ShapedRecipe shape) {
          w=shape.getWidth();
          h=shape.getHeight();
          if(w>2||h>2)continue;
        }
        else if(ingredients.size()>4)continue;
        small++;
        var sets=new JsonArray();
        boolean returns=false;
        for(var ingredient:ingredients) {
          if(ingredient.isEmpty()) {
            sets.add(JsonNull.INSTANCE);
            continue;
          }
          var ids=new JsonArray();
          for(var item:ingredient.get().items().toList()) {
            ids.add(BuiltInRegistries.ITEM.getId(item.value()));
            if(item.value().getCraftingRemainder()!=null)returns=true;
          }
          if(ids.isEmpty())throw new AssertionError("Empty ingredient "+holder.id());
          sets.add(ids);
        }
        if(returns) {
          System.out.println("REMAINDER "+holder.id());
          remainder++;
          continue;
        }
        var result=recipe.assemble(CraftingInput.EMPTY);
        for(var method:List.of("onCraftedBy","onCraftedPostProcess")) {
          var second=method.equals("onCraftedBy")?net.minecraft.world.entity.player.Player.class:net.minecraft.world.level.Level.class;
          var owner=result.getItem().getClass().getMethod(method,ItemStack.class,second).getDeclaringClass();
          if(owner!=Item.class)throw new AssertionError("Specialized crafting output "+holder.id()+" "+method+" "+owner);
        }
        if(!result.getComponentsPatch().isEmpty()) {
          System.out.println("PATCH "+holder.id()+" "+result.getComponentsPatch());
          patch++;
          continue;
        }
        var row=new JsonObject();
        row.addProperty("name",holder.id().identifier().toString());
        row.addProperty("width",w);
        row.addProperty("height",h);
        row.add("ingredients",sets);
        row.addProperty("result",BuiltInRegistries.ITEM.getId(result.getItem()));
        row.addProperty("count",result.getCount());
        facts.add(row);
      }
      var input=CraftingInput.of(2,2,List.of(new ItemStack(Items.OAK_LOG),ItemStack.EMPTY,ItemStack.EMPTY,ItemStack.EMPTY));
      var match=manager.getRecipeFor(RecipeType.CRAFTING,input,null).orElseThrow();
      System.out.println("OAK "+match.id()+" -> "+match.value().assemble(input));
      var enabled=facts.asList().stream().map(r->r.getAsJsonObject().get("name").getAsString()).filter(n->!n.equals("minecraft:firework_rocket_simple")).collect(Collectors.toSet());
      var observed=cases(manager,facts,enabled);
      if(observed.size()!=149128)throw new AssertionError("Changed native crafting contexts");
      Files.writeString(Path.of(args[1]),new Gson().toJson(observed));
      System.out.println("MATCH CASES "+observed.size());
    }
    var enabledProfiles=new JsonArray();
    for(var row:facts)if(!row.getAsJsonObject().get("name").getAsString().equals("minecraft:firework_rocket_simple"))enabledProfiles.add(row);
    if(enabledProfiles.size()!=476||ordinary!=1202||small!=496||remainder!=2||patch!=17)throw new AssertionError("Changed ordinary player recipe classification");
    var normalized=new JsonObject();
    normalized.addProperty("version","26.3");
    normalized.addProperty("data_version",5023);
    normalized.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");
    normalized.add("recipes",enabledProfiles);
    Files.writeString(Path.of(args[0]),new Gson().toJson(normalized)+"\n");
    System.out.println("PASS:476 ordinary player-grid recipes and149128 native global selections;2 remainder,17 component and1 shadowed special recipe excluded.");
  }
}
