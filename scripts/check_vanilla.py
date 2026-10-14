#!/usr/bin/env python3
"""Start an isolated Elixir server, run the official-codec TCP oracle, then clean up."""
import os, pathlib, socket, subprocess, sys, tempfile, time, json
root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='valimc-oracle-') as world:
    collision_facts = str(pathlib.Path(world) / 'collision-shapes.json')
    collision_cases = str(pathlib.Path(world) / 'collisions.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'CollisionMetadata', collision_facts], cwd=root, check=True)
    if json.loads(pathlib.Path(collision_facts).read_text()) != json.loads((root/'priv/physics/collision_shapes.json').read_text()):
        raise RuntimeError('Pinned cached collision geometry differs')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'CollisionOracle', collision_facts, collision_cases], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_collisions.exs', collision_cases], cwd=root, check=True)
    position_cases = str(pathlib.Path(world) / 'position-collisions.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'PositionCollisionOracle', collision_facts, position_cases], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_position_collisions.exs', position_cases], cwd=root, check=True)
    attribute_facts = str(pathlib.Path(world) / 'attributes.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'AttributeMetadata', attribute_facts], cwd=root, check=True)
    if json.loads(pathlib.Path(attribute_facts).read_text()) != json.loads((root/'priv/protocol/attributes.json').read_text()):
        raise RuntimeError('Pinned builtin attribute facts differ')
    ranges = str(pathlib.Path(world) / 'ranges.json')
    ranges_encoded = str(pathlib.Path(world) / 'ranges-elixir.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'InteractionRangeOracle', ranges], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_interaction_ranges.exs', ranges, ranges_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'InteractionRangeOracle', 'verify', ranges_encoded], cwd=root, check=True)
    modes = str(pathlib.Path(world) / 'modes.json')
    modes_encoded = str(pathlib.Path(world) / 'modes-elixir.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'GameModeOracle', modes], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_game_modes.exs', modes, modes_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'GameModeOracle', 'verify', modes_encoded], cwd=root, check=True)
    abilities = str(pathlib.Path(world) / 'abilities.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'AbilitiesOracle', abilities], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_abilities.exs', abilities], cwd=root, check=True)
    discovery_fixtures = str(pathlib.Path(world) / 'discovery.jsonl')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'DiscoveryOracle', discovery_fixtures], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_discovery.exs', discovery_fixtures], cwd=root, check=True)
    auth_fixtures = str(pathlib.Path(world) / 'auth-profiles.jsonl')
    auth_encoded = str(pathlib.Path(world) / 'auth-elixir.jsonl')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'AuthProfileOracle', auth_fixtures], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_auth.exs', auth_fixtures, auth_encoded], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'AuthProfileOracle', 'verify', auth_encoded], cwd=root, check=True)
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
    weather = str(pathlib.Path(world) / 'weather.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'WeatherOracle', weather], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_weather.exs', weather], cwd=root, check=True)
    difficulty = str(pathlib.Path(world) / 'difficulty.json')
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'DifficultyOracle', difficulty], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_difficulty.exs', difficulty], cwd=root, check=True)
    encryption = str(pathlib.Path(world) / 'encryption.json')
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_encryption.exs', 'generate', encryption], cwd=root, check=True)
    subprocess.run([sys.executable, 'scripts/java_tool.py', 'EncryptionOracle', encryption], cwd=root, check=True)
    subprocess.run(['mix', 'run', '--no-start', 'scripts/check_encryption.exs', 'verify', encryption], cwd=root, check=True)
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
    for mode, encrypted in [('plain', False), ('encrypted', True)]:
        with socket.socket() as port_probe:
            port_probe.bind(('127.0.0.1', 0))
            port = port_probe.getsockname()[1]
        env = dict(os.environ, VALIMC_PORT=str(port), VALIMC_WORLD=str(pathlib.Path(world)/mode), VALIMC_ENCRYPTION=str(encrypted).lower(), VALIMC_ONLINE_MODE='false', VALIMC_GAME_MODE='creative')
        log_path = pathlib.Path(world) / (mode+'-server.log')
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
                result = subprocess.run([sys.executable, 'scripts/java_tool.py', 'VanillaOracle', str(port), mode], cwd=root)
                if result.returncode:
                    print(log_path.read_text(), file=sys.stderr)
                if result.returncode:
                    sys.exit(result.returncode)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
sys.exit(0)
