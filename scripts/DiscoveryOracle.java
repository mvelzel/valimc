import java.nio.file.*;
import java.net.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;
import java.util.function.*;
import com.google.gson.*;
import com.mojang.authlib.minecraft.client.ObjectMapper;
import com.mojang.authlib.services.MinecraftServicesDiscoveryService;
import com.mojang.authlib.services.RetryableFetch;
import com.mojang.authlib.services.response.discovery.*;

/** Original synthetic harness for pinned authlib routing and refresh behavior. */
public final class DiscoveryOracle {
  private static final class Recorder extends ScheduledThreadPoolExecutor {
    Runnable pending; long delay;
    Recorder(){super(1);}
    @Override public void execute(Runnable task){pending=task;}
    @Override public ScheduledFuture<?> schedule(Runnable task,long interval,TimeUnit unit){pending=task;delay=unit.toMillis(interval);return null;}
    void runNext(){var task=pending;pending=null;task.run();}
  }

  public static void main(String[] args) throws Exception {
    var lines=new ArrayList<String>();
    var ctor=MinecraftServicesDiscoveryService.class.getDeclaredConstructor(Proxy.class,boolean.class,Supplier.class);
    ctor.setAccessible(true);
    var mapper=ObjectMapper.create();
    String route="https://sessionserver.mojang.com/session/minecraft/hasJoined";
    for(int i=0;i<16;i++) {
      var doc=new JsonObject();
      doc.addProperty("environment",i%4==0?"offline":i%4==1?"prod":i%4==2?"OFFLINE":"custom");
      doc.addProperty("product","minecraft");
      var discovery=new JsonObject();var session=new JsonObject();var endpoints=new JsonObject();var verify=new JsonObject();
      if(i%3!=0)verify.addProperty("uri",route+(i%2==0?"?feature=current":""));
      if(i%5!=0)endpoints.add("verify",verify);
      session.add("endpoints",endpoints);discovery.add("session",session);doc.add("discovery",discovery);
      var value=mapper.readValue(doc.toString(),DiscoveryResponse.class);
      var service=ctor.newInstance(Proxy.NO_PROXY,false,(Supplier<DiscoveryResponse>)()->value);
      String selected=null;
      try{selected=service.getUrl(Service.SESSION,"verify");}catch(RuntimeException expected){}
      var row=new JsonObject();row.addProperty("body",doc.toString());
      if(selected==null)row.add("route",JsonNull.INSTANCE);else row.addProperty("route",selected);
      row.addProperty("type","route");lines.add(row.toString());
    }
    for(String body:List.of(
      "{\"environment\":{}}", "{\"product\":[]}",
      "{\"environment\":\"offline\",\"discovery\":42}",
      "{\"discovery\":{\"authentication\":{\"endpoints\":{\"other\":{\"uri\":[]}}}}}",
      "{\"discovery\":{\"profiles\":{\"endpoints\":{\"other\":{\"validUris\":[{}]}}}}}"
    )) {
      boolean rejected=false;
      try{mapper.readValue(body,DiscoveryResponse.class);}catch(RuntimeException expected){rejected=true;}
      if(!rejected)throw new AssertionError("Native malformed discovery unexpectedly accepted");
      var row=new JsonObject();row.addProperty("type","invalid");row.addProperty("body",body);lines.add(row.toString());
    }
    var executor=new Recorder();
    try {
      var response=new AtomicReference<Optional<String>>(Optional.empty());
      var value=RetryableFetch.fetch(()->url(),executor,ignored->response.get(),"offline",24,1);
      for(int i=0;i<9;i++) {
        executor.runNext();
        var row=new JsonObject();row.addProperty("type","retry");row.addProperty("loaded",false);row.addProperty("failures",i);row.addProperty("delay",executor.delay);
        if(!value.get().equals("offline"))throw new AssertionError("Initial offline fallback mismatch");
        lines.add(row.toString());
      }
      response.set(Optional.of("first"));executor.runNext();
      if(!value.get().equals("first"))throw new AssertionError("Successful document missing");
      response.set(Optional.empty());executor.runNext();
      if(!value.get().equals("first"))throw new AssertionError("Failed refresh discarded cache");
      var row=new JsonObject();row.addProperty("type","retry");row.addProperty("loaded",true);row.addProperty("failures",0);row.addProperty("delay",executor.delay);lines.add(row.toString());
      response.set(Optional.of("offline"));executor.runNext();
      if(!value.get().equals("offline") || executor.delay!=86_400_000)throw new AssertionError("Offline document publication mismatch");
    } finally {executor.shutdownNow();}
    Files.write(Path.of(args[0]),lines);
    System.out.println("PASS: 16 native discovery routes, five malformed schemas and 10 retry/refresh/cache cases.");
  }
  private static URL url(){try{return URI.create("https://synthetic.invalid/discovery").toURL();}catch(Exception e){throw new RuntimeException(e);}}
}
