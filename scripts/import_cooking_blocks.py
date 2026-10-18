#!/usr/bin/env python3
"""Keep scalar native furnace-family state and isolated placement facts only."""
import json
import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
raw = json.loads(source.read_text())
assert raw['version'] == '26.3' and raw['data_version'] == 5023
assert raw['server_sha1'] == '33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c'
assert len(raw['states']) == 24 and len(raw['cases']) == 864
states = {row['state']: row for row in raw['states']}
assert len(states) == 24
placements = [{} for _ in range(3)]
for row in raw['cases']:
    result = states[row['result']]
    assert result['kind'] == row['kind'] and not result['lit']
    key = str(row['heading'])
    assert key not in placements[row['kind']] or placements[row['kind']][key] == row['result']
    placements[row['kind']][key] = row['result']
assert all(sorted(int(k) for k in table) == [2, 3, 4, 5] for table in placements)
facts = {key: raw[key] for key in ['version', 'data_version', 'server_sha1']}
facts.update(states=raw['states'], placements=placements)
destination.write_text(json.dumps(facts, separators=(',', ':')) + '\n')
print('PASS: 864 native candidates reduced to24 block states/12 directional placements')
