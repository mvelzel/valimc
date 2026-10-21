import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.tags.TagKey;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.effect.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/** Actual native worn-enchantment and armor/magic damage path, with no health/world mutation. */
public class DamageProtectionOracle {
  private static class ProbeServer extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private ProbeServer(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }
  private static class ProbeLevel extends ServerLevel {
    ProbeServer server;
    private ProbeLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return RandomSource.create(1);}
  }
  private static class Probe extends Player {
    ProbeLevel world; Map<EquipmentSlot,ItemStack> gear;
    int armorValue=30,wearCalls; double toughness; float wearAmount;
    boolean fire;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public ItemStack getItemBySlot(EquipmentSlot slot){return gear.getOrDefault(slot,ItemStack.EMPTY);}
    public RandomSource getRandom(){return RandomSource.create(1);}
    public int getArmorValue(){return armorValue;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(attribute.equals(Attributes.ARMOR_TOUGHNESS))return toughness;
      throw new AssertionError("Unexpected damage attribute: "+attribute);
    }
    protected void hurtArmor(DamageSource source,float amount){
      if(!fire)throw new AssertionError("Environmental source must bypass armor wear");
      wearCalls++;wearAmount=amount;
    }
    float armor(DamageSource source,float amount){return getDamageAfterArmorAbsorb(source,amount);}
    float magic(DamageSource source,float amount){return getDamageAfterMagicAbsorb(source,amount);}
  }
  private static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  private static ItemEnchantments patch(Map<String,Integer> levels,MappedRegistry<Enchantment> registry,RegistryAccess.Frozen access){
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{
      buf.writeVarInt(levels.size());
      for(var e:new TreeMap<>(levels).entrySet()){
        var holder=registry.getOrThrow(net.minecraft.resources.ResourceKey.create(Registries.ENCHANTMENT,net.minecraft.resources.Identifier.parse(e.getKey())));
        buf.writeVarInt(registry.getId(holder.value()));buf.writeVarInt(e.getValue());
      }
      return ItemEnchantments.STREAM_CODEC.decode(buf);
    }finally{buf.release();}
  }
  private static int menuSlot(EquipmentSlot slot){return switch(slot){case HEAD->5;case CHEST->6;case LEGS->7;case FEET->8;case MAINHAND->36;case OFFHAND->45;default->throw new AssertionError(slot);};}
  private static void equip(Probe p,JsonArray gear,MappedRegistry<Enchantment> registry,RegistryAccess.Frozen access,EquipmentSlot slot,Map<String,Integer> direct,Map<String,Integer> stored){
    equip(p,gear,registry,access,slot,Items.STONE,false,direct,stored);
  }
  private static void equip(Probe p,JsonArray gear,MappedRegistry<Enchantment> registry,RegistryAccess.Frozen access,EquipmentSlot slot,Item item,boolean removed,Map<String,Integer> direct,Map<String,Integer> stored){
    var stack=new ItemStack(item);if(removed)stack.remove(DataComponents.ATTRIBUTE_MODIFIERS);
    stack.set(DataComponents.ENCHANTMENTS,patch(direct,registry,access));stack.set(DataComponents.STORED_ENCHANTMENTS,patch(stored,registry,access));p.gear.put(slot,stack);
    var row=new JsonObject();row.addProperty("slot",menuSlot(slot));row.addProperty("item_id",BuiltInRegistries.ITEM.getId(item));row.addProperty("removed",removed);row.add("direct",new Gson().toJsonTree(direct));row.add("stored",new Gson().toJsonTree(stored));gear.add(row);
  }
  private static void observe(JsonArray cases,Probe p,JsonArray gear,String source,DamageSource damage){
    if(p.fire){
      var attributes=new AttributeMap(Player.createAttributes().build());
      for(var entry:p.gear.entrySet())entry.getValue().forEachModifier(entry.getKey(),(attribute,modifier)->{
        if(attribute.equals(Attributes.ARMOR)||attribute.equals(Attributes.ARMOR_TOUGHNESS))attributes.getInstance(attribute).addOrUpdateTransientModifier(modifier);
      });
      p.armorValue=(int)Math.floor(attributes.getValue(Attributes.ARMOR));p.toughness=attributes.getValue(Attributes.ARMOR_TOUGHNESS);
    }
    float protection=EnchantmentHelper.getDamageProtection(p.world,p,damage);
    for(float amount:source.equals("indirect_magic")?new float[]{0,.1f,1,5,6,12,100,Float.MAX_VALUE}:new float[]{.1f,1,5,100,Float.MAX_VALUE}){
      p.wearCalls=0;float armored=p.armor(damage,amount);if(!p.fire&&armored!=amount)throw new AssertionError("Unexpected environmental armor reduction");
      var c=new JsonObject();c.add("gear",gear);c.addProperty("source",source);c.addProperty("amount",(double)amount);c.addProperty("protection",(double)protection);
      float resolved=p.magic(damage,armored);if(Float.isNaN(resolved)||resolved<0)throw new AssertionError("Unexpected resolved damage");
      if(Float.isInfinite(resolved))c.addProperty("damage","infinity");else c.addProperty("damage",(double)resolved);
      var resistance=p.getEffect(MobEffects.RESISTANCE);c.addProperty("resistance",resistance==null?-1:resistance.getAmplifier());c.addProperty("exhaustion",(double)damage.getFoodExhaustion());
      if(p.fire){c.addProperty("armor",p.armorValue);c.addProperty("toughness",p.toughness);c.addProperty("armored",(double)armored);c.addProperty("wear_calls",p.wearCalls);if(p.wearCalls>0)c.addProperty("wear_amount",(double)p.wearAmount);}
      cases.add(c);
    }
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    for(var item:BuiltInRegistries.ITEM)if(!new ItemStack(item).getOrDefault(DataComponents.ENCHANTMENTS,ItemEnchantments.EMPTY).isEmpty())throw new AssertionError("Nonempty default enchantments");
    var source=lookup.lookupOrThrow(Registries.ENCHANTMENT);var registry=new MappedRegistry<Enchantment>(Registries.ENCHANTMENT,Lifecycle.stable());
    for(var id:source.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())registry.register(id,source.getOrThrow(id).value(),RegistrationInfo.BUILT_IN);
    registry.freeze();var access=new RegistryAccess.ImmutableRegistryAccess(List.of(registry)).freeze();
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var server=(ProbeServer)unsafe.allocateInstance(ProbeServer.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);world.server=server;
    String mode=args.length>1?args[1]:"environment";
    var p=(Probe)unsafe.allocateInstance(Probe.class);p.world=world;p.gear=new EnumMap<>(EquipmentSlot.class);p.armorValue=30;p.fire=Set.of("fire","hazards").contains(mode);field(Entity.class,"position").set(p,new Vec3(.5,64,.5));
    var statuses=new HashMap<Holder<MobEffect>,MobEffectInstance>();field(LivingEntity.class,"activeEffects").set(p,statuses);
    if(args.length>2)statuses.put(MobEffects.RESISTANCE,new MobEffectInstance(MobEffects.RESISTANCE,-1,Integer.parseInt(args[2])));
    var tags=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject().getAsJsonObject("minecraft:damage_type");
    var names=JsonParser.parseString(Files.readString(Path.of("priv/protocol/registries.json"))).getAsJsonObject().getAsJsonArray("minecraft:damage_type");
    var bindTags=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bindTags.setAccessible(true);
    var cases=new JsonArray();
    var types=switch(mode){
      case "effects"->List.of(DamageTypes.MAGIC,DamageTypes.WITHER);
      case "instant"->List.of(DamageTypes.INDIRECT_MAGIC);
      case "hazards"->List.of(DamageTypes.CAMPFIRE,DamageTypes.CACTUS,DamageTypes.SWEET_BERRY_BUSH);
      case "fire"->List.of(DamageTypes.IN_FIRE,DamageTypes.ON_FIRE,DamageTypes.LAVA,DamageTypes.HOT_FLOOR);
      case "environment"->List.of(DamageTypes.FALL,DamageTypes.STALAGMITE,DamageTypes.FREEZE,DamageTypes.DROWN,DamageTypes.FELL_OUT_OF_WORLD,DamageTypes.STARVE,DamageTypes.OUTSIDE_BORDER);
      default->throw new AssertionError("Unknown source matrix: "+mode);
    };
    for(var type:types){
      var holder=lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(type);int id=-1;
      for(int i=0;i<names.size();i++)if(names.get(i).getAsString().equals(type.identifier().toString()))id=i;
      if(id<0)throw new AssertionError(type);var keys=new ArrayList<TagKey<DamageType>>();
      for(var e:tags.entrySet())for(var value:e.getValue().getAsJsonArray())if(value.getAsInt()==id)keys.add(TagKey.create(Registries.DAMAGE_TYPE,net.minecraft.resources.Identifier.parse(e.getKey())));
      bindTags.invoke(holder,keys);var damage=mode.equals("instant")?new DamageSource(holder,p,p):new DamageSource(holder);
      for(var enchantment:registry.entrySet())for(int level:new int[]{0,1,4,255})for(boolean stored:new boolean[]{false,true})
        for(var slot:List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET,EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND)){
          p.gear.clear();var gear=new JsonArray();var one=Map.of(enchantment.getKey().identifier().toString(),level);
          equip(p,gear,registry,access,slot,stored?Map.of():one,stored?one:Map.of());observe(cases,p,gear,type.identifier().getPath(),damage);
        }
      for(int protection:new int[]{0,1,4,255})for(int feather:new int[]{0,1,4,255}){
        p.gear.clear();var gear=new JsonArray();
        for(var slot:List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET))
          equip(p,gear,registry,access,slot,Map.of("minecraft:protection",protection,"minecraft:feather_falling",feather),Map.of());
        observe(cases,p,gear,type.identifier().getPath(),damage);
      }
      if(p.fire)for(boolean removed:new boolean[]{false,true})for(int protection:new int[]{0,1,4,255})for(int fire:new int[]{0,1,4,255}){
        for(var set:List.of(new Item[]{Items.LEATHER_HELMET,Items.LEATHER_CHESTPLATE,Items.LEATHER_LEGGINGS,Items.LEATHER_BOOTS},new Item[]{Items.IRON_HELMET,Items.IRON_CHESTPLATE,Items.IRON_LEGGINGS,Items.IRON_BOOTS},new Item[]{Items.DIAMOND_HELMET,Items.DIAMOND_CHESTPLATE,Items.DIAMOND_LEGGINGS,Items.DIAMOND_BOOTS},new Item[]{Items.NETHERITE_HELMET,Items.NETHERITE_CHESTPLATE,Items.NETHERITE_LEGGINGS,Items.NETHERITE_BOOTS})){
          p.gear.clear();var gear=new JsonArray();int index=0;
          for(var slot:List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET))equip(p,gear,registry,access,slot,set[index++],removed,Map.of("minecraft:protection",protection,"minecraft:fire_protection",fire),Map.of());
          observe(cases,p,gear,type.identifier().getPath(),damage);
        }
      }
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native equipment/protection/armor/magic damage cases; sources="+types+", all "+registry.size()+" enchantments, levels0/1/4/255, stored and hand negatives, stacked caps, Resistance="+(args.length>2?args[2]:"absent")+". Health/world mutation/statistics excluded; armor-wear callback recorded but stack wear excluded; native lethal infinity labeled.");
  }
}
