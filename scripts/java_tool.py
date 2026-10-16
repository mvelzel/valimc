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
if name in ('FluidFlowOracle', 'FluidCurrentOracle'):
    sources.append(str(root / 'scripts' / 'FluidBoundaryMetadata.java'))
if name == 'FluidSupportOracle':
    sources.append(str(root / 'scripts' / 'CollisionMetadata.java'))
if name == 'ClimbContactOracle':
    sources.append(str(root / 'scripts' / 'ClimbMetadata.java'))
if name == 'StuckPathsOracle':
    sources.append(str(root / 'scripts' / 'StuckContactOracle.java'))
if name in ('PlayerMiningOracle', 'ToolDurabilityOracle', 'MiningLootOracle', 'MiningAttemptOracle', 'PlacementOracle'):
    sources.append(str(root / 'scripts' / 'MiningToolOracle.java'))
if name in ('PositionCollisionOracle', 'ScaffoldingCollisionOracle', 'PowderSnowCollisionOracle', 'ShulkerCollisionOracle', 'VoxelUnionOracle', 'PistonCollisionOracle', 'MovementCollisionOracle', 'VoxelIntersectionOracle', 'BlockCollisionOracle', 'StepMovementOracle', 'EntityCollisionOracle', 'ServerMovementOracle'):
    sources.append(str(root / 'scripts' / 'CollisionMetadata.java'))
compiled = subprocess.run([java_home + '/bin/javac', '-cp', classpath, '-d', str(tools), *sources])
if compiled.returncode:
    sys.exit(compiled.returncode)
sys.exit(subprocess.run([java_home + '/bin/java', '-cp', str(tools) + os.pathsep + classpath, name, *sys.argv[2:]]).returncode)
