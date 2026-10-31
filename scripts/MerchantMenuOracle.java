import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.sounds.SoundEvent;
import net.minecraft.sounds.SoundEvents;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.trading.*;

/**
 * The merchant menu (VMC-044b2): vanilla's `MerchantMenu` over a merchant
 * whose `notifyTrade` counts the use (the villager's experience and orb are
 * the owner's, checked by the trade draws and tests). Each scenario starts
 * from an inventory and offers (with uses, demand and special prices) and
 * runs clicks (`[input ordinal, slot, button]`) and trade selections
 * (`[-1, index, 0]`: the hint, then `tryMoveItems`); after every step it
 * records the menu's 39 slots, the cursor, each offer's uses and the drops
 * so far.
 */
public class MerchantMenuOracle extends PlayerCraftingOracle {
  static class Trader implements Merchant {
    final MerchantOffers offers = new MerchantOffers();
    Player player;
    public void setTradingPlayer(Player p) { player = p; }
    public Player getTradingPlayer() { return player; }
    public MerchantOffers getOffers() { return offers; }
    public void overrideOffers(MerchantOffers o) {}
    public void notifyTrade(MerchantOffer offer) { offer.increaseUses(); }
    public void notifyTradeUpdated(ItemStack stack) {}
    public int getVillagerXp() { return 0; }
    public void overrideXp(int xp) {}
    public boolean showProgressBar() { return true; }
    public SoundEvent getNotifyTradeSound() { return SoundEvents.VILLAGER_YES; }
    // The trade sound plays on the client only; the menu then casts nothing.
    public boolean isClientSide() { return true; }
    public boolean stillValid(Player p) { return true; }
  }

  static MerchantOffer offer(ItemCost a, ItemCost b, ItemStack result, int uses, int max, int demand, float multiplier, int special) {
    var o = new MerchantOffer(a, Optional.ofNullable(b), result, uses, max, 1, multiplier, demand);
    o.setSpecialPriceDiff(special);
    return o;
  }

  static JsonElement stack(ItemStack s) { return TableMenuOracle.stack(s); }

  record Scenario(String name, boolean creative, Map<Integer, ItemStack> inventory, List<MerchantOffer> offers, int[][] steps) {}

  static int[] click(ContainerInput input, int slot, int button) { return new int[]{input.ordinal(), slot, button}; }
  static int[] select(int index) { return new int[]{-1, index, 0}; }
  static ItemStack items(Item item, int count) { return new ItemStack(item, count); }

  static List<MerchantOffer> standard() {
    return List.of(
        offer(new ItemCost(Items.PAPER, 24), null, items(Items.EMERALD, 1), 0, 16, 0, 0.05F, 0),
        offer(new ItemCost(Items.EMERALD, 5), new ItemCost(Items.BOOK, 1), items(Items.LANTERN, 1), 0, 12, 0, 0.2F, 0),
        offer(new ItemCost(Items.EMERALD, 3), null, items(Items.BREAD, 6), 4, 4, 0, 0.05F, 0),
        offer(new ItemCost(Items.EMERALD, 3), null, items(Items.ARROW, 16), 0, 2, 4, 0.2F, -1),
        offer(new ItemCost(Items.EMERALD, 2), null, items(Items.IRON_SWORD, 1), 0, 12, 0, 0.2F, 0));
  }

  static List<Scenario> scenarios() {
    var all = new ArrayList<Scenario>();
    var rich = new HashMap<Integer, ItemStack>();
    rich.put(0, items(Items.PAPER, 64)); rich.put(1, items(Items.EMERALD, 20)); rich.put(2, items(Items.BOOK, 5));
    rich.put(9, items(Items.PAPER, 30)); rich.put(10, items(Items.EMERALD, 64)); rich.put(20, items(Items.DIRT, 64));
    var P = ContainerInput.PICKUP; var Q = ContainerInput.QUICK_MOVE; var S = ContainerInput.SWAP;
    var C = ContainerInput.CLONE; var T = ContainerInput.THROW; var D = ContainerInput.QUICK_CRAFT; var A = ContainerInput.PICKUP_ALL;
    all.add(new Scenario("select and take", false, rich, standard(), new int[][]{
        select(0), click(P, 2, 0), click(P, 2, 0), click(P, 2, 1), click(P, 30, 0), click(P, 2, 0), click(Q, 2, 0)}));
    all.add(new Scenario("two costs", false, rich, standard(), new int[][]{
        select(1), click(P, 2, 0), click(P, 0, 0), click(P, 1, 0), click(P, 0, 0), click(P, 2, 0), click(Q, 2, 0), select(3), click(Q, 2, 1)}));
    all.add(new Scenario("payments by hand", false, rich, standard(), new int[][]{
        click(P, 31, 0), click(P, 1, 0), click(P, 2, 0), click(P, 32, 0), click(P, 0, 1), click(P, 2, 0),
        click(P, 1, 0), click(P, 0, 0), click(Q, 0, 0), click(Q, 1, 0), click(Q, 30, 0), click(Q, 3, 0)}));
    all.add(new Scenario("out of stock and demand", false, rich, standard(), new int[][]{
        select(2), click(P, 2, 0), select(3), click(P, 2, 0), select(4), click(P, 2, 0), select(4), select(9)}));
    all.add(new Scenario("swap, throw and clone", true, rich, standard(), new int[][]{
        select(0), click(S, 2, 8), click(S, 2, 0), click(T, 2, 0), click(C, 2, 0), click(P, -999, 0), click(T, 2, 1), click(S, 2, 40)}));
    var full = new HashMap<Integer, ItemStack>();
    for (int i = 0; i < 36; i++) full.put(i, items(Items.STONE, 64));
    full.put(4, items(Items.EMERALD, 64)); full.put(5, items(Items.EMERALD, 64)); full.put(30, items(Items.ARROW, 60));
    all.add(new Scenario("full inventory", false, full, standard(), new int[][]{
        select(3), click(Q, 2, 0), click(Q, 2, 0), select(0), click(P, 34, 0), click(P, 0, 0), click(D, -999, 0), click(D, 0, 1), click(D, 1, 1), click(D, -999, 2), click(A, 3, 0)}));
    var hint = new HashMap<Integer, ItemStack>(rich);
    all.add(new Scenario("hint and first match", false, hint, List.of(
        offer(new ItemCost(Items.EMERALD, 1), null, items(Items.STICK, 1), 0, 12, 0, 0.05F, 0),
        offer(new ItemCost(Items.EMERALD, 1), null, items(Items.TORCH, 4), 0, 12, 0, 0.05F, 0),
        offer(new ItemCost(Items.EMERALD, 1), null, items(Items.STICK, 2), 12, 12, 0, 0.05F, 0)), new int[][]{
        select(1), click(P, 2, 0), select(0), click(Q, 2, 0), select(2), click(P, 2, 0), select(1), click(T, 2, 1)}));
    return all;
  }

  static JsonArray row(MerchantMenu menu, Trader trader, List<ItemStack> dropped) {
    var r = new JsonArray();
    var slots = new JsonArray();
    for (int i = 0; i < 39; i++) slots.add(stack(menu.getSlot(i).getItem()));
    r.add(slots);
    r.add(stack(menu.getCarried()));
    var uses = new JsonArray();
    for (var o : trader.offers) uses.add(o.getUses());
    r.add(uses);
    var drops = new JsonArray();
    for (var d : dropped) drops.add(stack(d));
    r.add(drops);
    return r;
  }

  static JsonObject run(Scenario s, sun.misc.Unsafe unsafe) throws Exception {
    var world = (MenuWorld) unsafe.allocateInstance(MenuWorld.class);
    var owner = (MenuPlayer) unsafe.allocateInstance(MenuPlayer.class);
    owner.world = world; owner.dropped = new ArrayList<>();
    var abilities = new Abilities(); abilities.instabuild = s.creative;
    var field = Player.class.getDeclaredField("abilities"); field.setAccessible(true); field.set(owner, abilities);
    var inventory = new Inventory(owner, new net.minecraft.world.entity.EntityEquipment());
    field = Player.class.getDeclaredField("inventory"); field.setAccessible(true); field.set(owner, inventory);
    for (var e : s.inventory.entrySet()) inventory.setItem(e.getKey(), e.getValue().copy());
    var trader = new Trader();
    for (var o : s.offers) trader.offers.add(o.copy());
    trader.setTradingPlayer(owner);
    var menu = new MerchantMenu(1, inventory, trader);
    var out = new JsonObject();
    out.addProperty("name", s.name);
    out.addProperty("creative", s.creative);
    var start = new JsonArray();
    for (int i = 0; i < 36; i++) start.add(stack(inventory.getItem(i)));
    out.add("inventory", start);
    var offers = new JsonArray();
    for (var o : s.offers) {
      var j = new JsonArray();
      j.add(stack(o.getBaseCostA())); j.add(stack(o.getCostB())); j.add(stack(o.getResult()));
      j.add(o.getUses()); j.add(o.getMaxUses()); j.add(o.getDemand()); j.add(o.getPriceMultiplier()); j.add(o.getSpecialPriceDiff());
      offers.add(j);
    }
    out.add("offers", offers);
    var steps = new JsonArray();
    for (var step : s.steps) {
      if (step[0] < 0) { menu.setSelectionHint(step[1]); menu.tryMoveItems(step[1]); }
      else menu.clicked(step[1], step[2], ContainerInput.values()[step[0]], owner);
      var r = new JsonArray();
      r.add(new Gson().toJsonTree(step));
      r.add(row(menu, trader, owner.dropped));
      steps.add(r);
    }
    out.add("steps", steps);
    return out;
  }

  /** The offers packet and the screen's open packet, as vanilla's codecs write them. */
  static JsonObject packets() {
    var access = net.minecraft.core.RegistryAccess.fromRegistryOfRegistries(net.minecraft.core.registries.BuiltInRegistries.REGISTRY);
    var offers = new MerchantOffers();
    standard().forEach(o -> offers.add(o.copy()));
    var water = net.minecraft.world.item.alchemy.PotionContents.EMPTY.withPotion(net.minecraft.world.item.alchemy.Potions.WATER);
    offers.add(offer(new ItemCost(Items.POTION, 1).withComponents(b -> b.expect(net.minecraft.core.component.DataComponents.POTION_CONTENTS, water)),
        null, items(Items.EMERALD, 1), 3, 12, 2, 0.05F, -1));
    var buffer = new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.buffer(), access);
    net.minecraft.network.protocol.game.ClientboundMerchantOffersPacket.STREAM_CODEC.encode(buffer,
        new net.minecraft.network.protocol.game.ClientboundMerchantOffersPacket(7, offers, 3, 25, true, true));
    var open = new net.minecraft.network.RegistryFriendlyByteBuf(io.netty.buffer.Unpooled.buffer(), access);
    net.minecraft.network.protocol.game.ClientboundOpenScreenPacket.STREAM_CODEC.encode(open,
        new net.minecraft.network.protocol.game.ClientboundOpenScreenPacket(7, MenuType.MERCHANT,
            net.minecraft.network.chat.Component.translatable("entity.minecraft.villager.librarian")));
    var out = new JsonObject();
    out.addProperty("offers", io.netty.buffer.ByteBufUtil.hexDump(buffer));
    out.addProperty("open", io.netty.buffer.ByteBufUtil.hexDump(open));
    return out;
  }

  public static void main(String[] args) throws Exception {
    MiningToolOracle.initialize();
    var field = sun.misc.Unsafe.class.getDeclaredField("theUnsafe"); field.setAccessible(true);
    var unsafe = (sun.misc.Unsafe) field.get(null);
    var cases = new JsonArray();
    for (var s : scenarios()) cases.add(run(s, unsafe));
    var out = new JsonObject();
    out.add("cases", cases);
    out.add("packets", packets());
    Files.writeString(Path.of(args[0]), new GsonBuilder().disableHtmlEscaping().create().toJson(out) + "\n");
  }
}
