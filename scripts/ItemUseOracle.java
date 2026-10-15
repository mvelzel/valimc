import com.google.gson.*;
import io.netty.buffer.Unpooled;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.*;
import net.minecraft.network.protocol.game.*;
import net.minecraft.network.syncher.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.food.FoodProperties;
import net.minecraft.world.item.*;
import net.minecraft.world.level.GameType;

/** Actual codecs and native active-use tick prefixes; completion/stop/world callbacks controlled. */
public class ItemUseOracle {
  private static class ProbeLevel extends ServerLevel {
    private ProbeLevel(){super(null,null,null,null,null,null,false,0,null,false);}
  }
  private static class Probe extends Player {
    ProbeLevel world; ItemStack current; InteractionHand hand; boolean active; int completed,stopped;
    private Probe(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public ServerLevel level(){return world;}
    public boolean isUsingItem(){return active;}
    public InteractionHand getUsedItemHand(){return hand;}
    public ItemStack getItemInHand(InteractionHand hand){return current;}
    protected void completeUsingItem(){completed++;active=false;}
    public void stopUsingItem(){stopped++;active=false;}
  }
  private static Field field(Class<?> owner,String name)throws Exception{var f=owner.getDeclaredField(name);f.setAccessible(true);return f;}
  private static String bytes(FriendlyByteBuf buf){var bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return HexFormat.of().formatHex(bytes);}
  private static Map<String,ServerboundUseItemPacket> requests(){
    var cases=new LinkedHashMap<String,ServerboundUseItemPacket>();
    for(var hand:InteractionHand.values())for(int sequence:new int[]{0,1,127,128,Integer.MAX_VALUE})for(float yaw:new float[]{0,-180,Float.MAX_VALUE})
      cases.put("request_"+cases.size(),new ServerboundUseItemPacket(hand,sequence,yaw,90));return cases;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var requests=requests();
    var accessor=(EntityDataAccessor<Byte>)field(LivingEntity.class,"DATA_LIVING_ENTITY_FLAGS").get(null);
    if(args[0].equals("verify")){
      var result=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonObject();
      for(var row:result.getAsJsonArray("requests")){var c=row.getAsJsonObject();var buf=new FriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(c.get("wire").getAsString())));
        try{if(!ServerboundUseItemPacket.STREAM_CODEC.decode(buf).equals(requests.get(c.get("name").getAsString()))||buf.isReadable())throw new AssertionError(c);}finally{buf.release();}}
      for(var row:result.getAsJsonArray("metadata")){var c=row.getAsJsonObject();var buf=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(c.get("wire").getAsString())),RegistryAccess.EMPTY);
        try{var packet=ClientboundSetEntityDataPacket.STREAM_CODEC.decode(buf);var value=packet.packedItems().getFirst();if(packet.id()!=c.get("entity_id").getAsInt()||packet.packedItems().size()!=1||value.id()!=accessor.id()||!value.value().equals((byte)c.get("flags").getAsInt())||buf.isReadable())throw new AssertionError(c);}finally{buf.release();}}
      for(var row:result.getAsJsonArray("events")){var c=row.getAsJsonObject();var raw=HexFormat.of().parseHex(c.get("wire").getAsString());var buf=new FriendlyByteBuf(Unpooled.wrappedBuffer(raw));var encoded=new FriendlyByteBuf(Unpooled.buffer());
        try{var packet=ClientboundEntityEventPacket.STREAM_CODEC.decode(buf);ClientboundEntityEventPacket.STREAM_CODEC.encode(encoded,packet);if(packet.getEventId()!=9||buf.isReadable()||!bytes(encoded).equals(c.get("wire").getAsString()))throw new AssertionError(c);}finally{buf.release();encoded.release();}}
      System.out.println("PASS: native decoding of "+result.getAsJsonArray("requests").size()+" item-use requests, "+result.getAsJsonArray("metadata").size()+" living flag packets and "+result.getAsJsonArray("events").size()+" completion events.");return;
    }
    var requestRows=new JsonArray();for(var e:requests.entrySet()){var p=e.getValue();var buf=new FriendlyByteBuf(Unpooled.buffer());
      try{ServerboundUseItemPacket.STREAM_CODEC.encode(buf,p);var c=new JsonObject();c.addProperty("name",e.getKey());c.addProperty("hand",p.hand()==InteractionHand.MAIN_HAND?"main":"off");c.addProperty("sequence",p.sequence());c.addProperty("yaw",(double)p.yRot());c.addProperty("pitch",(double)p.xRot());c.addProperty("wire",bytes(buf));requestRows.add(c);}finally{buf.release();}}
    var metadata=new JsonArray();for(int id:new int[]{1,127,128,Integer.MAX_VALUE})for(int flags:new int[]{0,1,2,3,127,128,255}){
      var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),RegistryAccess.EMPTY);try{ClientboundSetEntityDataPacket.STREAM_CODEC.encode(buf,new ClientboundSetEntityDataPacket(id,List.of(SynchedEntityData.DataValue.create(accessor,(byte)flags))));var c=new JsonObject();c.addProperty("entity_id",id);c.addProperty("flags",flags);c.addProperty("wire",bytes(buf));metadata.add(c);}finally{buf.release();}}
    var unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);var p=(Probe)unsafe.allocateInstance(Probe.class);p.world=(ProbeLevel)unsafe.allocateInstance(ProbeLevel.class);
    var update=LivingEntity.class.getDeclaredMethod("updatingUsingItem");update.setAccessible(true);var ticks=new JsonArray();
    for(var hand:InteractionHand.values())for(int remaining:new int[]{1,2,32,Integer.MAX_VALUE})for(var change:List.of("same","components","type","empty")){
      var original=new ItemStack(Items.STONE,2);p.current=switch(change){case "same"->new ItemStack(Items.STONE,1);case "components"->{var s=new ItemStack(Items.STONE);s.set(net.minecraft.core.component.DataComponents.FOOD,new FoodProperties(1,1,false));yield s;}case "type"->new ItemStack(Items.DIRT);default->ItemStack.EMPTY;};
      p.hand=hand;p.active=true;p.completed=0;p.stopped=0;field(LivingEntity.class,"useItem").set(p,original);field(LivingEntity.class,"useItemRemaining").set(p,remaining);update.invoke(p);
      var c=new JsonObject();c.addProperty("hand",hand==InteractionHand.MAIN_HAND?"main":"off");c.addProperty("remaining",remaining);c.addProperty("change",change);c.addProperty("next",p.getUseItemRemainingTicks());c.addProperty("active",p.active);c.addProperty("completed",p.completed);c.addProperty("stopped",p.stopped);c.addProperty("current",p.getUseItem()==p.current);ticks.add(c);
    }
    var events=new JsonArray();for(int id:new int[]{1,127,128,Integer.MAX_VALUE}){var entity=(Probe)unsafe.allocateInstance(Probe.class);entity.setId(id);var buf=new FriendlyByteBuf(Unpooled.buffer());try{ClientboundEntityEventPacket.STREAM_CODEC.encode(buf,new ClientboundEntityEventPacket(entity,(byte)9));var c=new JsonObject();c.addProperty("entity_id",id);c.addProperty("wire",bytes(buf));events.add(c);}finally{buf.release();}}
    var result=new JsonObject();result.add("requests",requestRows);result.add("metadata",metadata);result.add("ticks",ticks);result.add("events",events);Files.writeString(Path.of(args[1]),new Gson().toJson(result));
    System.out.println("PASS: "+requestRows.size()+" native use-item codecs, "+metadata.size()+" living flag codecs and "+ticks.size()+" native active-use tick prefixes; metadata state/start/finish effects excluded.");
  }
}
