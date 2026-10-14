#!/usr/bin/env python3
"""Start an isolated Elixir server, run the official-codec TCP oracle, then clean up."""
import os, pathlib, socket, subprocess, sys, tempfile, time, json
root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='valimc-oracle-') as world:
    item_facts = str(pathlib.Path(world) / 'items.json')
    defaults = str(pathlib.Path(world) / 'defaults.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'ItemMetadata', item_facts, defaults], cwd=root, check=True)
    for actual, committed in [(item_facts, 'items.json'), (defaults, 'item_defaults.json')]:
        if json.loads(pathlib.Path(actual).read_text()) != json.loads((root/'priv/protocol'/committed).read_text()):
            raise RuntimeError('Pinned item facts differ: '+committed)
    identity = str(pathlib.Path(world) / 'identity.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'StackIdentityOracle', identity], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_stack_identity.exs', identity], cwd=root, check=True)
    text = str(pathlib.Path(world) / 'text.json')
    text_encoded = str(pathlib.Path(world) / 'elixir-text.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'TextOracle', text], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_text.exs', text, text_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'TextOracle', 'verify', text_encoded], cwd=root, check=True)
    enchantments = str(pathlib.Path(world) / 'enchantments.json')
    enchantments_encoded = str(pathlib.Path(world) / 'elixir-enchantments.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'EnchantmentOracle', enchantments], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_enchantments.exs', enchantments, enchantments_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'EnchantmentOracle', 'verify', enchantments_encoded], cwd=root, check=True)
    tooltips = str(pathlib.Path(world) / 'tooltips.json')
    tooltips_encoded = str(pathlib.Path(world) / 'elixir-tooltips.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'TooltipOracle', tooltips], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_tooltips.exs', tooltips, tooltips_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'TooltipOracle', 'verify', tooltips_encoded], cwd=root, check=True)
    clocks = str(pathlib.Path(world) / 'clocks.json')
    clocks_encoded = str(pathlib.Path(world) / 'elixir-clocks.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'ClockOracle', clocks], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_clocks.exs', clocks, clocks_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'ClockOracle', 'verify', clocks_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'InventoryBehaviorOracle'], cwd=root, check=True)
    fixtures = str(pathlib.Path(world) / 'item-fixtures.json')
    encoded = str(pathlib.Path(world) / 'elixir-items.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'ItemOracle', 'generate', fixtures], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_items.exs', fixtures, encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'ItemOracle', 'verify', encoded], cwd=root, check=True)
    entity_fixtures = str(pathlib.Path(world) / 'entity-fixtures.json')
    entity_encoded = str(pathlib.Path(world) / 'elixir-entities.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'EntityOracle', 'generate', entity_fixtures], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_entities.exs', entity_fixtures, entity_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'EntityOracle', 'verify', entity_encoded], cwd=root, check=True)
    with socket.socket() as port_probe:
        port_probe.bind(('127.0.0.1', 0))
        port = port_probe.getsockname()[1]
    env = dict(os.environ, VALIMC_PORT=str(port), VALIMC_WORLD=world)
    log_path = pathlib.Path(world) / 'server.log'
    with log_path.open('w') as log:
        server = subprocess.Popen(['mix', 'run', '--no-halt'], cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            for _ in range(200):
                if server.poll() is not None:
                    raise RuntimeError(log_path.read_text())
                if 'listening on' in log_path.read_text():
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError('Server startup timeout')
            result = subprocess.run([sys.executable, 'scripts/java_tool.py', 'VanillaOracle', str(port)], cwd=root)
            if result.returncode:
                print(log_path.read_text(), file=sys.stderr)
            exit_code = result.returncode
        finally:
            server.terminate()
            try:
                server.wait(timeout=20)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
sys.exit(exit_code)
