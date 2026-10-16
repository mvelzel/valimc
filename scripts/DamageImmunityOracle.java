import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.resources.*;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.*;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.phys.Vec3;

/** Actual stock enchantment immunity, independently of damage reductions, wear or status effects. */
public class DamageImmunityOracle {
  static class Server extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }
  static class World extends ServerLevel {
    Server server;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return RandomSource.create(1);}
  }
  static class Body extends Player {
    World world;Map<EquipmentSlot,ItemStack> gear;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public ItemStack getItemBySlot(EquipmentSlot slot){return gear.getOrDefault(slot,ItemStack.EMPTY);}
    public RandomSource getRandom(){return RandomSource.create(1);}
  }
  static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  static int menuSlot(EquipmentSlot slot){return switch(slot){case HEAD->5;case CHEST->6;case LEGS->7;case FEET->8;case MAINHAND->36;case OFFHAND->45;default->throw new AssertionError(slot);};}
  static ItemEnchantments patch(Holder<Enchantment> enchantment,int level,MappedRegistry<Enchantment> registry,RegistryAccess.Frozen access){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try{buffer.writeVarInt(1);buffer.writeVarInt(registry.getId(enchantment.value()));buffer.writeVarInt(level);return ItemEnchantments.STREAM_CODEC.decode(buffer);}finally{buffer.release();}
  }
  static void observe(JsonArray rows,Body body,Map<String,DamageSource> sources,EquipmentSlot slot,Item item,String enchantment,int level,boolean stored,ItemEnchantments patch){
    body.gear.clear();var stack=new ItemStack(item);stack.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,patch);body.gear.put(slot,stack);
    var immune=new JsonArray();for(var entry:sources.entrySet())if(EnchantmentHelper.isImmuneToDamage(body.world,body,entry.getValue()))immune.add(entry.getKey());
    var row=new JsonObject();row.addProperty("slot",menuSlot(slot));row.addProperty("item",BuiltInRegistries.ITEM.getId(item));row.addProperty("enchantment",enchantment);row.addProperty("level",level);row.addProperty("stored",stored);row.add("immune",immune);rows.add(row);
  }
  public static void main(String[] args)throws Exception {
    var lookup=MiningToolOracle.initialize();var damageLookup=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var damageTags=TagLoader.loadTagsForRegistry(resources,Registries.DAMAGE_TYPE,(id,required)->damageLookup.get(ResourceKey.create(Registries.DAMAGE_TYPE,id)));
      var memberships=new HashMap<Holder<DamageType>,List<TagKey<DamageType>>>();damageTags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      for(var holder:damageLookup.listElements().toList())bind.invoke(holder,memberships.getOrDefault(holder,List.of()));
      var itemTags=TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.ITEM.key(),(id,required)->BuiltInRegistries.ITEM.get(id));
      var items=new HashMap<Holder<Item>,List<TagKey<Item>>>();itemTags.forEach((tag,holders)->holders.forEach(holder->items.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      for(var item:BuiltInRegistries.ITEM)bind.invoke(item.builtInRegistryHolder(),items.getOrDefault(item.builtInRegistryHolder(),List.of()));
    }
    var original=lookup.lookupOrThrow(Registries.ENCHANTMENT);var enchantments=new MappedRegistry<Enchantment>(Registries.ENCHANTMENT,Lifecycle.stable());
    for(var key:original.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())enchantments.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);enchantments.freeze();
    var access=new RegistryAccess.ImmutableRegistryAccess(List.of(enchantments)).freeze();
    var u=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var server=(Server)u.allocateInstance(Server.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var world=(World)u.allocateInstance(World.class);world.server=server;
    var body=(Body)u.allocateInstance(Body.class);body.world=world;body.gear=new EnumMap<>(EquipmentSlot.class);field(Entity.class,"position").set(body,new Vec3(.5,64,.5));
    var sources=new LinkedHashMap<String,DamageSource>();for(var key:damageLookup.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())sources.put(key.identifier().getPath(),new DamageSource(damageLookup.getOrThrow(key)));
    var rows=new JsonArray();var slots=List.of(EquipmentSlot.HEAD,EquipmentSlot.CHEST,EquipmentSlot.LEGS,EquipmentSlot.FEET,EquipmentSlot.MAINHAND,EquipmentSlot.OFFHAND);
    for(var enchantment:enchantments.listElements().toList())for(int level:new int[]{0,1,2,255})for(boolean stored:new boolean[]{false,true})for(var slot:slots)
      observe(rows,body,sources,slot,Items.STONE,enchantment.unwrapKey().orElseThrow().identifier().toString(),level,stored,patch(enchantment,level,enchantments,access));
    var frost=enchantments.getOrThrow(Enchantments.FROST_WALKER);var one=patch(frost,1,enchantments,access);
    for(var item:BuiltInRegistries.ITEM)if(!new ItemStack(item).isEmpty())observe(rows,body,sources,EquipmentSlot.FEET,item,"minecraft:frost_walker",1,false,one);
    var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("data_version",5023);out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("sources",new Gson().toJsonTree(sources.keySet()));out.addProperty("enchantment_count",enchantments.size());out.add("cases",rows);
    Files.writeString(Path.of(args[0]),new Gson().toJson(out));
    System.out.println("PASS: "+rows.size()+" native equipment/enchantment immunity contexts across "+sources.size()+" sources and "+enchantments.size()+" stock enchantments; direct/stored, level0, all six player slots and every nonempty stock item in feet. Damage/status/mode immunity and wear excluded.");
  }
}
