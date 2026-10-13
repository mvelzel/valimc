#!/usr/bin/env python3
"""Prepare the pinned 26.3 development oracle. No EULA acceptance or vanilla gameplay server."""
import hashlib, json, pathlib, urllib.request, zipfile
root = pathlib.Path(__file__).resolve().parent.parent
metadata = json.loads((root / 'research/mojang-version.json').read_text())
jar = root / 'research/server-26.3.jar'
download = metadata['downloads']['server']
if not jar.exists():
    urllib.request.urlretrieve(download['url'],jar)
if hashlib.sha1(jar.read_bytes()).hexdigest() != download['sha1']:
    raise SystemExit('Official server jar checksum mismatch')
bundle = root / 'research/vanilla-bundle'
with zipfile.ZipFile(jar) as archive:
    version = json.loads(archive.read('version.json'))
    if version['id'] != '26.3' or version['protocol_version'] != 777:
        raise SystemExit('Unexpected Minecraft protocol version')
    for name in archive.namelist():
        if name.startswith(('META-INF/libraries/','META-INF/versions/')) and name.endswith('.jar'):
            relative = pathlib.Path(name.removeprefix('META-INF/'))
            if '..' in relative.parts:
                raise SystemExit('Unsafe jar entry')
            target = bundle / relative
            target.parent.mkdir(parents=True,exist_ok=True)
            target.write_bytes(archive.read(name))
print('Prepared official Minecraft 26.3 protocol oracle; SHA-1',download['sha1'])
