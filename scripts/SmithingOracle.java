import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import java.util.stream.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.*;
import net.minecraft.server.packs.resources.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.crafting.*;
import net.minecraft.world.item.enchantment.ItemEnchantments;

/**
 * Smithing (VMC-038c), from the data pack's recipes in a `RecipeManager`:
 * `facts` writes every smithing recipe (its template, base and addition item sets, a
 * transform's result, a trim's pattern); `cases` assembles the recipe a smithing table finds for
 * netherite upgrades, trims of every pattern and material, re-trims, an enchanted damaged base and
 * mismatched inputs. `check_smithing.exs` replays the cases through `Valimc.Menus.Smithing`.
 * Usage: SmithingOracle facts OUT.json | cases OUT.json
 */
public class SmithingOracle {
  static JsonElement ids(Optional<Ingredient> ingredient) {
    if (ingredient.isEmpty()) return JsonNull.INSTANCE;
    var out = new JsonArray();
    ingredient.get().items().map(h -> BuiltInRegistries.ITEM.getKey(h.value()).toString()).sorted().forEach(out::add);
    return out;
  }

  static JsonElement describe(ItemStack s) {
    if (s.isEmpty()) return JsonNull.INSTANCE;
    var o = new JsonObject();
    o.addProperty("item", BuiltInRegistries.ITEM.getKey(s.getItem()).toString());
    o.addProperty("count", s.getCount());
    o.addProperty("damage", s.getDamageValue());
    var trim = s.get(DataComponents.TRIM);
    if (trim != null) {
      o.addProperty("material", trim.material().unwrapKey().orElseThrow().identifier().toString());
      o.addProperty("pattern", trim.pattern().unwrapKey().orElseThrow().identifier().toString());
    }
    var levels = new JsonArray();
    var sorted = new TreeMap<String, Integer>();
    s.getOrDefault(DataComponents.ENCHANTMENTS, ItemEnchantments.EMPTY).entrySet()
        .forEach(e -> sorted.put(e.getKey().unwrapKey().orElseThrow().identifier().toString(), e.getIntValue()));
    sorted.forEach((k, v) -> { var p = new JsonArray(); p.add(k); p.add(v); levels.add(p); });
    o.add("enchantments", levels);
    return o;
  }

  public static void main(String[] args) throws Exception {
    var initial = MiningToolOracle.initialize();
    try (var resources = new MultiPackResourceManager(PackType.SERVER_DATA, List.of(ServerPacksSource.createVanillaPackSource().fullResources()))) {
      var access = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY);
      var pending = net.minecraft.tags.TagLoader.loadTagsForExistingRegistries(resources, access);
      var statics = net.minecraft.tags.TagLoader.buildUpdatedLookups(access, pending);
      var staticKeys = statics.stream().map(r -> r.key()).collect(Collectors.toSet());
      var base = HolderLookup.Provider.create(Stream.concat(initial.listRegistries().filter(r -> !staticKeys.contains(r.key())), statics.stream()));
      var loaded = net.minecraft.resources.RegistryDataLoader.load(resources, base.listRegistries().toList(), net.minecraft.resources.RegistryDataLoader.RELOADABLE_REGISTRIES, Runnable::run).join();
      var keys = loaded.listRegistryKeys().collect(Collectors.toSet());
      var lookup = HolderLookup.Provider.create(Stream.concat(base.listRegistries().filter(r -> !keys.contains(r.key())), loaded.listRegistries()));
      for (var tags : pending) tags.apply();
      var manager = new RecipeManager(lookup);

      if (args[0].equals("facts")) {
        var recipes = new JsonArray();
        var holders = new ArrayList<RecipeHolder<?>>(manager.getRecipes());
        holders.sort(Comparator.comparing(h -> h.id().identifier().toString()));
        for (var holder : holders) {
          if (!(holder.value() instanceof SmithingRecipe recipe)) continue;
          var o = new JsonObject();
          o.addProperty("name", holder.id().identifier().toString());
          o.add("template", ids(recipe.templateIngredient()));
          o.add("base", ids(Optional.of(recipe.baseIngredient())));
          o.add("addition", ids(recipe.additionIngredient()));
          if (recipe instanceof SmithingTransformRecipe) {
            var out = recipe.assemble(new SmithingRecipeInput(ItemStack.EMPTY, new ItemStack(Items.STICK), ItemStack.EMPTY));
            o.addProperty("type", "transform");
            o.addProperty("result", BuiltInRegistries.ITEM.getKey(out.getItem()).toString());
            o.addProperty("count", out.getCount());
          } else if (recipe instanceof SmithingTrimRecipe trim) {
            var field = SmithingTrimRecipe.class.getDeclaredField("pattern");
            field.setAccessible(true);
            var pattern = (Holder<?>) field.get(trim);
            o.addProperty("type", "trim");
            o.addProperty("pattern", pattern.unwrapKey().orElseThrow().identifier().toString());
          } else {
            throw new AssertionError("Unknown smithing recipe " + holder.id());
          }
          recipes.add(o);
        }
        var out = new JsonObject();
        out.add("recipes", recipes);
        Files.writeString(Path.of(args[1]), new GsonBuilder().setPrettyPrinting().create().toJson(out) + "\n");
        System.out.println("PASS: " + recipes.size() + " smithing recipes");
        return;
      }

      var item = (java.util.function.Function<String, ItemStack>) n -> new ItemStack(BuiltInRegistries.ITEM.getValue(Identifier.parse(n)));
      var templates = new ArrayList<String>();
      for (var h : manager.getRecipes())
        if (h.value() instanceof SmithingRecipe r)
          r.templateIngredient().ifPresent(t -> t.items().forEach(i -> templates.add(BuiltInRegistries.ITEM.getKey(i.value()).toString())));
      var bases = List.of("minecraft:diamond_sword", "minecraft:diamond_chestplate", "minecraft:diamond_hoe", "minecraft:iron_helmet",
          "minecraft:netherite_boots", "minecraft:turtle_helmet", "minecraft:stick", "minecraft:diamond_horse_armor");
      var additions = List.of("minecraft:netherite_ingot", "minecraft:diamond", "minecraft:amethyst_shard", "minecraft:redstone",
          "minecraft:gold_ingot", "minecraft:resin_brick", "minecraft:iron_ingot", "minecraft:stick");
      var cases = new JsonArray();
      var seen = new HashSet<String>();
      for (var template : templates) {
        if (!seen.add(template)) continue;
        for (var b : bases) {
          for (var a : additions) {
            for (var variant : List.of("plain", "enchanted", "trimmed")) {
              var baseItem = item.apply(b);
              if (variant.equals("enchanted") && baseItem.isDamageableItem()) {
                baseItem.setDamageValue(17);
                var registry = lookup.lookupOrThrow(Registries.ENCHANTMENT);
                baseItem.enchant(registry.getOrThrow(ResourceKey.create(Registries.ENCHANTMENT, Identifier.parse("minecraft:unbreaking"))), 3);
              } else if (variant.equals("enchanted")) continue;
              if (variant.equals("trimmed")) {
                var input = new SmithingRecipeInput(item.apply(template), baseItem.copy(), item.apply(a));
                var first = manager.getRecipeFor(RecipeType.SMITHING, input, null);
                if (first.isEmpty() || !(first.get().value() instanceof SmithingTrimRecipe)) continue;
                baseItem = first.get().value().assemble(input);
                if (baseItem.isEmpty()) continue;
              }
              var input = new SmithingRecipeInput(item.apply(template), baseItem, item.apply(a));
              var found = manager.getRecipeFor(RecipeType.SMITHING, input, null);
              var o = new JsonObject();
              o.addProperty("template", template);
              o.add("base", describe(baseItem));
              o.addProperty("addition", a);
              o.add("result", found.isEmpty() ? JsonNull.INSTANCE : describe(found.get().value().assemble(input)));
              cases.add(o);
            }
          }
        }
      }
      Files.writeString(Path.of(args[1]), new Gson().toJson(cases) + "\n");
      System.out.println("PASS: " + cases.size() + " smithing cases");
    }
  }
}
