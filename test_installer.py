"""Offline checks only. Never installs services or changes system configuration."""
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / 'install-reality.sh'
XRAY = os.environ.get('TEST_XRAY') or shutil.which('xray')
if not XRAY:
    raise SystemExit('Set TEST_XRAY to an Xray executable or add xray to PATH.')
XRAY = str(Path(XRAY).resolve())
source = SCRIPT.read_text()
assert source.endswith('main "$@"\n')
library = source.removesuffix('main "$@"\n')

with tempfile.TemporaryDirectory(prefix='reality-offline-') as directory:
    work = Path(directory)
    lib = work / 'installer-lib.sh'
    lib.write_text(library)
    env = dict(os.environ, TEST_LIB=str(lib), TEST_WORK=str(work), TEST_XRAY=XRAY)
    checks = r'''
. "$TEST_LIB"
for p in 1 443 20443 65535; do valid_port "$p" || exit 10; done
for p in '' 0 00 0443 65536 9999999999999 -1 '4;id' '80 90' '1.2'; do
    if valid_port "$p"; then exit 11; fi
done
for h in example.com nat.example.com 192.0.2.93 192.0.2.1; do valid_host "$h" || exit 12; done
for h in '' 'bad"host' 'https://example.com' 'host:443' '..' '-host' 'host-' 'a..b' '256.1.1.1' '01.2.3.4' '1.2.3' '$(id)'; do
    if valid_host "$h"; then exit 13; fi
done
PUBLIC_HOST=nat.example.com PUBLIC_PORT=20443 LISTEN_PORT=443 SNI=www.tesla.cn
inputs
WORK=$TEST_WORK
ln -sf "$TEST_XRAY" "$WORK/xray"
credentials
render_config > "$WORK/config.json"
render_openrc > "$WORK/openrc"
render_systemd > "$WORK/reality-nat.service"
"$WORK/xray" run -test -config "$WORK/config.json"
sh -n "$WORK/openrc"
'''
    for shell in (['sh'], ['busybox', 'sh']):
        result = subprocess.run(shell + ['-c', checks], env=env, text=True, capture_output=True)
        assert result.returncode == 0, (shell, result.stdout, result.stderr)
        config = json.loads((work / 'config.json').read_text())
        inbound = config['inbounds'][0]
        assert inbound['port'] == 443
        reality = inbound['streamSettings']['realitySettings']
        assert reality['target'] == 'www.tesla.cn:443'
        assert len(reality['privateKey']) == 43
        assert len(reality['shortIds'][0]) == 16
        print(f"PASS {' '.join(shell)}: input rejection, key generation, JSON, real Xray configuration test, OpenRC syntax")

    for field, value in [('PUBLIC_HOST', 'x"},{}'), ('PUBLIC_PORT', '65536'), ('LISTEN_PORT', '0'), ('SNI', 'bad/host')]:
        test_env = dict(env, PUBLIC_HOST='nat.example.com', PUBLIC_PORT='20443', LISTEN_PORT='443', SNI='www.tesla.cn')
        test_env[field] = value
        result = subprocess.run(['sh', '-c', '. "$TEST_LIB"; inputs'], env=test_env, capture_output=True)
        assert result.returncode != 0, field
    print('PASS invalid deployment parameters fail before configuration generation')

version = subprocess.check_output([XRAY, 'version'], text=True).splitlines()[0]
print('Configuration validator:', version)
print('NOT TESTED: release download, SHA-256 against live release, service installation, external REALITY connection')
