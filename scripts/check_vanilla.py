#!/usr/bin/env python3
"""Start an isolated Elixir server, run the official-codec TCP oracle, then clean up."""
import os, pathlib, socket, subprocess, sys, tempfile, time
root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='valimc-oracle-') as world:
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
