import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.server.*;
import net.minecraft.server.dedicated.DedicatedServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.packs.PackType;
import net.minecraft.server.packs.repository.ServerPacksSource;
import net.minecraft.server.packs.resources.MultiPackResourceManager;
import net.minecraft.tags.*;
import net.minecraft.util.RandomSource;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.ai.attributes.Attribute;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;
import net.minecraft.world.level.GameType;

/** Actual Player armor callbacks and native one-point wear; no health, stats or world mutation. */
public class ArmorWearOracle {
  static class Server extends DedicatedServer {
    ReloadableServerRegistries.Holder registries;
    private Server(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
    public ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  }
  static class World extends ServerLevel {
    Server server;RandomSource random;
    private World(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public MinecraftServer getServer(){return server;}
    public RandomSource getRandom(){return random;}
  }
  static class Body extends Player {
    World world;Map<EquipmentSlot,ItemStack> gear;List<ItemStack> broken;
    private Body(){super(null,null);}
    public ServerLevel level(){return world;}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public int getArmorValue(){return 0;}
    public double getAttributeValue(Holder<Attribute> attribute){
      if(attribute.equals(Attributes.ARMOR_TOUGHNESS))return 0;
      throw new AssertionError(attribute);
    }
    public ItemStack getItemBySlot(EquipmentSlot slot){return gear.getOrDefault(slot,ItemStack.EMPTY);}
    public void onEquippedItemBroken(ItemStack stack,EquipmentSlot slot){broken.add(stack.copy());}
    void wear(DamageSource source,float amount){getDamageAfterArmorAbsorb(source,amount);}
  }
  static class Draws implements InvocationHandler {
    float value;int count;
    Draws(float value){this.value=value;}
    public Object invoke(Object proxy,Method method,Object[] args){
      if(!method.getName().equals("nextFloat"))throw new AssertionError("Unexpected random method "+method);
      count++;return value;
    }
    RandomSource source(){return (RandomSource)Proxy.newProxyInstance(RandomSource.class.getClassLoader(),new Class<?>[]{RandomSource.class},this);}
  }
  static Field field(Class<?> type,String name)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);return f;}
  static final EquipmentSlot[] SLOTS={EquipmentSlot.FEET,EquipmentSlot.LEGS,EquipmentSlot.CHEST,EquipmentSlot.HEAD};
  static final int[] MENU={8,7,6,5};
  static int one(World world,ItemStack stack,float draw){
    var random=new Draws(draw);world.random=random.source();int result=EnchantmentHelper.processDurabilityChange(world,stack,1);
    if(random.count!=1||result<0||result>1)throw new AssertionError("Non-binomial one-point wear");return result;
  }
  static float threshold(World world,ItemStack stack){
    int low=0,high=Float.floatToRawIntBits(1f);
    while(low<high){int mid=low+(high-low)/2;if(one(world,stack,Float.intBitsToFloat(mid))==1)high=mid;else low=mid+1;}
    float value=Float.intBitsToFloat(low);
    if(one(world,stack,value)!=1||(value>0&&one(world,stack,Math.nextDown(value))!=0))throw new AssertionError("Wear threshold differs");
    return value;
  }
  static void observe(JsonArray rows,Body p,DamageSource source,String name,ItemStack stack,int slot,float amount,float draw,JsonObject patch){
    p.gear.clear();p.gear.put(SLOTS[slot],stack);p.broken.clear();var random=new Draws(draw);p.world.random=random.source();
    var row=patch.deepCopy();row.addProperty("item",BuiltInRegistries.ITEM.getId(stack.getItem()));row.addProperty("slot",MENU[slot]);
    row.addProperty("source",name);row.addProperty("amount",(double)amount);row.addProperty("random",(double)draw);
    p.wear(source,amount);
    row.addProperty("count",stack.getCount());Integer damage=stack.get(DataComponents.DAMAGE);
    row.add("damage",damage==null?JsonNull.INSTANCE:new JsonPrimitive(damage));row.addProperty("draws",random.count);
    row.addProperty("breaks",p.broken.size());row.add("broken_damage",p.broken.isEmpty()?JsonNull.INSTANCE:new JsonPrimitive(p.broken.getFirst().getDamageValue()));rows.add(row);
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var bind=Holder.Reference.class.getDeclaredMethod("bindTags",Collection.class);bind.setAccessible(true);
    try(var resources=new MultiPackResourceManager(PackType.SERVER_DATA,List.of(ServerPacksSource.createVanillaPackSource().fullResources()))){
      var tags=TagLoader.loadTagsForRegistry(resources,BuiltInRegistries.ITEM.key(),(id,required)->BuiltInRegistries.ITEM.get(id));
      var memberships=new HashMap<Holder<Item>,List<TagKey<Item>>>();tags.forEach((tag,holders)->holders.forEach(holder->memberships.computeIfAbsent(holder,k->new ArrayList<>()).add(tag)));
      for(var item:BuiltInRegistries.ITEM)bind.invoke(item.builtInRegistryHolder(),memberships.getOrDefault(item.builtInRegistryHolder(),List.of()));
    }
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    var server=(Server)unsafe.allocateInstance(Server.class);server.registries=new ReloadableServerRegistries.Holder(lookup);
    var world=(World)unsafe.allocateInstance(World.class);world.server=server;
    var p=(Body)unsafe.allocateInstance(Body.class);p.world=world;p.gear=new EnumMap<>(EquipmentSlot.class);p.broken=new ArrayList<>();
    var tagFacts=JsonParser.parseString(Files.readString(Path.of("priv/protocol/tags.json"))).getAsJsonObject().getAsJsonObject("minecraft:damage_type");
    var names=JsonParser.parseString(Files.readString(Path.of("priv/protocol/registries.json"))).getAsJsonObject().getAsJsonArray("minecraft:damage_type");
    var sources=new LinkedHashMap<String,DamageSource>();
    for(var type:List.of(DamageTypes.IN_FIRE,DamageTypes.ON_FIRE,DamageTypes.LAVA,DamageTypes.HOT_FLOOR)){
      var holder=lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(type);int id=-1;
      for(int i=0;i<names.size();i++)if(names.get(i).getAsString().equals(type.identifier().toString()))id=i;
      var keys=new ArrayList<TagKey<DamageType>>();for(var e:tagFacts.entrySet())for(var value:e.getValue().getAsJsonArray())if(value.getAsInt()==id)keys.add(TagKey.create(Registries.DAMAGE_TYPE,Identifier.parse(e.getKey())));
      bind.invoke(holder,keys);sources.put(type.identifier().getPath(),new DamageSource(holder));
    }
    var hurt=new JsonArray();var resistant=new JsonArray();var armorTag=new JsonArray();var armor=TagKey.create(Registries.ITEM,Identifier.parse("minecraft:enchantable/armor"));
    var rows=new JsonArray();
    for(var item:BuiltInRegistries.ITEM){
      var stock=new ItemStack(item);var equippable=stock.get(DataComponents.EQUIPPABLE);
      if(equippable!=null&&equippable.damageOnHurt())hurt.add(BuiltInRegistries.ITEM.getId(item));
      boolean immune=!stock.canBeHurtBy(sources.get("lava"));
      for(var source:sources.values())if(immune==stock.canBeHurtBy(source))throw new AssertionError("Source-specific resistance needs separate facts");
      if(immune)resistant.add(BuiltInRegistries.ITEM.getId(item));if(item.builtInRegistryHolder().is(armor))armorTag.add(BuiltInRegistries.ITEM.getId(item));
      if(item==Items.AIR)continue;
      for(var source:sources.entrySet())for(int slot=0;slot<4;slot++)for(String removed:List.of("","minecraft:equippable","minecraft:damage","minecraft:max_damage","minecraft:damage_resistant")){
        var stack=new ItemStack(item);var input=new JsonObject();
        if(!removed.isEmpty()){stack.remove(BuiltInRegistries.DATA_COMPONENT_TYPE.getValue(Identifier.parse(removed)));input.addProperty("removed",removed);}
        observe(rows,p,source.getValue(),source.getKey(),stack,slot,4f,0f,input);
      }
    }
    var enchantments=lookup.lookupOrThrow(Registries.ENCHANTMENT);var unbreaking=enchantments.getOrThrow(Enchantments.UNBREAKING);
    for(var enchant:enchantments.listElements().toList())if(!enchant.equals(unbreaking)&&!enchant.value().getEffects(EnchantmentEffectComponents.ITEM_DAMAGE).isEmpty())throw new AssertionError("Other stock wear enchantment");
    var probabilities=new JsonObject();
    for(var item:List.of(Items.IRON_HELMET,Items.IRON_PICKAXE)){
      var values=new JsonArray();values.add(0f);
      for(int level=1;level<=255;level++){
        var stack=new ItemStack(item);stack.enchant(unbreaking,level);float chance=threshold(world,stack);values.add((double)chance);
        for(boolean stored:new boolean[]{false,true})for(float draw:new float[]{0f,Math.max(0f,Math.nextDown(chance)),chance,Math.min(.99999994f,Math.nextUp(chance))}){
          var copy=new ItemStack(item);var levels=new ItemEnchantments.Mutable(ItemEnchantments.EMPTY);levels.set(unbreaking,level);
          copy.set(stored?DataComponents.STORED_ENCHANTMENTS:DataComponents.ENCHANTMENTS,levels.toImmutable());
          var input=new JsonObject();input.addProperty("level",level);input.addProperty("stored",stored);
          observe(rows,p,sources.get("lava"),"lava",copy,0,4f,draw,input);
        }
      }
      probabilities.add(item==Items.IRON_HELMET?"armor":"other",values);
    }
    for(var item:List.of(Items.IRON_HELMET,Items.NETHERITE_BOOTS,Items.STONE))for(int maximum:new int[]{1,2,165,Integer.MAX_VALUE})for(int damage:new int[]{0,1,maximum-1,maximum,Integer.MAX_VALUE})for(boolean unbreakable:new boolean[]{false,true})for(boolean added:new boolean[]{false,true})for(float amount:new float[]{0f,Float.MIN_VALUE,.1f,1f,Math.nextDown(4f),4f}){
      var stack=new ItemStack(item);stack.set(DataComponents.MAX_STACK_SIZE,1);stack.set(DataComponents.MAX_DAMAGE,maximum);if(added)stack.set(DataComponents.DAMAGE,damage);if(unbreakable)stack.set(DataComponents.UNBREAKABLE,net.minecraft.util.Unit.INSTANCE);
      var input=new JsonObject();input.addProperty("maximum",maximum);if(added)input.addProperty("initial_damage",damage);input.addProperty("unbreakable",unbreakable);
      observe(rows,p,sources.get("lava"),"lava",stack,0,amount,0f,input);
    }
    var facts=new JsonObject();facts.add("damage_on_hurt",hurt);facts.add("fire_resistant",resistant);facts.add("armor_tag",armorTag);facts.add("unbreaking",probabilities);
    var events=new JsonObject();var event=LivingEntity.class.getDeclaredMethod("entityEventForEquipmentBreak",EquipmentSlot.class);event.setAccessible(true);
    for(int i=0;i<SLOTS.length;i++)events.addProperty(Integer.toString(MENU[i]),(byte)event.invoke(null,SLOTS[i]));facts.add("break_events",events);
    var exhaustion=new JsonObject();for(var source:sources.entrySet())exhaustion.addProperty(source.getKey(),(double)source.getValue().getFoodExhaustion());facts.add("exhaustion",exhaustion);
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native Player.hurtArmor/ItemStack wear cases; all stock items, four armor positions/fire sources, removals, Unbreaking thresholds, break payloads and signed-int durability. Health and attribute refresh excluded.");
  }
}
