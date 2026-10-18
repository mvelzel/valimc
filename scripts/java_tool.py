#!/usr/bin/env python3
"""Run development tools against the official Minecraft jar, never the server runtime."""
import os, pathlib, subprocess, sys, shutil
root = pathlib.Path(__file__).resolve().parent.parent
bundle = root / 'research/vanilla-bundle'
jars = sorted((bundle / 'libraries').rglob('*.jar'))
jars += [bundle / 'versions/26.3/server-26.3.jar']
classpath = os.pathsep.join(str(p) for p in jars)
from java_runtime import java_home as find_java_home
java_home = find_java_home()
tools = root / 'research/java-tools'
tools.mkdir(exist_ok=True)
name = sys.argv[1]
sources = [str(root / 'scripts' / (name + '.java'))]
if name in ('FluidFlowOracle', 'FluidCurrentOracle', 'ItemCurrentOracle', 'ItemTravelOracle'):
    sources.append(str(root / 'scripts' / 'FluidBoundaryMetadata.java'))
if name == 'FluidSupportOracle':
    sources.append(str(root / 'scripts' / 'CollisionMetadata.java'))
if name == 'ClimbContactOracle':
    sources.append(str(root / 'scripts' / 'ClimbMetadata.java'))
if name in ('StatusEffectOracle', 'HazardGeometryOracle', 'BlockHazardOracle', 'FireGeometryOracle', 'RainContactOracle'):
    sources.append(str(root / 'scripts' / 'FireContactOracle.java'))
if name == 'PlayerEffectMapOracle':
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('StatusEffectOracle', 'FireContactOracle')]
if name == 'StuckPathsOracle':
    sources.append(str(root / 'scripts' / 'StuckContactOracle.java'))
if name in ('HazardGeometryOracle', 'DamageImmunityOracle', 'FlatClimateOracle', 'SkyColumnOracle', 'RainContactOracle', 'HeightmapOracle', 'PlayerMiningOracle', 'ToolDurabilityOracle', 'MiningLootOracle', 'MiningAttemptOracle', 'PlacementOracle', 'PlacementConsumptionOracle', 'PlayerCraftingOracle', 'TableMenuOracle', 'CraftingTableAccessOracle', 'ItemDropOracle', 'ItemMotionOracle', 'ItemTravelOracle', 'ItemMergeOracle', 'ItemPickupOracle'):
    sources.append(str(root / 'scripts' / 'MiningToolOracle.java'))
if name == 'SkyColumnOracle':
    sources.append(str(root / 'scripts' / 'HeightmapOracle.java'))
if name == 'HazardGeometryOracle':
    sources.append(str(root / 'scripts' / 'FireGeometryOracle.java'))
if name == 'RandomMiningLootOracle':
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('MiningToolOracle', 'MiningLootOracle')]
if name == 'TableCraftingOracle':
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('PlayerCraftingOracle', 'MiningToolOracle')]
if name in ('TableMenuClickOracle', 'CraftingBulkOracle', 'RemainderCraftingOracle'):
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('PlayerCraftingOracle', 'TableMenuOracle', 'MiningToolOracle')]
if name in ('ChestMenuOracle', 'CookingMenuOracle'):
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('TableMenuOracle', 'MiningToolOracle')]
if name == 'CookingClickOracle':
    sources.append(str(root / 'scripts' / 'ChestClickOracle.java'))
if name in ('ChestClickOracle', 'CookingClickOracle'):
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('PlayerCraftingOracle', 'TableMenuOracle', 'MiningToolOracle')]
if name == 'ChestAccessOracle':
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('CraftingTableAccessOracle', 'MiningToolOracle')]
if name in ('ChestBlockEntityOracle', 'ChestOpeningOracle', 'ChestViewOracle', 'ChestPlacementOracle', 'ContainerDropOracle', 'ChestLootOracle'):
    sources.append(str(root / 'scripts' / 'MiningToolOracle.java'))
if name == 'ChestSoundOracle':
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('ChestViewOracle', 'MiningToolOracle')]
if name in ('CookingFuelOracle', 'CookingItemsOracle', 'CookingRecipesOracle', 'CookingTickOracle', 'CookingLootOracle'):
    sources.append(str(root / 'scripts' / 'MiningToolOracle.java'))
if name == 'CookingPlacementOracle':
    sources += [str(root / 'scripts' / (source + '.java')) for source in ('ChestPlacementOracle', 'MiningToolOracle')]
if name in ('CraftingBulkOracle', 'RemainderCraftingOracle'):
    sources.append(str(root / 'scripts' / 'TableMenuClickOracle.java'))
if name in ('PositionCollisionOracle', 'ScaffoldingCollisionOracle', 'PowderSnowCollisionOracle', 'ShulkerCollisionOracle', 'VoxelUnionOracle', 'PistonCollisionOracle', 'MovementCollisionOracle', 'VoxelIntersectionOracle', 'BlockCollisionOracle', 'StepMovementOracle', 'EntityCollisionOracle', 'ServerMovementOracle'):
    sources.append(str(root / 'scripts' / 'CollisionMetadata.java'))
compiled = subprocess.run([java_home + '/bin/javac', '-cp', classpath, '-d', str(tools), *sources])
if compiled.returncode:
    sys.exit(compiled.returncode)
sys.exit(subprocess.run([java_home + '/bin/java', '-cp', str(tools) + os.pathsep + classpath, name, *sys.argv[2:]]).returncode)
