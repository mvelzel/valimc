import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.Direction;
import net.minecraft.core.BlockPos;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.dispenser.*;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.ProjectileItem;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.block.DispenserBlock;
import net.minecraft.world.phys.Vec3;

/**
 * What a dispenser does with each item (VMC-049a), from pinned 26.3: `facts OUT` asks
 * `DispenserBlock.getDispenseMethod` for every item's default stack and writes, for each item
 * whose behaviour is not the plain drop (`DefaultDispenseItemBehavior`): `equipment` (worn by a
 * living entity in front, `EquipmentDispenseItemBehavior`, with whether its `Equippable` is
 * dispensable), `projectile` (`ProjectileDispenseBehavior`: the entity it shoots, its power,
 * spread and level event, and where it starts from the dispenser's centre for each facing), or
 * the behaviour's class (registered ones, anonymous included, which ValiMC names by item).
 *
 * Usage: DispenserOracle facts OUT
 */
public class DispenserOracle {
  public static void main(String[] args)throws Exception{
    if(!args[0].equals("facts"))throw new IllegalArgumentException(args[0]);
    var level=HopperOracle.level();
    var method=DispenserBlock.class.getDeclaredMethod("getDispenseMethod",net.minecraft.world.level.Level.class,ItemStack.class);method.setAccessible(true);
    var defaultField=DispenserBlock.class.getDeclaredField("DEFAULT_BEHAVIOR");defaultField.setAccessible(true);
    var plain=defaultField.get(null);
    var configField=ProjectileDispenseBehavior.class.getDeclaredField("dispenseConfig");configField.setAccessible(true);
    var itemField=ProjectileDispenseBehavior.class.getDeclaredField("projectileItem");itemField.setAccessible(true);
    var items=new JsonObject();var counts=new TreeMap<String,Integer>();
    for(var item:BuiltInRegistries.ITEM){
      var stack=new ItemStack(item);if(stack.isEmpty())continue;
      var behaviour=method.invoke(Blocks.DISPENSER,level,stack);
      if(behaviour==plain)continue;
      var entry=new JsonObject();String kind;
      if(behaviour==EquipmentDispenseItemBehavior.INSTANCE){
        kind="equipment";entry.addProperty("dispensable",stack.get(DataComponents.EQUIPPABLE).dispensable());
      }else if(behaviour instanceof ProjectileDispenseBehavior projectile){
        kind="projectile";
        var config=(ProjectileItem.DispenseConfig)configField.get(projectile);var projectileItem=(ProjectileItem)itemField.get(projectile);
        var shot=projectileItem.asProjectile(level,Vec3.ZERO,stack,Direction.NORTH);
        entry.addProperty("entity",BuiltInRegistries.ENTITY_TYPE.getKey(shot.getType()).toString());
        entry.addProperty("power",Float.floatToIntBits(config.power()));
        entry.addProperty("uncertainty",Float.floatToIntBits(config.uncertainty()));
        entry.addProperty("event",config.overrideDispenseEvent().orElse(1002));
        var offsets=new JsonArray();
        for(var facing:Direction.values()){
          var source=new BlockSource(level,BlockPos.ZERO,Blocks.DISPENSER.defaultBlockState().setValue(DispenserBlock.FACING,facing),null);
          var at=config.positionFunction().getDispensePosition(source,facing);
          var row=new JsonArray();for(double v:new double[]{at.x()-0.5,at.y()-0.5,at.z()-0.5})row.add(v);offsets.add(row);
        }
        entry.add("offsets",offsets);
      }else{
        kind="registered";entry.addProperty("class",behaviour.getClass().getName());
      }
      var ordered=new JsonObject();ordered.addProperty("kind",kind);for(var e:entry.entrySet())ordered.add(e.getKey(),e.getValue());
      items.add(BuiltInRegistries.ITEM.getKey(item).getPath(),ordered);counts.merge(kind,1,Integer::sum);
    }
    var result=new JsonObject();result.add("items",items);
    Files.writeString(Path.of(args[1]),new GsonBuilder().disableHtmlEscaping().create().toJson(result)+"\n");
    System.out.println("PASS: dispense facts for "+items.size()+" items "+counts);
  }
}
