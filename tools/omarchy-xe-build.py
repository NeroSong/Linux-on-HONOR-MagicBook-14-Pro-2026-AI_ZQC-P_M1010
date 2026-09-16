#!/usr/bin/env python3
"""Build-only DSC overlay. Exact package inputs and reproducible native baseline required."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import urllib.request

REPO = Path(__file__).resolve().parents[1]
PATCH = REPO / 'patch/edp-dsc/0001-drm-i915-dp-prefer-DSC-over-driving-eDP-below-8-bpc.patch'
OFFICIAL = 'https://raw.githubusercontent.com/omacom/omarchy-pkgs/'
PKGDIR = '/pkgbuilds/linux-omarchy/'
SEED_COMMIT = '7b11c97603dd9d751d803746560ee51640709725'


def run(*args, cwd=None, env=None):
    subprocess.run(args, cwd=cwd, env=env, check=True)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path, kind='sha256'):
    h = hashlib.new(kind)
    with Path(path).open('rb') as f:
        for b in iter(lambda: f.read(1024 * 1024), b''):
            h.update(b)
    return h.hexdigest()


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'honor-omarchy-dsc-builder'})
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read()


def recipe(text, version):
    base, release = version.rsplit('-', 1)
    if not re.search(r'^pkgver=' + re.escape(base) + r'$', text, re.M):
        raise ValueError('pkgver does not match')
    if not re.search(r'^pkgrel=' + re.escape(release) + r'$', text, re.M):
        raise ValueError('pkgrel does not match')
    if not re.fullmatch(r'\d+\.\d+\.\d+', base):
        raise ValueError('Only reviewed stable-source recipe format supported')
    block = text.split('source=(', 1)[1].split('\n)', 1)[0]
    names = re.findall(r'^  ([\w.-]+\.patch)$', block, re.M)
    sums = re.findall(r"'([^']+)'", text.split('b2sums=(', 1)[1].split(')', 1)[0])
    if not names or len(sums) != len(names) + 2 or any(not re.fullmatch('[0-9a-f]{128}', x) for x in [sums[0]] + sums[2:]):
        raise ValueError('Unrecognized source/checksum layout; refusing guessed build')
    # Reject additional/unparsed sources, and verify the known base URL form.
    allowed = [x.strip() for x in block.splitlines() if x.strip() and not x.strip().startswith('#')]
    if len(allowed) != len(names) + 3 or 'cdn.kernel.org/pub/linux/kernel/' not in allowed[0]:
        raise ValueError('Source list changed; manual review required')
    return base, names, sums


def find_recipe(version):
    candidates = [SEED_COMMIT]
    history = json.loads(fetch('https://api.github.com/repos/omacom/omarchy-pkgs/commits?path=pkgbuilds/linux-omarchy/PKGBUILD&per_page=60'))
    candidates += [x['sha'] for x in history]
    for sha in dict.fromkeys(candidates):
        if not re.fullmatch('[0-9a-f]{40}', sha):
            continue
        text = fetch(OFFICIAL + sha + PKGDIR + 'PKGBUILD').decode()
        try:
            info = recipe(text, version)
        except (ValueError, IndexError):
            continue
        return sha, text, info
    raise ValueError('No exact official package recipe found; leaving native xe in place')


def native_elf(native, target):
    if native.suffix == '.zst':
        with target.open('wb') as f:
            subprocess.run(['zstd', '-dc', str(native)], stdout=f, check=True)
    else:
        shutil.copy2(native, target)


def check_baseline(baseline, native, folder):
    for section in ['.text', '.init.text', '.exit.text', '.static_call.text']:
        a, b = folder / ('baseline' + section), folder / ('native' + section)
        run('objcopy', '--dump-section', f'{section}={a}', str(baseline))
        run('objcopy', '--dump-section', f'{section}={b}', str(native))
        if a.read_bytes() != b.read_bytes():
            raise ValueError(f'Native baseline mismatch in {section}; refusing install')
    if output('nm', '-u', str(baseline)) != output('nm', '-u', str(native)):
        raise ValueError('Native baseline imports differ')


def check_headers(tree, headers):
    count = 0
    for part in ('include', 'arch'):
        for p in (headers / part).rglob('*.h'):
            q = tree / p.relative_to(headers)
            if q.is_file():
                if p.read_bytes() != q.read_bytes():
                    raise ValueError(f'Header differs: {p.relative_to(headers)}')
                count += 1
    if count < 1000:
        raise ValueError('Insufficient headers to verify source layout')
    return count


def identity(kver, headers, native):
    return {'kver': kver, 'native_sha256': digest(native), 'config_sha256': digest(headers / '.config'),
            'vmlinux_sha256': digest(headers / 'vmlinux'), 'symvers_sha256': digest(headers / 'Module.symvers'),
            'patch_sha256': digest(PATCH)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--kver', required=True)
    parser.add_argument('--cache', required=True)
    parser.add_argument('--toolchain')
    parser.add_argument('--seed', help='Explicitly adopt the locally tested build after revalidation')
    args = parser.parse_args()
    if not re.fullmatch(r'\d+\.\d+\.\d+-\d+-omarchy', args.kver):
        raise ValueError('Unsupported kernel release')
    moddir = Path('/usr/lib/modules') / args.kver
    headers = moddir / 'build'
    native = moddir / 'kernel/drivers/gpu/drm/xe/xe.ko.zst'
    version = args.kver.removesuffix('-omarchy')
    if output('pacman', '-Q', 'linux-omarchy') != 'linux-omarchy ' + version:
        raise ValueError('Target is not the installed linux-omarchy package')
    ident = identity(args.kver, headers, native)
    dest = Path(args.cache).resolve() / args.kver
    manifest = dest / 'manifest.json'
    if manifest.exists():
        data = json.loads(manifest.read_text())
        if all(data.get(k) == v for k, v in ident.items()) and digest(dest / 'xe.ko.zst') == data['module_sha256']:
            print('Verified cache hit:', dest, flush=True)
            return
        raise ValueError('Cached inputs changed; retain evidence and choose a fresh cache directory')
    dest.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=args.kver + '-', dir=dest.parent))
    native_unpacked = work / 'native.ko'
    native_elf(native, native_unpacked)
    if args.seed:
        seed = Path(args.seed).resolve()
        tree = seed / ('linux-' + version.rsplit('-', 1)[0])
        if (seed / 'inputs/dsc.patch').read_bytes() != PATCH.read_bytes():
            raise ValueError('Seed patch differs')
        check_baseline(seed / 'baseline/xe.ko', native_unpacked, work)
        if (tree / '.config').read_bytes() != (headers / '.config').read_bytes():
            raise ValueError('Seed config differs')
        count = check_headers(tree, headers)
        # The seed was tested in this session; require that exact live module.
        module = seed / 'patched/xe.ko.zst'
        if output('modinfo', '-F', 'srcversion', str(module)) != Path('/sys/module/xe/srcversion').read_text().strip():
            raise ValueError('Seed module is not the successfully running module')
        sha = (seed / 'prepared').read_text().strip()
        shutil.copy2(module, work / 'xe.ko.zst')
    else:
        sha, text, (base, names, sums) = find_recipe(version)
        inputs = work / 'inputs'; inputs.mkdir()
        (inputs / 'PKGBUILD').write_text(text)
        for name, checksum in zip(names, sums[2:]):
            p = inputs / name; p.write_bytes(fetch(OFFICIAL + sha + PKGDIR + name))
            if digest(p, 'blake2b') != checksum:
                raise ValueError('Patch checksum mismatch: ' + name)
        archive = inputs / f'linux-{base}.tar.xz'
        archive.write_bytes(fetch(f'https://cdn.kernel.org/pub/linux/kernel/v{base.split(".")[0]}.x/linux-{base}.tar.xz'))
        if digest(archive, 'blake2b') != sums[0]:
            raise ValueError('Kernel archive checksum mismatch')
        run('tar', 'xf', str(archive), '-C', str(work))
        tree = work / f'linux-{base}'
        for name in names:
            run('patch', '--batch', '--fuzz=0', '-Np1', '-i', str(inputs / name), cwd=tree)
        for name in ('.config', 'Module.symvers', 'vmlinux'):
            shutil.copy2(headers / name, tree / name)
        for p in headers.glob('localversion.*'):
            shutil.copy2(p, tree / p.name)
        env = os.environ.copy()
        if args.toolchain:
            tc = Path(args.toolchain).resolve()
            env['PATH'] = str(tc / 'usr/bin') + ':' + env['PATH']
            env['RUST_LIB_SRC'] = str(tc / 'usr/lib/rustlib/src/rust/library')
        env.update(KBUILD_BUILD_USER='linux-omarchy', KBUILD_BUILD_HOST='omarchy')
        run('make', '-j6', 'modules_prepare', cwd=tree, env=env)
        if (tree / '.config').read_bytes() != (headers / '.config').read_bytes():
            raise ValueError('Build changed kernel config; dependencies/toolchain need review')
        if output('make', '-s', '-C', str(tree), 'kernelrelease') != args.kver:
            raise ValueError('Kernel release differs')
        count = check_headers(tree, headers)
        run('nice', '-n', '10', 'make', '-j6', 'M=drivers/gpu/drm/xe', cwd=tree, env=env)
        ko = tree / 'drivers/gpu/drm/xe/xe.ko'
        check_baseline(ko, native_unpacked, work)
        shutil.copy2(ko, work / 'baseline.ko')
        run('patch', '--batch', '--fuzz=0', '-Np1', '-i', str(PATCH), cwd=tree)
        run('nice', '-n', '10', 'make', '-j6', 'M=drivers/gpu/drm/xe', cwd=tree, env=env)
        shutil.copy2(ko, work / 'xe.ko')
        run('strip', '--strip-debug', str(work / 'xe.ko'))
        run('zstd', '-q', '-19', '-T2', str(work / 'xe.ko'), '-o', str(work / 'xe.ko.zst'))
    module = work / 'xe.ko.zst'
    if output('modinfo', '-F', 'vermagic', str(module)) != output('modinfo', '-F', 'vermagic', str(native)):
        raise ValueError('Module vermagic differs')
    data = dict(ident, commit=sha, header_matches=count, module_sha256=digest(module),
                srcversion=output('modinfo', '-F', 'srcversion', str(module)))
    dest.mkdir()
    shutil.copy2(module, dest / 'xe.ko.zst')
    manifest.write_text(json.dumps(data, indent=2) + '\n')
    print('Validated DSC module:', dest, flush=True)


if __name__ == '__main__':
    main()
