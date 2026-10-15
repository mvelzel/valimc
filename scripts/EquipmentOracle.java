import com.google.gson.*;
import com.mojang.datafixers.util.Pair;
import io.netty.buffer.Unpooled;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.component.DataComponents;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.protocol.game.ClientboundSetEquipmentPacket;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.entity.EquipmentSlot;
import net.minecraft.world.item.*;

/** Original bounded equipment packet fixtures; invokes the native codec in both directions. */
public class EquipmentOracle {
  private static Map<String,ClientboundSetEquipmentPacket> cases(){
    var result=new LinkedHashMap<String,ClientboundSetEquipmentPacket>();
    for(int id:new int[]{1,127,128,Integer.MAX_VALUE}){
      for(var slot:EquipmentSlot.values())for(int kind:new int[]{0,1,2}){
        var stack=kind==0?ItemStack.EMPTY:new ItemStack(Items.BREAD,kind==1?1:64);
        if(kind==2)stack.set(DataComponents.ENCHANTMENT_GLINT_OVERRIDE,true);
        result.put("equipment_"+result.size(),new ClientboundSetEquipmentPacket(id,List.of(Pair.of(slot,stack))));
      }
      var slots=new ArrayList<Pair<EquipmentSlot,ItemStack>>();
      for(var slot:EquipmentSlot.values()){
        var stack=slot==EquipmentSlot.MAINHAND?new ItemStack(Items.BREAD,2):slot==EquipmentSlot.HEAD?new ItemStack(Items.IRON_HELMET):ItemStack.EMPTY;
        slots.add(Pair.of(slot,stack));
        result.put("equipment_"+result.size(),new ClientboundSetEquipmentPacket(id,List.copyOf(slots)));
      }
    }
    return result;
  }
  public static void main(String[] args)throws Exception{
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var access=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();var cases=cases();
    if(args[0].equals("verify")){
      var rows=JsonParser.parseString(Files.readString(Path.of(args[1]))).getAsJsonArray();
      for(var entry:rows){var row=entry.getAsJsonObject();var expected=cases.get(row.get("name").getAsString());
        var buf=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(row.get("wire").getAsString())),access);
        try{var actual=ClientboundSetEquipmentPacket.STREAM_CODEC.decode(buf);
          if(buf.isReadable()||expected==null||actual.getEntity()!=expected.getEntity()||actual.getSlots().size()!=expected.getSlots().size())throw new AssertionError(row);
          for(int i=0;i<actual.getSlots().size();i++){var a=actual.getSlots().get(i);var e=expected.getSlots().get(i);if(a.getFirst()!=e.getFirst()||!ItemStack.matches(a.getSecond(),e.getSecond()))throw new AssertionError(row);}
        }finally{buf.release();}
      }
      if(rows.size()!=cases.size())throw new AssertionError("Missing equipment cases");
      System.out.println("PASS: native decoding of "+rows.size()+" equipment packets.");return;
    }
    var rows=new JsonArray();for(var e:cases.entrySet()){
      var packet=e.getValue();var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),access);
      try{ClientboundSetEquipmentPacket.STREAM_CODEC.encode(buf,packet);var raw=new byte[buf.readableBytes()];buf.readBytes(raw);
        var row=new JsonObject();row.addProperty("name",e.getKey());row.addProperty("entity_id",packet.getEntity());row.addProperty("wire",HexFormat.of().formatHex(raw));var slots=new JsonArray();
        for(var pair:packet.getSlots()){var stack=pair.getSecond();var slot=new JsonObject();slot.addProperty("slot",pair.getFirst().ordinal());slot.addProperty("item_id",stack.isEmpty()?0:BuiltInRegistries.ITEM.getId(stack.getItem()));slot.addProperty("count",stack.getCount());slot.addProperty("glint",Boolean.TRUE.equals(stack.get(DataComponents.ENCHANTMENT_GLINT_OVERRIDE)));slots.add(slot);}
        row.add("slots",slots);rows.add(row);
      }finally{buf.release();}
    }
    Files.writeString(Path.of(args[1]),new Gson().toJson(rows));System.out.println("PASS: generated "+rows.size()+" native equipment codecs across "+EquipmentSlot.values().length+" slots.");
  }
}
