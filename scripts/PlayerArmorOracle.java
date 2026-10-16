import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;

/** Native equipped armor/toughness/burning-time facts and attribute-map observations. */
public class PlayerArmorOracle {
  static final EquipmentSlot[] SLOTS={EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET,EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND};
  static final int[] MENU={5,6,7,8,36,45};
  static AttributeSupplier supplier;
  static double[] defaults(ItemStack stack,EquipmentSlot slot){
    var result=new double[2];
    stack.forEachModifier(slot,(attribute,modifier)->{
      int index=attribute.equals(Attributes.ARMOR)?0:attribute.equals(Attributes.ARMOR_TOUGHNESS)?1:-1;
      if(index>=0){
        if(modifier.operation()!=AttributeModifier.Operation.ADD_VALUE)throw new AssertionError("Non-additive stock armor");
        result[index]+=modifier.amount();
      }
      if(attribute.equals(Attributes.BURNING_TIME))throw new AssertionError("Stock burning-time modifier");
    });return result;
  }
  record Worn(int slot,ItemStack stack,JsonObject description){}
  static Worn worn(int index,Item item,boolean removed,net.minecraft.core.Holder<Enchantment> enchant,int level,boolean stored){
    var stack=new ItemStack(item);if(removed)stack.remove(DataComponents.ATTRIBUTE_MODIFIERS);
    if(enchant!=null){var mutable=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);mutable.set(enchant,level);
      stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,mutable.toImmutable());}
    var d=new JsonObject();d.addProperty("slot",MENU[index]);d.addProperty("item_id",BuiltInRegistries.ITEM.getId(item));d.addProperty("removed",removed);
    d.addProperty("fire",enchant==null||stored?0:level);d.addProperty("stored_fire",stored?level:0);
    return new Worn(index,stack,d);
  }
  static void observe(JsonArray rows,List<Worn> gear){
    var attributes=new AttributeMap(supplier);var items=new JsonArray();
    for(var worn:gear){items.add(worn.description);worn.stack.forEachModifier(SLOTS[worn.slot],(attribute,modifier)->{
      if(attribute.equals(Attributes.ARMOR)||attribute.equals(Attributes.ARMOR_TOUGHNESS)||attribute.equals(Attributes.BURNING_TIME))
        attributes.getInstance(attribute).addOrUpdateTransientModifier(modifier);
    });}
    var row=new JsonObject();row.add("gear",items);row.addProperty("armor",(int)Math.floor(attributes.getValue(Attributes.ARMOR)));
    row.addProperty("toughness",(double)(float)attributes.getValue(Attributes.ARMOR_TOUGHNESS));row.addProperty("burning_time",attributes.getValue(Attributes.BURNING_TIME));rows.add(row);
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());supplier=Player.createAttributes().build();
    var fire=lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(Enchantments.FIRE_PROTECTION);
    var defaults=new JsonObject();var candidates=new ArrayList<List<Item>>();for(int i=0;i<4;i++)candidates.add(new ArrayList<>());
    var rows=new JsonArray();
    for(var item:BuiltInRegistries.ITEM){
      if(item==Items.AIR)continue;var slots=new JsonObject();
      for(int i=0;i<SLOTS.length;i++){
        var values=defaults(new ItemStack(item),SLOTS[i]);
        if(values[0]!=0||values[1]!=0){slots.add(Integer.toString(MENU[i]),new Gson().toJsonTree(values));if(i<4)candidates.get(i).add(item);}
        for(boolean removed:new boolean[]{false,true})observe(rows,List.of(worn(i,item,removed,null,0,false)));
      }
      if(!slots.isEmpty())defaults.add(Integer.toString(BuiltInRegistries.ITEM.getId(item)),slots);
    }
    var coefficients=new JsonArray();
    for(int level=0;level<=255;level++){
      double expected=Double.NaN;
      for(int i=0;i<SLOTS.length;i++){
        var stack=new ItemStack(Items.STONE);stack.enchant(fire,level);double[] delta={0};
        EnchantmentHelper.forEachModifier(stack,SLOTS[i],(attribute,modifier)->{
          if(attribute.equals(Attributes.BURNING_TIME)){
            if(modifier.operation()!=AttributeModifier.Operation.ADD_MULTIPLIED_BASE)throw new AssertionError("Unexpected burning operation");delta[0]+=modifier.amount();
          }
          if(attribute.equals(Attributes.ARMOR)||attribute.equals(Attributes.ARMOR_TOUGHNESS))throw new AssertionError("Fire protection changes armor");
        });
        if(i==0)expected=delta[0];if((i<4&&delta[0]!=expected)||(i>=4&&delta[0]!=0))throw new AssertionError("Burning slot mismatch");
      }
      coefficients.add(expected);
    }
    for(int i=0;i<SLOTS.length;i++)for(int level:new int[]{0,1,4,255})for(boolean removed:new boolean[]{false,true})for(boolean stored:new boolean[]{false,true})
      observe(rows,List.of(worn(i,Items.STONE,removed,fire,level,stored)));
    int otherEnchantments=0;
    for(var key:lookup.lookupOrThrow(Registries.ENCHANTMENT).listElementIds().toList()){
      var enchant=lookup.lookupOrThrow(Registries.ENCHANTMENT).getOrThrow(key);if(enchant.equals(fire))continue;
      for(int level:new int[]{1,4,255})for(var slot:SLOTS){
        var stack=new ItemStack(Items.STONE);stack.enchant(enchant,level);
        EnchantmentHelper.forEachModifier(stack,slot,(attribute,modifier)->{
          if(attribute.equals(Attributes.ARMOR)||attribute.equals(Attributes.ARMOR_TOUGHNESS)||attribute.equals(Attributes.BURNING_TIME))
            throw new AssertionError("Other enchantment modifies defensive attributes: "+key);
        });otherEnchantments++;
      }
    }
    var random=new Random(26_3);
    for(int sample=0;sample<256;sample++){
      var gear=new ArrayList<Worn>();for(int i=0;i<4;i++){
        var list=candidates.get(i);gear.add(worn(i,list.get(random.nextInt(list.size())),random.nextInt(4)==0,fire,random.nextInt(6),false));
      }observe(rows,gear);
    }
    var facts=new JsonObject();facts.add("defaults",defaults);facts.add("fire_protection",coefficients);
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(facts)+"\n");
    Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+defaults.size()+" stock armor items,256 native fire-protection coefficients, "+rows.size()+" actual equipped attribute-map cases, "+otherEnchantments+" other-enchantment exclusions; wrong slots/removals/stored/mixed armor included, live health/wear excluded.");
  }
}
