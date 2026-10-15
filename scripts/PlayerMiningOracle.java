import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.tags.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.material.Fluid;

/** Actual Player mining composition without status effects; equipment modifiers applied explicitly. */
public class PlayerMiningOracle {
  private static List<Holder<Attribute>> ATTRIBUTES;
  private static class Probe extends Player {
    boolean water,ground;
    Map<Holder<Attribute>,AttributeInstance> attributes;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public double getAttributeValue(Holder<Attribute> key){return getAttribute(key).getValue();}
    public AttributeInstance getAttribute(Holder<Attribute> key){return Objects.requireNonNull(attributes.get(key));}
    public boolean isEyeInFluid(TagKey<Fluid> tag){if(tag!=FluidTags.WATER)throw new AssertionError(tag);return water;}
    public boolean onGround(){return ground;}
    public boolean hasEffect(Holder<MobEffect> type){return false;}
    public MobEffectInstance getEffect(Holder<MobEffect> type){return null;}
    void reset(){attributes=new HashMap<>();for(var key:ATTRIBUTES)attributes.put(key,new AttributeInstance(key,a->{}));}
  }
  private static String bits(float value){return String.format(Locale.ROOT,"%08x",Float.floatToIntBits(value));}
  private static int[] levels(String name){return name.equals("minecraft:efficiency")||name.equals("minecraft:aqua_affinity")?java.util.stream.IntStream.rangeClosed(0,255).toArray():new int[]{0,1,3,255};}
  private static JsonObject attributes(Probe player){var row=new JsonObject();for(var key:ATTRIBUTES)row.addProperty(key.unwrapKey().orElseThrow().identifier().getPath(),player.getAttributeValue(key));return row;}
  public static void main(String[] args)throws Exception{
    var lookup=MiningToolOracle.initialize();
    ATTRIBUTES=List.of(Attributes.MINING_EFFICIENCY,Attributes.BLOCK_BREAK_SPEED,Attributes.SUBMERGED_MINING_SPEED);
    var unsafeField=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");unsafeField.setAccessible(true);
    var p=(Probe)((sun.misc.Unsafe)unsafeField.get(null)).allocateInstance(Probe.class);p.reset();
    var inventory=new Inventory(p,new EntityEquipment());inventory.setSelectedSlot(7);
    var inventoryField=Player.class.getDeclaredField("inventory");inventoryField.setAccessible(true);inventoryField.set(p,inventory);
    var baseline=attributes(p);var equipment=new JsonArray();var speeds=new JsonArray();
    var enchantments=lookup.lookupOrThrow(Registries.ENCHANTMENT);
    for(var enchantment:enchantments.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())
      for(int level:levels(enchantment.identifier().toString()))for(boolean stored:new boolean[]{false,true})
        for(var slot:List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET,EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND)){
          p.reset();var stack=new ItemStack(Items.IRON_PICKAXE);var mutable=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);mutable.set(enchantments.getOrThrow(enchantment),level);
          stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,mutable.toImmutable());
          EnchantmentHelper.forEachModifier(stack,slot,(attribute,modifier)->{if(p.attributes.containsKey(attribute))p.attributes.get(attribute).addTransientModifier(modifier);});
          var row=new JsonObject();row.addProperty("enchantment",enchantment.identifier().toString());row.addProperty("level",level);row.addProperty("stored",stored);
          row.addProperty("slot",switch(slot){case HEAD->5;case CHEST->6;case LEGS->7;case FEET->8;case MAINHAND->43;case OFFHAND->45;default->throw new AssertionError(slot);});row.add("attributes",attributes(p));equipment.add(row);
          inventory.setItem(7,slot==EquipmentSlot.MAINHAND?stack:new ItemStack(Items.IRON_PICKAXE));
          var values=new JsonArray();for(var state:List.of(Blocks.STONE.defaultBlockState(),Blocks.DIRT.defaultBlockState()))for(boolean water:new boolean[]{false,true})for(boolean ground:new boolean[]{false,true}){
            p.water=water;p.ground=ground;values.add(bits(p.getDestroySpeed(state)));
          }row.add("speed_bits",values);
        }
    p.reset();
    for(var item:List.of(Items.AIR,Items.STONE,Items.WOODEN_PICKAXE,Items.IRON_PICKAXE,Items.DIAMOND_PICKAXE,Items.GOLDEN_PICKAXE,Items.SHEARS,Items.DIAMOND_SWORD))
      for(boolean remove:new boolean[]{false,true})for(var state:List.of(Blocks.STONE.defaultBlockState(),Blocks.DIRT.defaultBlockState(),Blocks.OBSIDIAN.defaultBlockState(),Blocks.COBWEB.defaultBlockState(),Blocks.BAMBOO.defaultBlockState()))
        for(boolean water:new boolean[]{false,true})for(boolean ground:new boolean[]{false,true}){
          p.water=water;p.ground=ground;var stack=new ItemStack(item);if(remove)stack.remove(DataComponents.TOOL);inventory.setItem(7,stack);
          var row=new JsonObject();row.addProperty("item",BuiltInRegistries.ITEM.getId(item));row.addProperty("removed",remove);row.addProperty("state",Block.getId(state));row.addProperty("water",water);row.addProperty("ground",ground);
          row.addProperty("speed_bits",bits(p.getDestroySpeed(state)));row.addProperty("correct",p.hasCorrectToolForDrops(state));speeds.add(row);
          row.addProperty("rate_bits",bits(state.getDestroyProgress(p,net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO)));
        }
    var aqua=enchantments.getOrThrow(net.minecraft.resources.ResourceKey.create(Registries.ENCHANTMENT,net.minecraft.resources.Identifier.parse("minecraft:aqua_affinity")));
    for(int level:new int[]{1,2,255})for(var state:List.of(Blocks.AIR.defaultBlockState(),Blocks.BAMBOO.defaultBlockState(),Blocks.BEDROCK.defaultBlockState()))for(boolean ground:new boolean[]{false,true}){
      p.reset();p.water=true;p.ground=ground;inventory.setItem(7,new ItemStack(Items.DIAMOND_SWORD));
      var helmet=new ItemStack(Items.IRON_HELMET);var mutable=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);mutable.set(aqua,level);helmet.set(DataComponents.ENCHANTMENTS,mutable.toImmutable());
      EnchantmentHelper.forEachModifier(helmet,EquipmentSlot.HEAD,(attribute,modifier)->{if(p.attributes.containsKey(attribute))p.attributes.get(attribute).addTransientModifier(modifier);});
      var row=new JsonObject();row.addProperty("item",BuiltInRegistries.ITEM.getId(Items.DIAMOND_SWORD));row.addProperty("removed",false);row.addProperty("state",Block.getId(state));row.addProperty("water",true);row.addProperty("ground",ground);row.addProperty("head_aqua",level);
      row.addProperty("speed_bits",bits(p.getDestroySpeed(state)));row.addProperty("correct",p.hasCorrectToolForDrops(state));row.addProperty("rate_bits",bits(state.getDestroyProgress(p,net.minecraft.world.level.EmptyBlockGetter.INSTANCE,BlockPos.ZERO)));speeds.add(row);
    }
    int defaults=0;
    for(var item:BuiltInRegistries.ITEM)for(var slot:EquipmentSlot.values()){
      new ItemStack(item).forEachModifier(slot,(attribute,modifier)->{if(ATTRIBUTES.contains(attribute)&&modifier.amount()!=0)throw new AssertionError("Nonzero stock mining modifier: "+item);});defaults++;
    }
    var result=new JsonObject();result.add("baseline",baseline);result.add("equipment",equipment);result.add("speeds",speeds);Files.writeString(Path.of(args[0]),new Gson().toJson(result));
    System.out.println("PASS: "+equipment.size()+" native mining attribute/equipment cases, "+equipment.size()*8+" geared Player speed contexts, "+speeds.size()+" stock Player speed/harvest contexts and "+defaults+" default modifier controls; status effects and automatic equipment update excluded.");
  }
}
