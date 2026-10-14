import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import com.mojang.serialization.JsonOps;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.RegistryAccess;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.nbt.NbtOps;
import net.minecraft.nbt.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.world.item.*;
import net.minecraft.world.item.component.ItemLore;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.network.chat.*;

/** Original raw text fixtures and actual Mojang decode/equality expectations. */
public class TextOracle {
  private static RegistryAccess.Frozen registries;
  private static final List<Map<String,Object>> fixtures=new ArrayList<>();
  private static final List<Component> decoded=new ArrayList<>();
  private static final List<Map<String,Object>> loreFixtures=new ArrayList<>();
  private static void probe(String name,String json,boolean supported) {
    var tag=JsonOps.INSTANCE.convertTo(NbtOps.INSTANCE,JsonParser.parseString(json));
    probeTag(name,tag,supported);
  }
  private static void probeTag(String name,Tag tag,boolean supported) {
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    byte[] raw;
    try { buf.writeNbt(tag); raw=new byte[buf.readableBytes()];buf.readBytes(raw); }
    finally {buf.release();}
    var entry=new LinkedHashMap<String,Object>();
    entry.put("name",name);entry.put("input",HexFormat.of().formatHex(raw));entry.put("supported",supported);
    buf=new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(raw),registries);
    try {
      var component=ComponentSerialization.STREAM_CODEC.decode(buf);
      if (buf.isReadable()) throw new AssertionError("Trailing text fixture bytes");
      entry.put("accepted",true); entry.put("plain",component.getString());decoded.add(component);
      var canonical=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
      try {
        ComponentSerialization.STREAM_CODEC.encode(canonical,component);
        var bytes=new byte[canonical.readableBytes()];canonical.readBytes(bytes);
        entry.put("canonical",HexFormat.of().formatHex(bytes));
      } finally {canonical.release();}
    } catch (Exception error) {entry.put("accepted",false);decoded.add(null);}
    finally {buf.release();}
    fixtures.add(entry);
  }
  private static void numeric(String field,String name,Tag tag) {
    var root=new CompoundTag();root.putString("text","A");root.put(field,tag);
    probeTag(field+"/"+name,root,true);
  }
  private static RegistryFriendlyByteBuf buffer(String hex) {
    return new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(HexFormat.of().parseHex(hex)),registries);
  }
  private static void probeLore(int count) {
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    String hex;
    try {
      buf.writeVarInt(count);
      for(int i=0;i<count;i++)buf.writeNbt(StringTag.valueOf("line"));
      var bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);hex=HexFormat.of().formatHex(bytes);
    } finally {buf.release();}
    buf=buffer(hex);boolean accepted;
    try {accepted=DataComponents.LORE.streamCodec().decode(buf).lines().size()==count && !buf.isReadable();}
    catch(Exception error){accepted=false;}
    finally{buf.release();}
    loreFixtures.add(Map.of("count",count,"input",hex,"accepted",accepted));
  }
  private static void verify(String path) throws Exception {
    var rows=JsonParser.parseString(Files.readString(Path.of(path))).getAsJsonArray();
    for(var row:rows) {
      var object=row.getAsJsonObject();var expected=decoded.get(object.get("index").getAsInt());
      var text=buffer(object.get("text").getAsString());
      try { if(!expected.equals(ComponentSerialization.STREAM_CODEC.decode(text)) || text.isReadable())
        throw new AssertionError("Elixir text differs: "+object.get("index")); }
      finally {text.release();}
      var stack=new ItemStack(Items.STONE,1);
      stack.set(DataComponents.CUSTOM_NAME,expected);stack.set(DataComponents.ITEM_NAME,expected);
      stack.set(DataComponents.LORE,new ItemLore(List.of(expected,Component.literal("lore\u0000\uD83D\uDE80"))));
      for(var key:List.of("stack","untrusted")) {
        var buf=buffer(object.get(key).getAsString());
        try {
          var actual=(key.equals("stack")?ItemStack.OPTIONAL_STREAM_CODEC:ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC).decode(buf);
          if(!ItemStack.matches(stack,actual) || buf.isReadable()) throw new AssertionError("Elixir stack differs: "+object.get("index")+"/"+key);
        } finally {buf.release();}
      }
    }
    System.out.println("PASS: Mojang decoded "+rows.size()+" Elixir text/name/lore cases and both stack formats.");
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    registries=RegistryAccess.fromRegistryOfRegistries(BuiltInRegistries.REGISTRY).freeze();
    probe("string","\"A\"",true);
    probe("literal","{\"text\":\"A\"}",true);
    probe("typed-literal","{\"type\":\"text\",\"text\":\"A\"}",true);
    probe("ignored-field","{\"text\":\"A\",\"unknown\":123}",true);
    probe("empty-string","\"\"",true);
    probe("empty-literal","{\"text\":\"\"}",true);
    probe("sequence","[\"A\",\"B\"]",true);
    probe("extra","{\"text\":\"A\",\"extra\":[\"B\"]}",true);
    probe("nested-extra","{\"text\":\"A\",\"extra\":[[\"B\",\"C\"]]}",true);
    probe("mixed-sequence","[\"A\",{\"text\":\"B\",\"italic\":false}]",true);
    probe("translation","{\"translate\":\"block.minecraft.stone\"}",true);
    probe("translation-empty-args","{\"translate\":\"block.minecraft.stone\",\"with\":[]}",true);
    probe("translation-args","{\"translate\":\"test.key\",\"fallback\":\"Hello %s\",\"with\":[\"A\",2,0.5,{\"text\":\"B\",\"color\":\"gold\"}]}",true);
    probe("translation-literal-arg","{\"translate\":\"test.key\",\"with\":[\"A\"]}",true);
    probe("translation-component-arg","{\"translate\":\"test.key\",\"with\":[{\"text\":\"A\"}]}",true);
    probe("translation-missing-args","{\"translate\":\"test.key\"}",true);
    probe("translation-bad-fallback","{\"translate\":\"test.key\",\"fallback\":5}",true);
    probe("keybind","{\"keybind\":\"key.jump\"}",true);
    probe("two-contents","{\"text\":\"A\",\"translate\":\"test.key\"}",true);
    probe("bad-literal-good-keybind","{\"text\":1,\"keybind\":\"key.jump\"}",true);
    probe("bad-translation-good-keybind","{\"translate\":\"test.key\",\"with\":1,\"keybind\":\"key.jump\"}",true);
    probe("bad-translation-arg-good-keybind","{\"translate\":\"test.key\",\"with\":[{}],\"keybind\":\"key.jump\"}",true);
    for (String field:List.of("bold","italic","underlined","strikethrough","obfuscated"))
      for(String value:List.of("true","false","0","1","2","256","0.5","-0.5","\"true\""))
        probe(field+"/"+value,"{\"text\":\"A\",\""+field+"\":"+value+"}",true);
    for(String color:List.of("gold","#ffaa00","#FFAA00","#f","#00000f","#00ffffff","#1000000","Gold","reset","bad"))
      probe("color/"+color,"{\"text\":\"A\",\"color\":\""+color+"\"}",true);
    for(String font:List.of("default","minecraft:default","Bad:Font","",":default"))
      probe("font/"+font,"{\"text\":\"A\",\"font\":\""+font+"\"}",true);
    for(String shadow:List.of("-1","0","16777215","[1,0.5,0,1]","[1,0,0,1]","[1,0,0]","[2,0,0,1]"))
      probe("shadow/"+shadow,"{\"text\":\"A\",\"shadow_color\":"+shadow+"}",true);
    probe("insertion","{\"text\":\"A\",\"insertion\":\"paste me\"}",true);
    probe("bad-insertion","{\"text\":\"A\",\"insertion\":1}",true);
    probe("empty-extra","{\"text\":\"A\",\"extra\":[]}",true);
    probe("empty-root-list","[]",true);
    probe("bad-root","42",true);
    probe("missing-contents","{}",true);
    probe("bad-type","{\"type\":\"bogus\",\"text\":\"A\"}",true);
    probe("bad-type-translate","{\"type\":\"translate\",\"translate\":\"test.key\"}",true);
    probe("typed-translation","{\"type\":\"translatable\",\"translate\":\"test.key\"}",true);
    probe("unicode","{\"text\":\"ValiMC \\u0000 \\ud83d\\ude80\",\"extra\":[\"é\"]}",true);
    for(String shadow:List.of("[-0.1,0,0,1]","[0.1,0.4,0.7,0.999]","[1e100,0,0,1]","0.5","4294967295"))
      probe("shadow/"+shadow,"{\"text\":\"A\",\"shadow_color\":"+shadow+"}",true);
    for(String color:List.of("#+f","#-0","#","#000000000000000f"))
      probe("color/"+color,"{\"text\":\"A\",\"color\":\""+color+"\"}",true);
    numeric("bold","nan",FloatTag.valueOf(Float.NaN));
    numeric("bold","infinity",DoubleTag.valueOf(Double.POSITIVE_INFINITY));
    numeric("shadow_color","nan",DoubleTag.valueOf(Double.NaN));
    numeric("shadow_color","negative-infinity",DoubleTag.valueOf(Double.NEGATIVE_INFINITY));
    for(Tag value:List.of(ByteTag.valueOf((byte)1),IntTag.valueOf(1),FloatTag.valueOf(1),DoubleTag.valueOf(1),
      FloatTag.valueOf(Float.NaN),DoubleTag.valueOf(Double.NaN),FloatTag.valueOf(-0.0f))) {
      var root=new CompoundTag();root.putString("translate","test.key");
      var argsList=new ListTag();argsList.add(value);root.put("with",argsList);
      probeTag("translation/"+value.getType()+"/"+value,root,true);
    }
    probe("selector","{\"selector\":\"@p\"}",false);
    probe("event","{\"text\":\"A\",\"click_event\":{\"action\":\"run_command\",\"command\":\"/help\"}}",false);
    for(int count:List.of(0,1,256,257))probeLore(count);
    var equality=new ArrayList<List<Integer>>();
    for(int i=0;i<decoded.size();i++)for(int j=i;j<decoded.size();j++)
      if(decoded.get(i)!=null && decoded.get(j)!=null && (boolean)fixtures.get(i).get("supported") && (boolean)fixtures.get(j).get("supported"))
        equality.add(List.of(i,j,decoded.get(i).equals(decoded.get(j))?1:0));
    if(args[0].equals("verify")) {verify(args[1]);return;}
    Files.writeString(Path.of(args[0]),new Gson().toJson(Map.of("fixtures",fixtures,"equality",equality,"lore",loreFixtures)));
    System.out.println("PASS: Generated "+fixtures.size()+" raw Mojang text cases and "+equality.size()+" actual equality pairs.");
  }
}
