#!/usr/bin/env python3
"""Reduce original stock crafting-remainder scalar observations for furnace fuel consumption."""
import json
import pathlib
import sys
import pinned

source, destination = map(pathlib.Path, sys.argv[1:])
raw = json.loads(source.read_text())
assert pinned.stamped(raw)
assert len(raw['completion']) == 37440 and len(raw['consumption']) == 1960
remainders = raw['remainders']
assert remainders and all(0 < int(item) < 1658 and 0 < result < 1658 for item, result in remainders.items())
facts = {key: raw[key] for key in ['version', 'data_version', 'server_sha1', 'remainders']}
destination.write_text(json.dumps(facts, separators=(',', ':')) + '\n')
print(f'PASS: {len(remainders)} stock crafting-remainder item pairs retained; callbacks remain private')
