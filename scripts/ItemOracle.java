import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.resources.Identifier;
import net.minecraft.util.Unit;
import net.minecraft.world.item.*;

/** Independent Mojang-generated fixtures and semantic decoding of Elixir output. */
public class ItemOracle {
  private static RegistryAccess.Frozen registries;
  private static Map<String, ItemStack> cases() {
    Map<String, ItemStack> cases = new LinkedHashMap<>();
    cases.put("empty", ItemStack.EMPTY);
    cases.put("stone64", new ItemStack(Items.STONE, 64));
    cases.put("egg16", new ItemStack(Items.EGG, 16));
    var sword = new ItemStack(Items.DIAMOND_SWORD);
    sword.set(DataComponents.DAMAGE, 137);
    cases.put("damaged_sword", sword);
    var damage = new ItemStack(Items.STONE);
    damage.set(DataComponents.MAX_STACK_SIZE, 1);
    damage.set(DataComponents.MAX_DAMAGE, 256);
    damage.set(DataComponents.DAMAGE, 12);
    cases.put("damage_patch", damage);
    var scalar = new ItemStack(Items.STONE, 32);
    scalar.set(DataComponents.MAX_STACK_SIZE, 32);
    scalar.set(DataComponents.RARITY, Rarity.RARE);
    scalar.set(DataComponents.UNBREAKABLE, Unit.INSTANCE);
    scalar.set(DataComponents.CREATIVE_SLOT_LOCK, Unit.INSTANCE);
    scalar.set(DataComponents.INTANGIBLE_PROJECTILE, Unit.INSTANCE);
    scalar.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE, true);
    scalar.set(DataComponents.REPAIR_COST, 3);
    scalar.set(DataComponents.ITEM_MODEL, Identifier.parse("valimc:test/item"));
    scalar.set(DataComponents.TOOLTIP_STYLE, Identifier.parse("valimc:test/tooltip"));
    scalar.set(DataComponents.MINIMUM_ATTACK_CHARGE, 0.25f);
    cases.put("scalar_patch", scalar);
    var removed = new ItemStack(Items.STONE);
    removed.remove(DataComponents.MAX_STACK_SIZE);
    removed.remove(DataComponents.ITEM_NAME);
    cases.put("removals", removed);
    var mixed = new ItemStack(Items.DIAMOND_SWORD, 2);
    mixed.remove(DataComponents.MAX_DAMAGE);
    mixed.set(DataComponents.MAX_STACK_SIZE, 2);
    mixed.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE, false);
    cases.put("mixed_patch", mixed);
    return cases;
  }
  private static String encode(ItemStack stack, boolean untrusted) {
    var buf = new RegistryFriendlyByteBuf(Unpooled.buffer(), registries);
    try {
      var codec = untrusted ? ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC : ItemStack.OPTIONAL_STREAM_CODEC;
      codec.encode(buf, stack);
      byte[] bytes = new byte[buf.readableBytes()]; buf.readBytes(bytes);
      return HexFormat.of().formatHex(bytes);
    } finally { buf.release(); }
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion(); Bootstrap.bootStrap();
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    registries = RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    var cases = cases();
    if (args[0].equals("generate")) {
      List<Map<String, String>> fixtures = new ArrayList<>();
      cases.forEach((name, stack) -> fixtures.add(Map.of("name", name,
        "trusted", encode(stack, false), "untrusted", encode(stack, true))));
      Files.writeString(Path.of(args[1]), new Gson().toJson(fixtures));
    } else if (args[0].equals("verify")) {
      var fixtures = JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for (var fixture : fixtures) {
        var object = fixture.getAsJsonObject(); var expected = cases.get(object.get("name").getAsString());
        if (expected == null) throw new AssertionError("Unknown fixture");
        for (String mode : List.of("trusted", "untrusted")) {
          var buf = new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(
            HexFormat.of().parseHex(object.get(mode).getAsString())), registries);
          try {
            var codec = mode.equals("untrusted") ? ItemStack.validatedStreamCodec(ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC) : ItemStack.OPTIONAL_STREAM_CODEC;
            var decoded = codec.decode(buf);
            if (buf.isReadable() || !ItemStack.matches(expected, decoded))
              throw new AssertionError("Elixir stack differs: " + object.get("name") + " " + mode);
          } finally { buf.release(); }
        }
      }
      if (fixtures.size() != cases.size()) throw new AssertionError("Missing fixture");
      System.out.println("PASS: Mojang 26.3 decoded " + cases.size() + " Elixir stack cases in both ordinary and delimited formats.");
    } else throw new IllegalArgumentException("generate/verify expected");
  }
}
