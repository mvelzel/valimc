import com.google.gson.*;
import java.nio.file.*;
import java.util.*;
import net.minecraft.core.*;
import net.minecraft.core.registries.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.piston.*;
import net.minecraft.world.level.block.state.properties.*;
import net.minecraft.world.phys.*;

/** Actual moving-block ticks with a native player, without ticking the player's own movement. */
public class PistonPlayerOracle {
  public static void main(String[] args) throws Exception {
    var lookup = MiningToolOracle.initialize();
    BuiltInRegistries.DATA_COMPONENT_INITIALIZERS.build(lookup).forEach(p -> p.apply());
    var rows = new JsonArray();
    for (int origin : new int[] {0,127}) for (var face : Direction.values())
      for (var material : List.of(Blocks.STONE,Blocks.SLIME_BLOCK,Blocks.HONEY_BLOCK))
      for (boolean extending : List.of(false,true)) for (boolean crouch : List.of(false,true))
      for (boolean ground : List.of(false,true)) for (var placement : List.of("front","top","side","inside","far")) {
        var level = PistonOracle.probe(); level.cells = new HashMap<>(); level.entities = new HashMap<>();
        level.writes = new JsonArray(); level.sounds = new JsonArray(); level.events = new JsonArray();
        level.random = net.minecraft.util.RandomSource.create(7);
        level.rules = new net.minecraft.world.level.gamerules.GameRules(net.minecraft.world.flag.FeatureFlags.DEFAULT_FLAGS);
        for (int x=origin-6;x<=origin+6;x++) for (int z=-6;z<=6;z++) level.cells.put(new BlockPos(x,63,z),Blocks.STONE.defaultBlockState());
        var pos = new BlockPos(origin,66,0);
        var state = Blocks.MOVING_PISTON.defaultBlockState().setValue(MovingPistonBlock.FACING,face);
        var moving = new PistonMovingBlockEntity(pos,state,material.defaultBlockState(),face,extending,false);
        level.cells.put(pos,state); level.setBlockEntity(moving);
        var bounds = state.getCollisionShape(level,pos).bounds().move(pos);
        var player = new MobAiOracle.Fighter(level,1,GameType.SURVIVAL);
        player.setShiftKeyDown(crouch); player.setPose(crouch ? Pose.CROUCHING : Pose.STANDING);
        var direction = extending ? face : face.getOpposite();
        double x = (bounds.minX+bounds.maxX)/2, y = bounds.minY, z = (bounds.minZ+bounds.maxZ)/2;
        if (placement.equals("front")) {
          if (direction.getStepX() != 0) x = direction.getStepX() > 0 ? bounds.maxX+player.getBbWidth()/2.0 : bounds.minX-player.getBbWidth()/2.0;
          if (direction.getStepY() != 0) y = direction.getStepY() > 0 ? bounds.maxY : bounds.minY-player.getBbHeight();
          if (direction.getStepZ() != 0) z = direction.getStepZ() > 0 ? bounds.maxZ+player.getBbWidth()/2.0 : bounds.minZ-player.getBbWidth()/2.0;
        } else if (placement.equals("top")) y = bounds.maxY;
        else if (placement.equals("side")) x = bounds.maxX+player.getBbWidth()/2.0+.2;
        else if (placement.equals("far")) x += 4;
        player.setPos(x,y,z); player.setDeltaMovement(.17,-.11,.23); player.setOnGround(ground);
        level.things.add(player);
        var row = new JsonObject(); row.addProperty("face",face.get3DDataValue()); row.addProperty("material",BuiltInRegistries.BLOCK.getKey(material).toString());
        row.addProperty("extending",extending); row.addProperty("crouch",crouch); row.addProperty("ground",ground);
        row.add("pos",new Gson().toJsonTree(new int[] {pos.getX(),pos.getY(),pos.getZ()}));
        row.add("start",ShulkerBodyBoxOracle.point(player.position()));
        row.addProperty("simulates",player.canSimulateMovement()); row.addProperty("authoritative",player.isLocalInstanceAuthoritative());
        PistonMovingBlockEntity.tick(level,pos,state,moving);
        row.add("position",ShulkerBodyBoxOracle.point(player.position())); row.add("velocity",ShulkerBodyBoxOracle.point(player.getDeltaMovement()));
        row.addProperty("after_ground",player.onGround());
        var cells = new JsonArray();
        for (var p : level.cells.keySet()) if (!level.cell(p).isAir()) cells.add(RedstoneOracle.row(p,Block.getId(level.cell(p))));
        row.add("cells",cells); row.add("moving",PistonOracle.movingRows(level)); rows.add(row);
      }
    Files.writeString(Path.of(args[0]),new GsonBuilder().setPrettyPrinting().create().toJson(rows)+"\n");
    System.out.println("PASS: native player piston phases: "+rows.size());
  }
}
