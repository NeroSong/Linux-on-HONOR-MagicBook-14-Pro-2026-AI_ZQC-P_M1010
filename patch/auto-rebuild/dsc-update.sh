#!/usr/bin/env bash
# Synchronous PostTransaction hook BEFORE the distro's 90-mkinitcpio hook.
# Only DSC is maintained here. Fingerprint keeps its independent existing hook.
set -uo pipefail
source /etc/honor-autorebuild.conf
LOG=/var/log/honor-autorebuild.log
exec > >(tee -a "$LOG") 2>&1
printf '\n%s === synchronous Omarchy DSC maintenance ===\n' "$(date -Is)"
declare -A kernels=()
while IFS= read -r target; do
    if [[ $target =~ ^/?usr/lib/modules/([^/]+)/(vmlinuz|modules\.builtin)$ ]]; then
        kernels[${BASH_REMATCH[1]}]=1
    fi
done
status=0
for kver in "${!kernels[@]}"; do
    [[ $kver == *-omarchy ]] || continue
    if ! KVER="$kver" REGEN=0 XE_ONLY=edp-dsc bash "$REPO/patch/edp-dsc/install.sh"; then
        echo "DSC NOT UPDATED for $kver: exact-source validation/build failed."
        echo 'No unvalidated module was installed. The distro initramfs hook will still run.'
        status=1
    fi
done
printf '%s === DSC maintenance finished (status=%s) ===\n' "$(date -Is)" "$status"
exit "$status"
