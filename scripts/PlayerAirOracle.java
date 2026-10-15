import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.Holder;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import com.mojang.serialization.Lifecycle;
import net.minecraft.server.Bootstrap;
import net.minecraft.util.RandomSource;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;

/** Original air primitive observations; baseTick world/effect ordering is a separate reference. */
public class PlayerAirOracle {
  private static class Probe extends Player {
    AttributeInstance oxygen; int air; double draw;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public AttributeInstance getAttribute(Holder<Attribute> key){
      if(key!=Attributes.OXYGEN_BONUS)throw new AssertionError(key);return oxygen;
    }
    public int getAirSupply(){return air;}
    int decrease(int value){return decreaseAirSupply(value);}
    int increase(int value){return increaseAirSupply(value);}
    boolean drowning(){return shouldTakeDrowningDamage();}
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");unsafeField.setAccessible(true);
    var unsafe=(sun.misc.Unsafe)unsafeField.get(null);var p=(Probe)unsafe.allocateInstance(Probe.class);
    p.oxygen=new AttributeInstance(Attributes.OXYGEN_BONUS,a->{});
    var random=Entity.class.getDeclaredField("random");random.setAccessible(true);
    random.set(p,Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},(proxy,method,a)->{
      if(!method.getName().equals("nextDouble"))throw new AssertionError(method);return p.draw;
    }));
    var cases=new JsonArray();
    for(int air:new int[]{-20,-19,-1,0,1,2,296,299,300})for(double bonus:new double[]{0,.1,1,3,16,1024}){
      p.air=air;p.oxygen.setBaseValue(bonus);double threshold=1.0/(bonus+1);
      for(double draw:new double[]{0,Math.nextDown(threshold),threshold,Math.min(Math.nextUp(threshold),Math.nextDown(1.0)),Math.nextDown(1.0)}){
        if(draw<0||draw>=1)continue;p.draw=draw;var c=new JsonObject();c.addProperty("air",air);c.addProperty("oxygen",bonus);c.addProperty("draw",draw);
        c.addProperty("decrease",p.decrease(air));c.addProperty("increase",p.increase(air));c.addProperty("drowning",p.drowning());cases.add(c);
      }
    }
    var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(patch->patch.apply());
    var source=lookup.lookupOrThrow(Registries.ENCHANTMENT);var enchantments=new MappedRegistry<Enchantment>(Registries.ENCHANTMENT,Lifecycle.stable());
    for(var id:source.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())enchantments.register(id,source.getOrThrow(id).value(),RegistrationInfo.BUILT_IN);
    enchantments.freeze();var equipment=new JsonArray();
    for(var enchantment:enchantments.entrySet())for(int level:new int[]{0,1,3,255})for(boolean stored:new boolean[]{false,true})
      for(var slot:List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET,EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND)){
        var stack=new ItemStack(Items.STONE);var mutable=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);
        mutable.set(enchantments.getOrThrow(enchantment.getKey()),level);
        stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,mutable.toImmutable());
        var oxygen=new AttributeInstance(Attributes.OXYGEN_BONUS,a->{});
        EnchantmentHelper.forEachModifier(stack,slot,(attribute,modifier)->{if(attribute==Attributes.OXYGEN_BONUS)oxygen.addTransientModifier(modifier);});
        var c=new JsonObject();c.addProperty("enchantment",enchantment.getKey().identifier().toString());c.addProperty("level",level);c.addProperty("stored",stored);
        c.addProperty("slot",switch(slot){case HEAD->5;case CHEST->6;case LEGS->7;case FEET->8;case MAINHAND->36;case OFFHAND->45;default->throw new AssertionError(slot);});
        c.addProperty("oxygen",oxygen.getValue());equipment.add(c);
      }
    for(var item:BuiltInRegistries.ITEM)for(var slot:EquipmentSlot.values())new ItemStack(item).forEachModifier(slot,(attribute,modifier)->{
      if(attribute==Attributes.OXYGEN_BONUS&&modifier.amount()!=0)throw new AssertionError("Nonzero default oxygen modifier");
    });
    var result=new JsonObject();result.addProperty("maximum",p.getMaxAirSupply());result.add("cases",cases);result.add("equipment",equipment);
    if(p.getMaxAirSupply()!=300)throw new AssertionError("Changed native maximum");
    Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+cases.size()+" actual native air primitives and "+equipment.size()+" oxygen enchantment/slot cases; default maximum="+p.getMaxAirSupply()+"; world/effect composition excluded.");
  }
}
