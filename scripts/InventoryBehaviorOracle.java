import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.SimpleContainer;
import net.minecraft.world.entity.player.Player;
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
  }
  private static Player player;
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
    var lookup = VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var field = Unsafe.class.getDeclaredField("theUnsafe");
    field.setAccessible(true);
    player = (Player)((Unsafe)field.get(null)).allocateInstance(ProbePlayer.class);
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
    System.out.println("PASS: Mojang 26.3 collect behavior: two passes, both directions, caps, triggers, components and output exclusion.");
  }
}
