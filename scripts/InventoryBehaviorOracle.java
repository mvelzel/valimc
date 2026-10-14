import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.SimpleContainer;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.player.Abilities;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.entity.EntityEquipment;
import net.minecraft.world.entity.item.ItemEntity;
import net.minecraft.util.Prediction;
import net.minecraft.world.inventory.AbstractContainerMenu;
import net.minecraft.world.inventory.ContainerInput;
import net.minecraft.world.inventory.Slot;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.world.level.GameType;
import sun.misc.Unsafe;

/** Original focused harness invoking Mojang's algorithm, without starting its server. */
public class InventoryBehaviorOracle {
  // This focused branch reads the player inventory reference but ordinary slots
  // never dereference it. Avoid constructing a world or starting a gameplay server.
  private static final class ProbePlayer extends Player {
    private ProbePlayer() { super(null, null); }
    public GameType gameMode() { return GameType.CREATIVE; }
    public ItemEntity drop(ItemStack stack, boolean random, Prediction prediction) {
      if (!stack.isEmpty()) dropped.add(stack.copy());
      return null;
    }
  }
  private static Player player;
  private static final java.util.List<ItemStack> dropped = new java.util.ArrayList<>();

  private static void expectInventory(Inventory inventory, int... counts) {
    for (int i = 0; i < counts.length; i += 2)
      if (inventory.getItem(counts[i]).getCount() != counts[i + 1])
        throw new AssertionError("Wrong returned count at inventory index " + counts[i]);
  }
  private static final class Menu extends AbstractContainerMenu {
    final SimpleContainer contents = new SimpleContainer(46);
    Menu() {
      super(null, 0);
      for (int i = 0; i < 46; i++) addSlot(new Slot(contents, i, 0, 0));
    }
    public boolean stillValid(Player player) { return true; }
    public ItemStack quickMoveStack(Player player, int slot) { return ItemStack.EMPTY; }
    public boolean canTakeItemForPickAll(ItemStack cursor, Slot slot) { return slot.index != 0; }
    void stone(int slot, int count) { contents.setItem(slot, new ItemStack(Items.STONE, count)); }
    void collect(int trigger, int direction) { clicked(trigger, direction, ContainerInput.PICKUP_ALL, player); }
    void expect(int cursor, int... slotCounts) {
      if (getCarried().getCount() != cursor) throw new AssertionError("Wrong cursor count");
      for (int i = 0; i < slotCounts.length; i += 2)
        if (contents.getItem(slotCounts[i]).getCount() != slotCounts[i + 1])
          throw new AssertionError("Wrong count in slot " + slotCounts[i]);
    }
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();
    Bootstrap.bootStrap();
    var throttle = new net.minecraft.util.TickThrottler(20, 1480);
    for (int i=0; i<74; i++) {
      if (!throttle.isUnderThreshold()) throw new AssertionError("Early creative throttle");
      throttle.increment();
    }
    if (throttle.isUnderThreshold()) throw new AssertionError("Accepted threshold 1480");
    throttle.tick();
    if (!throttle.isUnderThreshold()) throw new AssertionError("Rejected 1479");
    throttle.increment();
    for (int i=0; i<19; i++) throttle.tick();
    if (throttle.isUnderThreshold()) throw new AssertionError("Accepted 1499 minus 19 ticks");
    throttle.tick();
    if (!throttle.isUnderThreshold()) throw new AssertionError("Rejected 1499 minus 20 ticks");
    System.out.println("PASS: Mojang creative throttle: 74 initial requests, strict 1480, one-tick readmission and 1499 boundary.");
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var field = Unsafe.class.getDeclaredField("theUnsafe");
    field.setAccessible(true);
    player = (Player)((Unsafe)field.get(null)).allocateInstance(ProbePlayer.class);
    var abilities = new Abilities();
    var abilitiesField = Player.class.getDeclaredField("abilities");
    abilitiesField.setAccessible(true);
    abilitiesField.set(player, abilities);
    var menu = new Menu();
    menu.setCarried(new ItemStack(Items.STONE, 50));
    menu.stone(9, 64); menu.stone(10, 7); menu.stone(11, 9);
    menu.collect(0, 0); menu.expect(64, 9, 64, 10, 0, 11, 2);
    menu = new Menu(); menu.setCarried(new ItemStack(Items.STONE, 50));
    menu.stone(9, 64); menu.stone(10, 3);
    menu.collect(0, 0); menu.expect(64, 9, 53, 10, 0);
    for (int direction : new int[]{0, 1}) {
      menu = new Menu(); menu.setCarried(new ItemStack(Items.STONE, 10));
      menu.stone(9, 30); menu.stone(11, 40);
      menu.collect(0, direction);
      menu.expect(64, 9, direction == 0 ? 0 : 16, 11, direction == 0 ? 16 : 0);
    }
    menu = new Menu(); menu.setCarried(new ItemStack(Items.EGG, 10));
    menu.contents.setItem(9, new ItemStack(Items.EGG, 12));
    menu.collect(0, 0); menu.expect(16, 9, 6);
    menu = new Menu(); menu.setCarried(new ItemStack(Items.STONE, 1));
    menu.stone(9, 7); menu.collect(9, 0); menu.expect(1, 9, 7);
    menu.setCarried(ItemStack.EMPTY); menu.collect(0, 0); menu.expect(0, 9, 7);
    menu = new Menu(); var shiny = new ItemStack(Items.STONE, 5);
    shiny.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE, true);
    menu.setCarried(shiny.copyWithCount(1));
    for (int slot : new int[]{0, 1, 5, 45}) menu.contents.setItem(slot, shiny.copy());
    menu.stone(9, 7); menu.collect(10, 0);
    menu.expect(16, 0, 5, 1, 0, 5, 0, 9, 7, 45, 0);
    if (!Boolean.TRUE.equals(menu.getCarried().get(DataComponents.ENCHANTMENT_GLINT_OVERRIDE)))
      throw new AssertionError("Lost cursor component");
    menu = new Menu(); menu.stone(9, 7);
    menu.clicked(9, 2, ContainerInput.CLONE, player); menu.expect(0, 9, 7);
    abilities.instabuild = true;
    menu.clicked(9, 2, ContainerInput.CLONE, player); menu.expect(64, 9, 7);
    menu.stone(10, 3); menu.clicked(10, 2, ContainerInput.CLONE, player); menu.expect(64, 10, 3);
    menu = new Menu(); menu.setCarried(new ItemStack(Items.STONE, 1));
    menu.clicked(-999, 8, ContainerInput.QUICK_CRAFT, player);
    menu.clicked(9, 9, ContainerInput.QUICK_CRAFT, player);
    menu.clicked(-999, 10, ContainerInput.QUICK_CRAFT, player); menu.expect(1, 9, 0);
    menu = new Menu(); menu.setCarried(shiny.copyWithCount(1));
    menu.contents.setItem(9, shiny.copyWithCount(63));
    menu.clicked(-999, 8, ContainerInput.QUICK_CRAFT, player);
    for (int slot : new int[]{9, 10}) menu.clicked(slot, 9, ContainerInput.QUICK_CRAFT, player);
    menu.clicked(-999, 10, ContainerInput.QUICK_CRAFT, player); menu.expect(0, 9, 64, 10, 64);
    if (!Boolean.TRUE.equals(menu.contents.getItem(10).get(DataComponents.ENCHANTMENT_GLINT_OVERRIDE)))
      throw new AssertionError("Lost fill component");
    menu = new Menu(); menu.setCarried(new ItemStack(Items.STONE, 1));
    menu.stone(9,64); menu.stone(10,64);
    menu.clicked(-999, 8, ContainerInput.QUICK_CRAFT, player);
    for (int slot : new int[]{9, 10}) menu.clicked(slot, 9, ContainerInput.QUICK_CRAFT, player);
    menu.clicked(-999, 10, ContainerInput.QUICK_CRAFT, player); menu.expect(1, 9, 64, 10, 64);
    abilities.instabuild = false;
    menu = new Menu(); menu.setCarried(new ItemStack(Items.EGG, 1));
    menu.clicked(-999, 8, ContainerInput.QUICK_CRAFT, player);
    for (int slot : new int[]{9, 10}) menu.clicked(slot, 9, ContainerInput.QUICK_CRAFT, player);
    menu.clicked(-999, 10, ContainerInput.QUICK_CRAFT, player); menu.expect(1, 9, 0, 10, 0);
    abilities.instabuild = true;
    menu = new Menu(); menu.setCarried(new ItemStack(Items.STONE, 1));
    menu.clicked(-999, 8, ContainerInput.QUICK_CRAFT, player);
    abilities.instabuild = false;
    for (int slot : new int[]{9, 10}) menu.clicked(slot, 9, ContainerInput.QUICK_CRAFT, player);
    menu.clicked(-999, 10, ContainerInput.QUICK_CRAFT, player); menu.expect(0, 9, 64, 10, 64);
    System.out.println("PASS: Mojang 26.3 collect/creative behavior: order, caps, triggers, components, output exclusion, clone/fill permissions and single-target fill no-op.");

    var inventory = new Inventory(player, new EntityEquipment());
    inventory.setSelectedSlot(2);
    for (int slot : new int[]{2, 40, 0, 9}) inventory.setItem(slot, shiny.copyWithCount(60));
    var returning = shiny.copyWithCount(17);
    inventory.placeItemBackInInventory(returning, false, Prediction.SERVER_ONLY);
    expectInventory(inventory, 2,64, 40,64, 0,64, 9,64, 1,1);
    if (!returning.isEmpty() || !ItemStack.matches(inventory.getItem(1), shiny.copyWithCount(1)))
      throw new AssertionError("Lost returned components or cursor");
    inventory = new Inventory(player, new EntityEquipment());
    inventory.setSelectedSlot(7);
    inventory.setItem(0, new ItemStack(Items.STONE, 7));
    inventory.setItem(40, new ItemStack(Items.STONE, 8));
    inventory.placeItemBackInInventory(shiny.copyWithCount(9), false, Prediction.SERVER_ONLY);
    expectInventory(inventory, 0,7, 40,8, 1,9, 7,0);
    inventory = new Inventory(player, new EntityEquipment());
    inventory.setItem(0, new ItemStack(Items.EGG,15));
    inventory.setItem(40, new ItemStack(Items.EGG,14));
    inventory.placeItemBackInInventory(new ItemStack(Items.EGG,16), false, Prediction.SERVER_ONLY);
    expectInventory(inventory, 0,16, 40,16, 1,13);
    for (boolean infinite : new boolean[]{false, true}) {
      abilities.instabuild = infinite;
      inventory = new Inventory(player, new EntityEquipment());
      for (int i = 0; i < 36; i++) inventory.setItem(i, shiny.copyWithCount(64));
      inventory.setItem(0, shiny.copyWithCount(63));
      dropped.clear();
      inventory.placeItemBackInInventory(shiny.copyWithCount(10), false, Prediction.SERVER_ONLY);
      expectInventory(inventory, 0,64, 40,0);
      if (dropped.size() != 1 || !ItemStack.matches(dropped.getFirst(), shiny.copyWithCount(9)))
        throw new AssertionError("Wrong return overflow effect");
    }
    inventory = new Inventory(player, new EntityEquipment());
    var sword = new ItemStack(Items.IRON_SWORD);
    sword.set(DataComponents.DAMAGE,17);
    inventory.setItem(0, sword.copy());
    inventory.placeItemBackInInventory(sword.copy(), false, Prediction.SERVER_ONLY);
    expectInventory(inventory, 0,1, 1,1);
    if (!ItemStack.matches(inventory.getItem(1), sword)) throw new AssertionError("Lost returned damage");
    System.out.println("PASS: Mojang 26.3 inventory return: selected/offhand/storage order, caps, component identity, nonstackable damage and overflow in both permission modes. Drop effects captured; no item entity simulated.");

    for (boolean infinite : new boolean[]{false, true}) {
      abilities.instabuild = infinite;
      inventory = new Inventory(player, new EntityEquipment());
      inventory.setSelectedSlot(2);
      for (int i=0; i<36; i++) inventory.setItem(i, shiny.copyWithCount(64));
      inventory.setItem(2, shiny.copyWithCount(63));
      inventory.setItem(40, shiny.copyWithCount(64));
      dropped.clear();
      var returned = new ItemStack[]{shiny.copyWithCount(10), new ItemStack(Items.EGG,3),
        new ItemStack(Items.DIRT,4), sword.copy(), new ItemStack(Items.DIAMOND)};
      for (var stack : returned) inventory.placeItemBackInInventory(stack.copy(),false,Prediction.SERVER_ONLY);
      expectInventory(inventory,2,64,40,64);
      var expected = new ItemStack[]{shiny.copyWithCount(9),returned[1],returned[2],returned[3],returned[4]};
      if (dropped.size()!=5) throw new AssertionError("Wrong close remainder count");
      for (int i=0; i<5; i++) if (!ItemStack.matches(dropped.get(i),expected[i]))
        throw new AssertionError("Wrong ordered close remainder/patch at " + i);
      for (int i=0; i<36; i++) if (!ItemStack.matches(inventory.getItem(i),shiny.copyWithCount(64)))
        throw new AssertionError("Partial return changed full storage");
    }
    System.out.println("PASS: Mojang 26.3 ordered cursor/grid return sequence: partial merge and five exact overflow stacks in both permission modes; effects captured without entity simulation.");

    for (boolean infinite : new boolean[]{false, true}) {
      abilities.instabuild = infinite;
      inventory = new Inventory(player, new EntityEquipment());
      inventory.setSelectedSlot(8);
      inventory.setItem(8, shiny.copyWithCount(7));
      inventory.setItem(40, new ItemStack(Items.EGG, 3));
      var one = inventory.removeFromSelected(false);
      if (!ItemStack.matches(one, shiny.copyWithCount(1))) throw new AssertionError("Wrong single drop");
      expectInventory(inventory, 8,6, 40,3);
      var all = inventory.removeFromSelected(true);
      if (!ItemStack.matches(all, shiny.copyWithCount(6))) throw new AssertionError("Wrong whole-stack drop");
      expectInventory(inventory, 8,0, 40,3);
      if (!inventory.removeFromSelected(false).isEmpty() || !inventory.removeFromSelected(true).isEmpty())
        throw new AssertionError("Empty selected stack dropped an item");
    }
    System.out.println("PASS: Mojang 26.3 selected-hand single/all/empty drop counts and component identity in both permission modes; item physics remains separate.");

    for (boolean infinite : new boolean[]{false, true}) {
      abilities.instabuild = infinite;
      for (int button : new int[]{0, 1, 2, -1, -128, 127}) {
        menu = new Menu(); menu.contents.setItem(9, shiny.copyWithCount(7)); dropped.clear();
        menu.clicked(9, button, ContainerInput.THROW, player);
        int count = button == 0 ? 1 : 7;
        menu.expect(0, 9, 7-count);
        if (dropped.size() != 1 || !ItemStack.matches(dropped.getFirst(), shiny.copyWithCount(count)))
          throw new AssertionError("Wrong THROW count/patch for button " + button);
      }
      for (var type : new ContainerInput[]{ContainerInput.PICKUP, ContainerInput.QUICK_MOVE}) {
        for (int button : new int[]{0, 1}) {
          menu = new Menu(); menu.setCarried(shiny.copyWithCount(7)); dropped.clear();
          menu.clicked(-999, button, type, player);
          int count = button == 0 ? 7 : 1;
          menu.expect(7-count);
          if (dropped.size() != 1 || !ItemStack.matches(dropped.getFirst(), shiny.copyWithCount(count)))
            throw new AssertionError("Wrong outside cursor count/patch");
        }
      }
      menu = new Menu(); menu.setCarried(shiny.copyWithCount(7)); menu.stone(9, 8); dropped.clear();
      menu.clicked(9, 1, ContainerInput.THROW, player); menu.expect(7, 9, 8);
      menu.clicked(-999, 2, ContainerInput.PICKUP, player); menu.expect(7, 9, 8);
      if (!dropped.isEmpty()) throw new AssertionError("Cursor blocks THROW; outside button 2 is a no-op");
      menu.setCarried(ItemStack.EMPTY);
      for (int slot : new int[]{-999, -1, 0, 10}) menu.clicked(slot, 1, ContainerInput.THROW, player);
      menu.clicked(-999, 0, ContainerInput.PICKUP, player);
      if (!dropped.isEmpty()) throw new AssertionError("Empty/negative drop created an item");
      menu = new Menu(); menu.setCarried(shiny.copyWithCount(7)); dropped.clear();
      menu.clicked(-999, 0, ContainerInput.QUICK_CRAFT, player);
      menu.clicked(-999, 0, ContainerInput.PICKUP, player); menu.expect(7);
      if (!dropped.isEmpty()) throw new AssertionError("Interrupting quick craft dropped the cursor");
      menu.clicked(-999, 0, ContainerInput.PICKUP, player); menu.expect(0);
      if (dropped.size()!=1 || !ItemStack.matches(dropped.getFirst(),shiny.copyWithCount(7)))
        throw new AssertionError("Retry after quick-craft reset did not drop");
    }
    System.out.println("PASS: Mojang 26.3 ordinary menu THROW/outside PICKUP+QUICK_MOVE counts, nonstandard buttons, patches, empty/cursor/negative no-ops and quick-craft interruption.");
  }
}
