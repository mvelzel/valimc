import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.server.level.*;
import net.minecraft.world.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.*;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.*;
import net.minecraft.world.level.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.phys.*;
/** Original native block-use dispatch and CraftingMenu validity observations. */
public class CraftingTableAccessOracle {
 static class S extends net.minecraft.server.dedicated.DedicatedServer {
  net.minecraft.server.ReloadableServerRegistries.Holder registries;
  private S(){super(null,null,null,null,Optional.empty(),null,null,null,null,null);}
  public net.minecraft.server.ReloadableServerRegistries.Holder reloadableRegistries(){return registries;}
  public net.minecraft.util.RandomSource getRandomSequence(net.minecraft.resources.Identifier id){return net.minecraft.util.RandomSource.create(1L);}
 }
 static S server;
 static net.minecraft.server.PlayerAdvancements advancements;
 static class L extends ServerLevel {
  BlockState state;
  public net.minecraft.server.MinecraftServer getServer(){return server;}
  private L(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
  public BlockState getBlockState(BlockPos pos){return state;}
  public net.minecraft.util.RandomSource getRandom(){return net.minecraft.util.RandomSource.create(1L);}
  public net.minecraft.world.flag.FeatureFlagSet enabledFeatures(){return net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS;}
 }
 static class P extends ServerPlayer {
  L world;GameType mode;boolean secondary;ItemStack main,off;Abilities abilities;Inventory inventory;int opens;double range;
  private P(){super(null,null,null,null);}
  public ServerLevel level(){return world;}
  public GameType gameMode(){return mode;}
  public boolean isSecondaryUseActive(){return secondary;}
  public ItemStack getMainHandItem(){return main;}
  public ItemStack getOffhandItem(){return off;}
  public ItemStack getItemInHand(InteractionHand hand){return hand==InteractionHand.MAIN_HAND?main:off;}
  public Abilities getAbilities(){return abilities;}
  public Inventory getInventory(){return inventory;}
  public ItemCooldowns getCooldowns(){return new ItemCooldowns();}
  public OptionalInt openMenu(MenuProvider provider){if(provider==null)throw new AssertionError("Missing provider");opens++;return OptionalInt.of(17);}
  public void awardStat(net.minecraft.stats.Stat<?> stat,int amount){}
  public net.minecraft.server.PlayerAdvancements getAdvancements(){return advancements;}
  public double blockInteractionRange(){return range;}
 }
 static class Table extends CraftingMenu {
  Table(Inventory inventory,L world,BlockPos pos){super(17,inventory,ContainerLevelAccess.create(world,pos));}
  public void slotsChanged(Container container){}
 }
 static void set(Object instance,Class<?> type,String name,Object value)throws Exception{var f=type.getDeclaredField(name);f.setAccessible(true);f.set(instance,value);}
 public static void main(String[]args)throws Exception {
  var lookup=MiningToolOracle.initialize();var f=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);var u=(sun.misc.Unsafe)f.get(null);
  server=(S)u.allocateInstance(S.class);server.registries=new net.minecraft.server.ReloadableServerRegistries.Holder(lookup);
  advancements=(net.minecraft.server.PlayerAdvancements)u.allocateInstance(net.minecraft.server.PlayerAdvancements.class);set(advancements,net.minecraft.server.PlayerAdvancements.class,"activeTriggers",Map.of());
  var uses=new JsonArray();var validity=new JsonArray();
  for(var mode:GameType.values())for(boolean secondary:new boolean[]{false,true})for(boolean main:new boolean[]{false,true})for(boolean off:new boolean[]{false,true})for(var hand:InteractionHand.values())for(boolean table:new boolean[]{false,true}) {
   var l=(L)u.allocateInstance(L.class);l.state=(table?Blocks.CRAFTING_TABLE:Blocks.STONE).defaultBlockState();
   var p=(P)u.allocateInstance(P.class);p.world=l;p.mode=mode;p.secondary=secondary;p.main=main?new ItemStack(Items.STICK):ItemStack.EMPTY;p.off=off?new ItemStack(Items.STICK):ItemStack.EMPTY;p.abilities=new Abilities();set(p,Player.class,"abilities",p.abilities);p.abilities.instabuild=mode==GameType.CREATIVE;p.abilities.mayBuild=mode!=GameType.ADVENTURE&&mode!=GameType.SPECTATOR;
   var g=(ServerPlayerGameMode)u.allocateInstance(ServerPlayerGameMode.class);set(g,ServerPlayerGameMode.class,"player",p);set(g,ServerPlayerGameMode.class,"level",l);set(g,ServerPlayerGameMode.class,"gameModeForPlayer",mode);
   var hit=new BlockHitResult(new Vec3(.5,.5,.5),Direction.UP,BlockPos.ZERO,false);
   var result=g.useItemOn(p,l,p.getItemInHand(hand),hand,hit);
   var row=new JsonArray();row.add(mode.getName());row.add(secondary);row.add(main);row.add(off);row.add(hand.name());row.add(table);row.add(p.opens);row.add(result.consumesAction());uses.add(row);
  }
  for(var mode:GameType.values())for(boolean table:new boolean[]{false,true})for(var pos:List.of(BlockPos.ZERO,new BlockPos(29999984,64,-29999984))) {
   var l=(L)u.allocateInstance(L.class);l.state=(table?Blocks.CRAFTING_TABLE:Blocks.STONE).defaultBlockState();
   var p=(P)u.allocateInstance(P.class);p.world=l;p.mode=mode;p.range=mode==GameType.CREATIVE?5.0:4.5;p.abilities=new Abilities();set(p,Player.class,"abilities",p.abilities);p.inventory=new Inventory(p,new EntityEquipment());
   set(p,Entity.class,"eyeHeight",0.0f);var menu=new Table(p.inventory,l,pos);double reach=p.range+4.0;
   for(double x:new double[]{.5,1+reach-1e-6,1+reach,1+reach+1e-6,-reach+1e-6,-reach,-reach-1e-6}) {
    var eye=new Vec3(pos.getX()+x,pos.getY()+.5,pos.getZ()+.5);set(p,Entity.class,"position",eye);
    var row=new JsonArray();row.add(mode.getName());row.add(table);row.add(new Gson().toJsonTree(List.of(pos.getX(),pos.getY(),pos.getZ())));row.add(new Gson().toJsonTree(List.of(eye.x,eye.y,eye.z)));row.add(menu.stillValid(p));validity.add(row);
   }
  }
  var out=new JsonObject();out.addProperty("version","26.3");out.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");out.add("uses",uses);out.add("validity",validity);out.addProperty("table_item",net.minecraft.core.registries.BuiltInRegistries.ITEM.getId(Items.CRAFTING_TABLE));out.addProperty("table_state",Block.getId(Blocks.CRAFTING_TABLE.defaultBlockState()));
  Files.writeString(Path.of(args[0]),new Gson().toJson(out));System.out.println("PASS:"+uses.size()+" actual game-mode table-use decisions and "+validity.size()+" actual table validity boundaries.");
 }
}
