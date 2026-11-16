"""Build the pinned native TLS transport. Android needs NDK 26.1.10909125."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CRATE = ROOT / 'native' / 'transport'
TARGETS = {
    'arm64-v8a': ('aarch64-linux-android', 'aarch64-linux-android'),
    'armeabi-v7a': ('armv7-linux-androideabi', 'armv7a-linux-androideabi'),
    'x86_64': ('x86_64-linux-android', 'x86_64-linux-android'),
}
if sys.argv[1:] != ['android']:
    raise SystemExit('Usage: python3 tool/build_native.py android')
sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or '')
ndk = Path(os.environ.get('ANDROID_NDK_HOME') or sdk / 'ndk' / '26.1.10909125')
host = 'darwin-x86_64' if sys.platform == 'darwin' else 'linux-x86_64'
clang = ndk / 'toolchains' / 'llvm' / 'prebuilt' / host / 'bin'
if not clang.is_dir():
    raise SystemExit(f'Install Android NDK 26.1.10909125 first: {clang}')
for abi, (target, compiler) in TARGETS.items():
    env = os.environ.copy()
    env['CC_' + target.replace('-', '_')] = str(clang / (compiler + '21-clang'))
    env['AR_' + target.replace('-', '_')] = str(clang / 'llvm-ar')
    env['CARGO_TARGET_' + target.upper().replace('-', '_') + '_LINKER'] = env['CC_' + target.replace('-', '_')]
    subprocess.run(['cargo', 'build', '--manifest-path', str(CRATE / 'Cargo.toml'),
                    '--locked', '--release', '--target', target], env=env, check=True)
    output = ROOT / 'android' / 'app' / 'src' / 'main' / 'jniLibs' / abi
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(CRATE / 'target' / target / 'release' / 'libmysend_transport.so', output)
