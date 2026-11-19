#!/system/bin/sh
# Pick the gatekeeper HAL implementation the installed vendor image uses.
#
# r8q vendors ship two HIDL gatekeeper services: the MDFPP one (the stock
# Samsung/AOSP builds) and the QTI one (OneUI). The vendor property
# ro.hardware.gatekeeper is authoritative; the fingerprint is only a fallback
# for a vendor image that does not set it.

TAG="gatekeeper_select"

log_msg() {
    echo "$TAG: $*" > /dev/kmsg 2>/dev/null
    log -t "$TAG" "$*" 2>/dev/null
}

hw="$(getprop ro.hardware.gatekeeper)"
fp="$(getprop aera.system.fingerprint)"

# aera.system.fingerprint is filled in by AERA once the installed system is
# readable; give it a short grace period before falling back.
i=0
while [ -z "$fp" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
    fp="$(getprop aera.system.fingerprint)"
done

log_msg "ro.hardware.gatekeeper=$hw aera.system.fingerprint=$fp"

case "$hw" in
qti)
    log_msg "vendor gatekeeper=qti"
    setprop recovery.gatekeeper qti
    ;;
mdfpp)
    log_msg "vendor gatekeeper=mdfpp"
    setprop recovery.gatekeeper mdfpp
    ;;
*)
    case "$fp" in
    samsung/*)
        log_msg "no vendor gatekeeper property; Samsung fingerprint -> qti"
        setprop recovery.gatekeeper qti
        ;;
    *)
        log_msg "no vendor gatekeeper property; AOSP fingerprint -> mdfpp"
        setprop recovery.gatekeeper mdfpp
        ;;
    esac
    ;;
esac
