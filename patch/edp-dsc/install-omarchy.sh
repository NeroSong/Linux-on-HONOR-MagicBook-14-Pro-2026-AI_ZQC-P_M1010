#!/usr/bin/env bash
# Exact-source Omarchy path; called under xe_build_install's module lock.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
source /etc/honor-autorebuild.conf
kver=${KVER:-$(uname -r)}
[[ $kver =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-omarchy$ ]] || exit 3
[[ ${BUILD_USER:-root} != root ]] || { echo 'A non-root BUILD_USER is required'; exit 1; }
cache=${DSC_CACHE:?DSC_CACHE must be configured}
toolchain=${DSC_TOOLCHAIN:-}
args=(--kver "$kver" --cache "$cache")
[[ -z $toolchain ]] || args+=(--toolchain "$toolchain")
runuser -u "$BUILD_USER" -- python3 "$repo/tools/omarchy-xe-build.py" "${args[@]}"
# Revalidate the cache against the installed package immediately before writing.
python3 - "$repo" "$cache" "$kver" <<'PY'
import importlib.util,json,sys
from pathlib import Path
repo,cache,kver=sys.argv[1:]
spec=importlib.util.spec_from_file_location('builder',Path(repo)/'tools/omarchy-xe-build.py')
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
p=Path(cache)/kver; data=json.loads((p/'manifest.json').read_text())
mod=Path('/usr/lib/modules')/kver
identity=b.identity(kver,mod/'build',mod/'kernel/drivers/gpu/drm/xe/xe.ko.zst')
assert all(data.get(k)==v for k,v in identity.items()),'Cache input identity changed'
assert b.digest(p/'xe.ko.zst')==data['module_sha256'],'Cache module changed'
assert b.output('pacman','-Q','linux-omarchy')=='linux-omarchy '+kver.removesuffix('-omarchy')
PY
moddir=/usr/lib/modules/$kver
backup=$(mktemp -d /var/lib/honor/dsc-install-XXXXXX)
target=$moddir/updates/xe.ko.zst
[[ ! -f $target ]] || cp -a "$target" "$backup/previous-xe.ko.zst"
mkdir -p "$moddir/updates"
install -m644 "$cache/$kver/xe.ko.zst" "$target.new"
mv -f "$target.new" "$target"
depmod "$kver"
if [[ ${REGEN:-1} == 1 ]]; then
    if ! limine-mkinitcpio linux-omarchy; then
        echo 'DSC initramfs generation failed; restoring previous module selection' >&2
        if [[ -f $backup/previous-xe.ko.zst ]]; then
            cp -a "$backup/previous-xe.ko.zst" "$target"
        else
            rm -f "$target"
        fi
        depmod "$kver"
        limine-mkinitcpio linux-omarchy || true
        exit 1
    fi
fi
install -m644 "$cache/$kver/manifest.json" /var/lib/honor/xe-omarchy-manifest.json
printf 'kver=%s\nwanted=edp-dsc\npatches=edp-dsc\nsrcversion=%s\n' \
    "$kver" "$(modinfo -F srcversion "$target")" > /var/lib/honor/xe-module.stamp
printf 'DSC installed for %s; running driver was not reloaded.\n' "$kver"
