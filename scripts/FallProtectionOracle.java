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
import net.minecraft.world.effect.MobEffect;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/** Actual native worn-enchantment and armor/magic damage path, with no health/world mutation. */
public class FallProtectionOracle {
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
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public ItemStack getItemBySlot(EquipmentSlot slot){return gear.getOrDefault(slot,ItemStack.EMPTY);}
    public RandomSource getRandom(){return RandomSource.create(1);}
    public boolean hasEffect(Holder<MobEffect> effect){return false;}
    public int getArmorValue(){return 30;}
    protected void hurtArmor(DamageSource source,float amount){throw new AssertionError("Landing must bypass armor wear");}
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
    var stack=new ItemStack(Items.STONE);stack.set(DataComponents.ENCHANTMENTS,patch(direct,registry,access));stack.set(DataComponents.STORED_ENCHANTMENTS,patch(stored,registry,access));p.gear.put(slot,stack);
    var row=new JsonObject();row.addProperty("slot",menuSlot(slot));row.add("direct",new Gson().toJsonTree(direct));row.add("stored",new Gson().toJsonTree(stored));gear.add(row);
  }
  private static void observe(JsonArray cases,Probe p,JsonArray gear,String source,DamageSource damage){
    float protection=EnchantmentHelper.getDamageProtection(p.world,p,damage);
    for(float amount:new float[]{.1f,1,5,100,Float.MAX_VALUE}){
      float armored=p.armor(damage,amount);if(armored!=amount)throw new AssertionError("Unexpected landing armor reduction");
      var c=new JsonObject();c.add("gear",gear);c.addProperty("source",source);c.addProperty("amount",(double)amount);c.addProperty("protection",(double)protection);c.addProperty("damage",(double)p.magic(damage,armored));cases.add(c);
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
    var p=(Probe)unsafe.allocateInstance(Probe.class);p.world=world;p.gear=new EnumMap<>(EquipmentSlot.class);field(Entity.class,"position").set(p,new Vec3(.5,64,.5));
    var tags=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject().getAsJsonObject("minecraft:damage_type");
    var names=JsonParser.parseString(Files.readString(Path.of("priv/protocol/registries.json"))).getAsJsonObject().getAsJsonArray("minecraft:damage_type");
    var bindTags=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bindTags.setAccessible(true);
    var cases=new JsonArray();
    for(var type:List.of(DamageTypes.FALL,DamageTypes.STALAGMITE)){
      var holder=lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(type);int id=-1;
      for(int i=0;i<names.size();i++)if(names.get(i).getAsString().equals(type.identifier().toString()))id=i;
      if(id<0)throw new AssertionError(type);var keys=new ArrayList<TagKey<DamageType>>();
      for(var e:tags.entrySet())for(var value:e.getValue().getAsJsonArray())if(value.getAsInt()==id)keys.add(TagKey.create(Registries.DAMAGE_TYPE,net.minecraft.resources.Identifier.parse(e.getKey())));
      bindTags.invoke(holder,keys);var damage=new DamageSource(holder);
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
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" native equipment/protection/armor-bypass/magic damage cases; both landing sources, all "+registry.size()+" enchantments, levels0/1/4/255, stored and hand negatives, stacked caps. Effects/health/world mutation excluded.");
  }
}
