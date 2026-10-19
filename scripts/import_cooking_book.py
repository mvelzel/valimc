#!/usr/bin/env python3
"""Import factual native recipe display wire data, never upstream code/assets."""
import json,pathlib,sys
root=pathlib.Path(__file__).resolve().parent.parent
raw=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert raw['version']=='26.3' and raw['server_sha1']=='33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c'
names=[r['recipe'] for r in json.loads((root/'priv/crafting/cooking.json').read_text())['recipes']]
assert [r['recipe'] for r in raw['entries']]==names and len(names)==107
entries=[]
for row in raw['entries']:
    for field in ['quiet','notify']:
        data=bytes.fromhex(row[field]);assert 0<len(data)<=4096
    entries.append({k:row[k] for k in ['recipe','quiet','notify']})
(root/'priv/crafting/cooking_book.json').write_text(json.dumps({'version':raw['version'],'server_sha1':raw['server_sha1'],'entries':entries},separators=(',',':'))+'\n')
print('PASS: 107 bounded native cooking recipe displays imported')
