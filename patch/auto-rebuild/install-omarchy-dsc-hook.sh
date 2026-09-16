#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
[[ ! -r /etc/honor-autorebuild.conf ]] || source /etc/honor-autorebuild.conf
REPO=$repo
BUILD_USER=${BUILD_USER:-${SUDO_USER:-}}
if [[ -z $BUILD_USER && -n ${PKEXEC_UID:-} ]]; then BUILD_USER=$(id -nu "$PKEXEC_UID"); fi
[[ -n $BUILD_USER && $BUILD_USER != root ]] || { echo 'Non-root BUILD_USER required'; exit 1; }
user_home=$(getent passwd "$BUILD_USER" | cut -d: -f6)
DSC_CACHE=${DSC_CACHE:-$user_home/.cache/honor-omarchy-xe}
DSC_TOOLCHAIN=${DSC_TOOLCHAIN:-}
export REPO BUILD_USER DSC_CACHE DSC_TOOLCHAIN
python3 - <<'PY'
import os,re,shlex
from pathlib import Path
p=Path('/etc/honor-autorebuild.conf');s=p.read_text() if p.exists() else ''
for key in ['REPO','BUILD_USER','DSC_CACHE','DSC_TOOLCHAIN']:
 s=re.sub(r'^'+key+r'=.*\n?', '', s, flags=re.M)
 s=s.rstrip()+'\n'+key+'='+shlex.quote(os.environ[key])+'\n'
p.write_text(s);p.chmod(0o644)
PY
install -d /etc/pacman.d/hooks /usr/local/lib/honor
# Preserve the separate fingerprint maintenance path.
install -m755 "$repo/patch/auto-rebuild/rebuild.sh" "$repo/patch/auto-rebuild/deferred.sh" /usr/local/lib/honor/
install -m644 "$repo/patch/auto-rebuild/96-honor-libfprint.hook" /etc/pacman.d/hooks/
if [[ -f /etc/pacman.d/hooks/95-honor-kernel-modules.hook ]]; then
    mv /etc/pacman.d/hooks/95-honor-kernel-modules.hook /etc/pacman.d/hooks/95-honor-kernel-modules.hook.disabled
fi
install -m755 "$repo/patch/auto-rebuild/dsc-update.sh" /usr/local/lib/honor/dsc-update.sh
install -m644 "$repo/patch/auto-rebuild/85-honor-edp-dsc.hook" /etc/pacman.d/hooks/
echo 'DSC-only synchronous maintenance enabled before the normal 90-mkinitcpio hook.'
