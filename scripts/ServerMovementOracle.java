import com.google.gson.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.server.level.*;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.world.TickRateManager;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.*;
import net.minecraft.world.phys.*;
import net.minecraft.world.phys.shapes.*;

/** Original controlled post-move fixtures invoke the actual native packet handler. */
public class ServerMovementOracle {
  private static sun.misc.Unsafe unsafe;
  private static Field position, bounds;
  private static Method handle;
  private static class Outcome extends RuntimeException {
    final boolean rejected;
    Outcome(boolean rejected){super(null,null,false,false);this.rejected=rejected;}
  }
  private static class FrozenTicks extends TickRateManager {
    public boolean runsNormally(){return false;}
  }
  private static class FixtureLevel extends ServerLevel {
    boolean oldClear; List<VoxelShape> supplied,used; AABB query;
    private FixtureLevel(){super(null,null,null,null,null,null,false,0L,List.of(),false);}
    public TickRateManager tickRateManager(){return new FrozenTicks();}
    public boolean noCollision(Entity entity,AABB box){return oldClear;}
    public Iterable<VoxelShape> getPreMoveCollisions(Entity entity,AABB box,Vec3 previousBottom){
      query=box;var shape=Shapes.create(box);
      used=supplied.stream().filter(s->Shapes.joinIsNotEmpty(s,shape,BooleanOp.AND)).toList();
      return used;
    }
  }
  private static class FixturePlayer extends ServerPlayer {
    FixtureLevel world; Vec3 moved; GameType mode; boolean impulse,changing;
    private FixturePlayer(){super(null,null,null,null);}
    public ServerLevel level(){return world;}
    public boolean isSleeping(){return false;}
    public boolean isFallFlying(){return false;}
    public boolean isCreative(){return mode==GameType.CREATIVE;}
    public boolean isSpectator(){return mode==GameType.SPECTATOR;}
    public boolean isInPostImpulseGraceTime(){return impulse;}
    public boolean isChangingDimension(){return changing;}
    public String getPlainTextName(){return "controlled-movement-probe";}
    public void move(MoverType type,Vec3 movement){
      try {
        var before=position();
        bounds.set(this,getBoundingBox().move(moved.x-before.x,moved.y-before.y,moved.z-before.z));
        position.set(this,moved);
      } catch(Exception error){throw new RuntimeException(error);}
    }
    public void absSnapTo(double x,double y,double z,float yaw,float pitch){throw new Outcome(false);}
  }
  private static class FixtureListener extends ServerGamePacketListenerImpl {
    private FixtureListener(){super(null,null,null,null);}
    public void teleport(double x,double y,double z,float yaw,float pitch){throw new Outcome(true);}
  }
  private static Field field(Class<?> type,String name) throws Exception {
    var f=type.getDeclaredField(name);f.setAccessible(true);return f;
  }
  private static JsonArray vector(double... values){var out=new JsonArray();for(double value:values)out.add(value);return out;}
  private static JsonArray vector(Vec3 value){return vector(value.x,value.y,value.z);}
  private static JsonArray box(AABB b){return vector(b.minX,b.minY,b.minZ,b.maxX,b.maxY,b.maxZ);}
  public static void main(String[] args) throws Throwable {
    SharedConstants.tryDetectVersion();Bootstrap.bootStrap();
    unsafe=(sun.misc.Unsafe)field(sun.misc.Unsafe.class,"theUnsafe").get(null);
    position=field(Entity.class,"position");bounds=field(Entity.class,"bb");
    handle=ServerGamePacketListenerImpl.class.getDeclaredMethod("handlePlayerPositionChange",
      double.class,double.class,double.class,float.class,float.class,boolean.class,boolean.class);
    handle.setAccessible(true);var playerField=field(ServerGamePacketListenerImpl.class,"player");
    var velocity=field(Entity.class,"deltaMovement");var cases=new JsonArray();
    for(double origin:new double[]{0,-17.125,29999900})
      for(var mode:List.of(GameType.SURVIVAL,GameType.CREATIVE,GameType.ADVENTURE,GameType.SPECTATOR))
        for(int flags=0;flags<16;flags++)
          for(double error:new double[]{0,Math.nextDown(.25),.25,Math.nextUp(.25),.5,1})
            for(double vertical:new double[]{-2,0,2})for(int layout=0;layout<6;layout++) {
              var old=new Vec3(origin,64,-origin);var target=old.add(1,vertical,.5);
              var moved=new Vec3(target.x-error,64,target.z);
              var oldBox=new AABB(origin-.3,64,-origin-.3,origin+.3,65.8,-origin+.3);
              var wall=Shapes.create(new AABB(origin+.75,63,-origin,origin+1.25,68,-origin+1));
              var overlap=Shapes.create(new AABB(origin-.2,63,-origin-.2,origin+.2,68,-origin+.2));
              List<VoxelShape> supplied=switch(layout) {
                case 0->List.of();case 1->List.of(wall);case 2->List.of(overlap);
                case 3->List.of(Shapes.or(overlap,wall));
                default->List.of(Shapes.create(new AABB(origin+.3-(layout==4?.5:2)*9.999999747378752e-6,
                  63,-origin-.2,origin+1.25,68,-origin+.75)));
              };
              var world=(FixtureLevel)unsafe.allocateInstance(FixtureLevel.class);
              world.oldClear=(flags&8)!=0;world.supplied=supplied;world.used=List.of();
              var player=(FixturePlayer)unsafe.allocateInstance(FixturePlayer.class);
              player.world=world;player.moved=moved;player.mode=mode;
              player.impulse=(flags&2)!=0;player.changing=(flags&4)!=0;player.noPhysics=(flags&1)!=0;
              position.set(player,old);bounds.set(player,oldBox);velocity.set(player,Vec3.ZERO);
              var listener=(FixtureListener)unsafe.allocateInstance(FixtureListener.class);
              playerField.set(listener,player);boolean rejected;
              try {
                handle.invoke(listener,target.x,target.y,target.z,0f,0f,false,false);
                throw new AssertionError("Native handler never reached a decision");
              } catch(InvocationTargetException wrapped) {
                if(wrapped.getCause() instanceof Outcome outcome)rejected=outcome.rejected;
                else throw wrapped.getCause();
              }
              var c=new JsonObject();c.add("requested",vector(target));c.add("moved",vector(moved));
              c.add("old_box",box(oldBox));c.addProperty("mode",mode.getName());
              c.addProperty("no_physics",player.noPhysics);c.addProperty("impulse",player.impulse);
              c.addProperty("changing_dimension",player.changing);c.addProperty("old_clear",world.oldClear);
              var shapes=new JsonArray();for(var shape:world.used)shapes.add(BlockFactsOracle.geometry(shape));
              c.add("new_colliders",shapes);c.addProperty("queried_new",world.query!=null);
              c.addProperty("rejected",rejected);cases.add(c);
            }
    Files.writeString(Path.of(args[0]),new Gson().toJson(cases));
    System.out.println("PASS: "+cases.size()+" actual native post-move decisions; controlled supplied movement/occupancy, not full physics.");
  }
}
