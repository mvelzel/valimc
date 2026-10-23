import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.*;
import net.minecraft.core.registries.Registries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.chat.*;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.*;
import io.netty.buffer.Unpooled;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.damagesource.*;
import net.minecraft.world.entity.LivingEntity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.GameType;

/** Native environmental death-message components with a plain name and no attacker/kill credit. */
public class DamageMessageOracle {
  static class Body extends Player {
    String name;
    private Body(){super(null,null);}
    public GameType gameMode(){return GameType.SURVIVAL;}
    public Component getDisplayName(){return Component.literal(name);}
    public LivingEntity getKillCredit(){return null;}
  }
  @SuppressWarnings({"rawtypes","unchecked"})
  static String wire(Object packet){
    var buffer=new RegistryFriendlyByteBuf(Unpooled.buffer(),RegistryAccess.EMPTY);
    try{GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,RegistryAccess.EMPTY)).codec().encode(buffer,(Packet)packet);var bytes=new byte[buffer.readableBytes()];buffer.readBytes(bytes);return HexFormat.of().formatHex(bytes);}finally{buffer.release();}
  }
  public static void main(String[] args)throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    var field=sun.misc.Unsafe.class.getDeclaredField("theUnsafe");field.setAccessible(true);var u=(sun.misc.Unsafe)field.get(null);var body=(Body)u.allocateInstance(Body.class);
    if(args[0].equals("verify")){
      var rows=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for(var entry:rows){var row=entry.getAsJsonObject();body.name=row.get("name").getAsString();var key=net.minecraft.resources.ResourceKey.create(Registries.DAMAGE_TYPE,net.minecraft.resources.Identifier.withDefaultNamespace(row.get("source").getAsString()));var message=new DamageSource(lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(key)).getLocalizedDeathMessage(body);Object expected=row.get("kind").getAsString().equals("death")?new ClientboundPlayerCombatKillPacket(row.get("entity").getAsInt(),message):new ClientboundSystemChatPacket(message,false);
        var buffer=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(row.get("wire").getAsString())),RegistryAccess.EMPTY);
        try{var decoded=GameProtocols.CLIENTBOUND_TEMPLATE.bind(b->new RegistryFriendlyByteBuf(b,RegistryAccess.EMPTY)).codec().decode(buffer);if(buffer.isReadable()||!wire(decoded).equals(wire(expected)))throw new AssertionError("Native death component differs "+row);}finally{buffer.release();}}
      System.out.println("PASS: "+rows.size()+" independently encoded death/chat packets decode to actual native source-specific messages.");return;
    }
    var facts=new JsonObject();facts.addProperty("version","26.3");facts.addProperty("data_version",5023);facts.addProperty("server_sha1","33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c");var keys=new JsonObject();var typeFacts=new JsonObject();var cases=new JsonArray();
    var types=List.of(DamageTypes.FALL,DamageTypes.STALAGMITE,DamageTypes.FREEZE,DamageTypes.DROWN,DamageTypes.FELL_OUT_OF_WORLD,DamageTypes.OUTSIDE_BORDER,DamageTypes.STARVE,DamageTypes.ON_FIRE,DamageTypes.IN_FIRE,DamageTypes.LAVA,DamageTypes.HOT_FLOOR,DamageTypes.CAMPFIRE,DamageTypes.CACTUS,DamageTypes.SWEET_BERRY_BUSH,DamageTypes.GENERIC,DamageTypes.MAGIC,DamageTypes.WITHER,DamageTypes.GENERIC_KILL,DamageTypes.EXPLOSION);
    for(var type:types)for(String name:List.of("ValiMCTest","Player_42")){
      body.name=name;var source=new DamageSource(lookup.lookupOrThrow(Registries.DAMAGE_TYPE).getOrThrow(type));var message=source.getLocalizedDeathMessage(body);var json=ComponentSerialization.CODEC.encodeStart(JsonOps.INSTANCE,message).getOrThrow().getAsJsonObject();
      keys.addProperty(type.identifier().getPath(),json.get("translate").getAsString());var fact=new JsonObject();fact.addProperty("exhaustion",(double)source.getFoodExhaustion());fact.addProperty("scaling",source.type().scaling().getSerializedName());typeFacts.add(type.identifier().getPath(),fact);var row=new JsonObject();row.addProperty("source",type.identifier().getPath());row.addProperty("name",name);row.add("message",json);cases.add(row);
    }
    facts.add("keys",keys);facts.add("types",typeFacts);Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(facts)+"\n");Files.writeString(Path.of(args[1]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" actual no-attacker environmental/periodic death messages across all16 implemented/fallback sources. Attacker/team/display-name variants excluded.");
  }
}
