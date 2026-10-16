import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.*;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.*;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.*;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.item.*;
import net.minecraft.world.level.GameType;

/** Original self-attributed magic event/message fixtures; no damage or inventory simulation. */
public class SelfMagicOracle {
  static class Body extends Player {
    String label; ItemStack hand;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public Component getDisplayName(){return Component.literal(label);}
    public ItemStack getMainHandItem(){return hand;}
  }
  static RegistryAccess.Frozen access;
  @SuppressWarnings({"rawtypes","unchecked"})
  static String wire(Object packet){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
    try {
      GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().encode(buffer,(Packet)packet);
      byte[] bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);
      return HexFormat.of().formatHex(bytes);
    } finally {buffer.release();}
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var original=lookup.lookupOrThrow(Registries.DAMAGE_TYPE);
    var damage=new MappedRegistry<DamageType>(Registries.DAMAGE_TYPE,Lifecycle.stable());
    for(var key:original.listElementIds().sorted(Comparator.comparing(k->k.identifier().toString())).toList())
      damage.register(key,original.getOrThrow(key).value(),RegistrationInfo.BUILT_IN);
    damage.freeze();access=new RegistryAccess.ImmutableRegistryAccess(List.of(damage)).freeze();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);
    var body=(Body)((sun.misc.Unsafe)field.get(null)).allocateInstance(Body.class);
    var rows=new JsonArray();
    for(int id:new int[]{1,127,128,Integer.MAX_VALUE})for(String name:List.of("ValiMCTest","Player_42"))
      for(String held:List.of("empty","potion","named_potion","item_name_only")){
        body.setId(id);body.label=name;
        body.hand=held.equals("empty")?ItemStack.EMPTY:new ItemStack(Items.POTION);
        if(held.equals("named_potion"))body.hand.set(DataComponents.CUSTOM_NAME,Component.literal("Unsafe brew"));
        if(held.equals("item_name_only"))body.hand.set(DataComponents.ITEM_NAME,Component.literal("Renamed item type"));
        var source=new DamageSource(damage.getOrThrow(DamageTypes.INDIRECT_MAGIC),body,body);
        var message=source.getLocalizedDeathMessage(body);
        var event=new ClientboundDamageEventPacket(body,source);
        var row=new JsonObject();row.addProperty("entity",id);row.addProperty("name",name);row.addProperty("held",held);
        row.addProperty("event",wire(event));row.add("message",ComponentSerialization.CODEC.encodeStart(JsonOps.INSTANCE,message).getOrThrow());
        row.addProperty("death",wire(new ClientboundPlayerCombatKillPacket(id,message)));
        row.addProperty("chat",wire(new ClientboundSystemChatPacket(message,false)));rows.add(row);
      }
    if(args[0].equals("verify")) {
      var candidates=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      int checked=0;
      for(var entry:candidates){
        var candidate=entry.getAsJsonObject();JsonObject expected=null;
        for(var nativeRow:rows){var row=nativeRow.getAsJsonObject();
          if(row.get("entity").equals(candidate.get("entity")) && row.get("name").equals(candidate.get("name")) && row.get("held").equals(candidate.get("held")))expected=row;
        }
        if(expected==null)throw new AssertionError("Unknown fixture");
        for(String kind:List.of("event","death","chat"))if(candidate.has(kind)){
          var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(candidate.get(kind).getAsString())),access);
          try {
            var decoded=GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,access)).codec().decode(buffer);
            if(buffer.isReadable() || !wire(decoded).equals(expected.get(kind).getAsString()))throw new AssertionError("Self magic packet differs: "+candidate);
            checked++;
          } finally {buffer.release();}
        }
      }
      System.out.println("PASS: "+checked+" Elixir self-magic packets decode to independently constructed native packets; named-item components remain excluded.");return;
    }
    Files.writeString(Path.of(args[0]),new Gson().toJson(rows));
    System.out.println("PASS: "+rows.size()+" native self-magic event/death/chat fixtures, entity-ID boundaries and custom-name versus item-name variants; runtime health/inventory excluded.");
  }
}
