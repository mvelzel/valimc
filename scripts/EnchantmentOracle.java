import java.nio.file.*;
import java.util.*;
import com.google.gson.*;
import com.mojang.serialization.Lifecycle;
import io.netty.buffer.Unpooled;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.core.component.DataComponents;
import net.minecraft.data.registries.VanillaRegistries;
import net.minecraft.network.RegistryFriendlyByteBuf;
import net.minecraft.world.item.*;
import net.minecraft.world.item.enchantment.*;

/** Original differential fixtures: negotiated holder IDs, native map decoding and equality. */
public class EnchantmentOracle {
  private static RegistryAccess.Frozen registries;
  private static final List<String> names=new ArrayList<>();
  private static final List<Map<String,Object>> fixtures=new ArrayList<>();
  private static final List<ItemEnchantments> decoded=new ArrayList<>();
  private static RegistryFriendlyByteBuf buffer(byte[] bytes) {
    return new RegistryFriendlyByteBuf(Unpooled.wrappedBuffer(bytes),registries);
  }
  private static byte[] raw(int count,int... entries) {
    var buf=new RegistryFriendlyByteBuf(Unpooled.buffer(),registries);
    try {
      buf.writeVarInt(count);for(int value:entries)buf.writeVarInt(value);
      byte[] bytes=new byte[buf.readableBytes()];buf.readBytes(bytes);return bytes;
    } finally {buf.release();}
  }
  private static void probe(String name,byte[] raw,boolean bounded) {
    var row=new LinkedHashMap<String,Object>();row.put("name",name);
    row.put("input",HexFormat.of().formatHex(raw));row.put("bounded",bounded);
    var buf=buffer(raw);
    try {
      var result=ItemEnchantments.STREAM_CODEC.decode(buf);
      if(buf.isReadable())throw new IllegalArgumentException("Trailing fixture bytes");
      var values=new TreeMap<String,Integer>();
      for(var holder:result.keySet())values.put(holder.unwrapKey().orElseThrow().identifier().toString(),result.getLevel(holder));
      row.put("accepted",true);row.put("values",values);decoded.add(result);
    } catch(Exception error) {row.put("accepted",false);decoded.add(null);}
    finally {buf.release();}
    fixtures.add(row);
  }
  private static void generate() {
    probe("empty",raw(0),true);
    for(int id=0;id<names.size();id++)for(int level:List.of(0,1,3,255))
      probe(names.get(id)+"/"+level,raw(1,id,level),true);
    probe("ordered",raw(3,0,1,13,2,40,3),true);
    probe("reversed",raw(3,40,3,13,2,0,1),true);
    probe("duplicate-last",raw(2,40,1,40,3),true);
    probe("duplicate-negative-overwritten",raw(2,40,-1,40,3),true);
    probe("duplicate-large-overwritten",raw(2,40,256,40,3),true);
    probe("duplicate-zero-last",raw(2,40,3,40,0),true);
    probe("negative-level",raw(1,40,-1),true);
    probe("large-level",raw(1,40,256),true);
    probe("negative-final",raw(2,40,3,40,-1),true);
    probe("large-final",raw(2,40,3,40,256),true);
    probe("unknown-id",raw(1,names.size(),1),true);
    probe("negative-id",raw(1,-1,1),true);
    probe("unknown-overwritten",raw(2,names.size(),1,40,3),true);
    probe("negative-count",raw(-1),true);
    probe("truncated-level",raw(1,40),true);
    probe("truncated-entry",raw(1),true);
    probe("trailing-data",raw(0,0),true);
    int[] all=new int[names.size()*2];
    for(int i=0;i<names.size();i++){all[i*2]=i;all[i*2+1]=i%256;}
    probe("all-registry-entries",raw(names.size(),all),true);
    for(int count:List.of(1024,1025)) {
      int[] duplicates=new int[count*2];
      for(int i=0;i<count;i++){duplicates[i*2]=40;duplicates[i*2+1]=i%256;}
      probe("raw-count/"+count,raw(count,duplicates),count<=1024);
    }
  }
  private static void verify(String path) throws Exception {
    var rows=JsonParser.parseString(Files.readString(Path.of(path))).getAsJsonArray();
    for(var row:rows) {
      var object=row.getAsJsonObject();var expected=decoded.get(object.get("index").getAsInt());
      var buf=buffer(HexFormat.of().parseHex(object.get("value").getAsString()));
      try {
        if(!expected.equals(ItemEnchantments.STREAM_CODEC.decode(buf))||buf.isReadable())
          throw new AssertionError("Elixir enchantment value differs: "+object.get("index"));
      }finally{buf.release();}
      var stack=new ItemStack(Items.STONE,2);stack.set(DataComponents.ENCHANTMENTS,expected);
      stack.set(DataComponents.STORED_ENCHANTMENTS,expected);
      for(var key:List.of("stack","untrusted")) {
        buf=buffer(HexFormat.of().parseHex(object.get(key).getAsString()));
        try {
          var actual=(key.equals("stack")?ItemStack.OPTIONAL_STREAM_CODEC:ItemStack.OPTIONAL_UNTRUSTED_STREAM_CODEC).decode(buf);
          if(!ItemStack.matches(stack,actual)||buf.isReadable())
            throw new AssertionError("Elixir enchantment stack differs: "+object.get("index")+"/"+key);
        }finally{buf.release();}
      }
    }
    System.out.println("PASS: Mojang decoded "+rows.size()+" Elixir enchantment maps and both stack formats.");
  }
  public static void main(String[] args) throws Exception {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    var lookup=VanillaRegistries.createWorldLookup();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p->p.apply());
    var source=lookup.lookupOrThrow(Registries.ENCHANTMENT);
    var mapped=new MappedRegistry<Enchantment>(Registries.ENCHANTMENT,Lifecycle.stable());
    source.listElements().sorted(Comparator.comparing(h->h.key().identifier().toString())).forEach(h->{
      names.add(h.key().identifier().toString());mapped.register(h.key(),h.value(),RegistrationInfo.BUILT_IN);
    });
    mapped.bindAllTagsToEmpty();mapped.freeze();
    var all=new ArrayList<Registry<?>>(BuiltInRegistries.REGISTRY.stream().toList());all.add(mapped);
    registries=new RegistryAccess.ImmutableRegistryAccess(all).freeze();
    generate();
    if(args[0].equals("verify")){verify(args[1]);return;}
    var pairs=new ArrayList<List<Integer>>();
    for(int i=0;i<decoded.size();i++)for(int j=i;j<decoded.size();j++)
      if(decoded.get(i)!=null&&decoded.get(j)!=null&&(boolean)fixtures.get(i).get("bounded")&&(boolean)fixtures.get(j).get("bounded"))
        pairs.add(List.of(i,j,decoded.get(i).equals(decoded.get(j))?1:0));
    Files.writeString(Path.of(args[0]),new Gson().toJson(Map.of("registry",names,"fixtures",fixtures,"equality",pairs)));
    System.out.println("PASS: Generated "+fixtures.size()+" actual enchantment decode cases and "+pairs.size()+" equality pairs across "+names.size()+" holder IDs.");
  }
}
