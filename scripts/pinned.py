"""The pinned Minecraft release (`priv/version.json`), shared by the Python tools."""
import json, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
facts = json.loads((root / 'priv/version.json').read_text())
VERSION, DATA_VERSION, PROTOCOL, SERVER_SHA1 = (
    facts['minecraft'], facts['data_version'], facts['protocol'], facts['server_sha1'])
SERVER_JAR = root / f'research/server-{VERSION}.jar'
STAMPS = {'version': VERSION, 'data_version': DATA_VERSION, 'protocol': PROTOCOL, 'server_sha1': SERVER_SHA1}


def stamped(raw, keys=('version', 'data_version', 'server_sha1')):
    """True when generated facts carry this release's value for each stamp key."""
    return all(raw.get(key) == STAMPS[key] for key in keys)
