#!/usr/bin/env python3
"""Regenerate protocol facts from official reports, using a Java 25+ development toolchain."""
import json, pathlib, subprocess, sys, math
root = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0,str(root / 'scripts'))
# java_tool is a CLI, so share its file layout rather than importing its entry point.
from java_runtime import java_home as find_java_home
java_home = find_java_home()
subprocess.run([sys.executable,str(root/'scripts/prepare_vanilla.py')],check=True)
subprocess.run([java_home+'/bin/java','-DbundlerMainClass=net.minecraft.data.Main',
                '-DbundlerRepoDir=research/vanilla-bundle','-jar','research/server-26.3.jar',
                '--reports','--output','research/generated'],cwd=root,check=True)
out = root / 'priv/protocol';reports = root / 'research/generated/reports'
out.mkdir(parents=True,exist_ok=True)
packets=json.loads((reports/'packets.json').read_text())
blocks=json.loads((reports/'blocks.json').read_text())
registries=json.loads((reports/'registries.json').read_text())
names=['air','stone','grass_block','dirt','bedrock','oak_planks','glass','cobblestone']
def state(name):return next(s['id'] for s in blocks[name]['states'] if s.get('default'))
facts={'states':{n:state('minecraft:'+n) for n in names},
       'items':{n:registries['minecraft:item']['entries']['minecraft:'+n]['protocol_id'] for n in names if n!='air'},
       'item_blocks':{str(v['protocol_id']):state(k) for k,v in registries['minecraft:item']['entries'].items() if k in blocks},
       'player_entity_type':registries['minecraft:entity_type']['entries']['minecraft:player']['protocol_id'],
       'state_count':max(s['id'] for b in blocks.values() for s in b['states'])+1}
for name,data in [('packets',packets),('blocks',facts)]:
    (out/(name+'.json')).write_text(json.dumps(data,indent=2)+'\n')
subprocess.run([sys.executable,'scripts/java_tool.py','ProtocolMetadata','priv/protocol/registries.json','priv/protocol/tags.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','ItemMetadata','priv/protocol/items.json','priv/protocol/item_defaults.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','EntityMetadata','priv/protocol/entities.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','AttributeMetadata','priv/protocol/attributes.json'],cwd=root,check=True)
subprocess.run([sys.executable,'scripts/java_tool.py','CollisionMetadata','priv/physics/collision_shapes.json'],cwd=root,check=True)
print('Regenerated official 26.3 protocol facts')
