#!/usr/bin/env python3
"""Regenerate protocol facts from official reports, using a Java 25+ development toolchain."""
import json, pathlib, subprocess, sys, math
root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root / 'scripts'))
# java_tool is a CLI, so share its file layout rather than importing its entry point.
from java_runtime import java_home as find_java_home
from pinned import SERVER_JAR, VERSION
java_home = find_java_home()
subprocess.run([sys.executable,str(root/'scripts/prepare_vanilla.py')],check=True)
subprocess.run([java_home+'/bin/java','-DbundlerMainClass=net.minecraft.data.Main',
                '-DbundlerRepoDir=research/vanilla-bundle','-jar',str(SERVER_JAR),
                '--reports','--output','research/generated'],cwd=root,check=True)
out = root / 'priv/protocol';reports = root / 'research/generated/reports'
out.mkdir(parents=True,exist_ok=True)
packets=json.loads((reports/'packets.json').read_text())
(out/'packets.json').write_text(json.dumps(packets,indent=2)+'\n')
subprocess.run([sys.executable,'scripts/java_tool.py','VersionMetadata','priv/version.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','BlockRegistryMetadata','priv/registry/blocks.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','ProtocolMetadata','priv/protocol/registries.json','priv/protocol/tags.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','ItemMetadata','priv/protocol/items.json','priv/protocol/item_defaults.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','EntityMetadata','priv/protocol/entities.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','AttributeMetadata','priv/protocol/attributes.json'],cwd=root,check=True)
print(f'Regenerated official {VERSION} protocol facts')
