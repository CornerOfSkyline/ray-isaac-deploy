#!/bin/bash
# repair-novnc.sh - Fix noVNC binding to 127.0.0.1:6006
# Audit mode (default): read-only inspection, no changes
# Apply mode (--apply): controlled restart with full identity verification
set -euo pipefail

STATE_DIR="${HOME}/.local/state/ray-isaac-deploy"
PID_DIR="${STATE_DIR}/pids"
LOG_DIR="${STATE_DIR}/logs"

log()   { echo "[$(date +%H:%M:%S)] $*"; }
warn()  { log "WARN: $*" >&2; }
die()   { log "FATAL: $*" >&2; exit 1; }

ensure_dirs() { mkdir -p "${LOG_DIR}" "${PID_DIR}" 2>/dev/null || true; }

pid_file()      { echo "${PID_DIR}/$1.pid"; }
identity_file() { echo "${PID_DIR}/$1.identity.json"; }
read_pid()      { cat "$(pid_file "$1")" 2>/dev/null || echo ""; }

# Read saved identity if it exists
read_identity() {
    local f
    f="$(identity_file "$1")"
    if [[ -f "${f}" ]]; then cat "${f}"; else echo "{}"; fi
}

# Build current identity for a PID
build_identity() {
    local pid="$1"
    python3 -c "
import json, os
pid = int('${pid}')
uid = int(open(f'/proc/{pid}/status').read().split('\nUid:')[1].split()[0]) if os.path.exists(f'/proc/{pid}/status') else 0
start_time = int(open(f'/proc/{pid}/stat').read().split()[21]) if os.path.exists(f'/proc/{pid}/stat') else 0
exe = os.readlink(f'/proc/{pid}/exe') if os.path.exists(f'/proc/{pid}/exe') else ''
with open(f'/proc/{pid}/cmdline', 'rb') as f:
    raw = f.read().decode().replace(chr(0), ' ').strip()[:500]
print(json.dumps({'pid':pid, 'uid':uid, 'start_time':start_time, 'exe':exe, 'cmdline':raw}))
" 2>/dev/null || echo '{}'
}

# Compare two identity JSON strings; return 0 if ALL key fields match
identity_matches() {
    local saved="$1" current="$2"
    python3 -c "
import json, sys
s = json.loads(sys.argv[1])
c = json.loads(sys.argv[2])
for field in ('pid','uid','start_time','exe','cmdline'):
    sv = str(s.get(field,''))
    cv = str(c.get(field,''))
    if sv != cv:
        sys.exit(1)
sys.exit(0)
" "${saved}" "${current}" 2>/dev/null
}

# Kill with identity verification before each signal
safe_kill() {
    local pid="$1" saved_identity="$2" signal="${3:-TERM}"
    if ! kill -0 "${pid}" 2>/dev/null; then
        log "  PID ${pid} already gone"
        return 0
    fi
    local current
    current=$(build_identity "${pid}")
    if ! identity_matches "${saved_identity}" "${current}"; then
        die "  Identity mismatch for PID ${pid}! Refusing ${signal}."
    fi
    log "  Sending SIG${signal} to PID ${pid} (identity verified)"
    kill "-${signal}" "${pid}" 2>/dev/null || true
}

# Save identity atomically
save_identity() {
    local name="$1" pid="$2"
    local tmpfile identity
    tmpfile="$(identity_file "${name}").tmp.$$"
    identity=$(build_identity "${pid}")
    echo "${identity}" > "${tmpfile}"
    mv "${tmpfile}" "$(identity_file "${name}")"
}

# ============================================================
# AUDIT MODE (default)
# ============================================================
run_audit() {
    log "=== noVNC Audit (read-only) ==="

    # 1. All processes on port 6006
    log "Processes on port 6006:"
    local pids
    pids=$(ss -tlnp 2>/dev/null | grep ':6006 ' | grep -oP 'pid=\d+' | cut -d= -f2 || true)
    if [[ -z "${pids}" ]]; then
        log "  No process listening on port 6006"
    fi
    for pid in ${pids}; do
        local identity
        identity=$(build_identity "${pid}")
        log "  PID=${pid}: $(echo "${identity}" | python3 -c "import json,sys;d=json.load(sys.stdin);print('UID='+str(d.get('uid',''))+' EXE='+str(d.get('exe',''))[-80:])" 2>/dev/null || echo "parse error")"
    done

    # 2. Managed identity
    local managed_pid
    managed_pid=$(read_pid "novnc")
    local saved
    saved=$(read_identity "novnc")
    log ""
    log "Managed noVNC record:"
    if [[ -n "${managed_pid}" ]]; then
        log "  PID file: ${managed_pid}"
        log "  Saved identity: ${saved}"
        if kill -0 "${managed_pid}" 2>/dev/null; then
            local current
            current=$(build_identity "${managed_pid}")
            if identity_matches "${saved}" "${current}"; then
                log "  Status: MANAGED (identity matches)"
            else
                log "  Status: IDENTITY_MISMATCH"
                log "    Saved:  ${saved}"
                log "    Current: ${current}"
            fi
        else
            log "  Status: PID_STALE (process not running)"
        fi
    else
        log "  No managed PID file"
    fi

    # 3. Current binding
    local bind
    bind=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
    log ""
    log "Current binding: ${bind:-NONE}"
    log "Expected binding: 127.0.0.1:6006"
    if [[ "${bind}" == "127.0.0.1:6006" ]]; then
        log "Status: CORRECT - no repair needed"
    elif [[ "${bind}" == "0.0.0.0:6006" ]] || [[ "${bind}" == *":6006" ]]; then
        log "Status: NEEDS REPAIR - run with --apply to fix"
    else
        log "Status: UNKNOWN_BINDING"
    fi

    # 4. Public reachability check
    log ""
    log "Public reachability check:"
    local pub_code
    pub_code=$(curl -s --connect-timeout 3 -o /dev/null -w '%{http_code}' "http://180.97.68.228:6006/vnc.html" 2>/dev/null || echo "000")
    log "  External HTTP on port 6006: ${pub_code} ($([[ "${pub_code}" == "000" ]] && echo "NOT REACHABLE" || echo "REACHABLE"))"
}

# ============================================================
# APPLY MODE (--apply)
# ============================================================
run_apply() {
    log "=== noVNC Repair (Apply) ==="
    ensure_dirs

    local bind
    bind=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
    if [[ "${bind}" == "127.0.0.1:6006" ]]; then
        log "Binding already correct. No repair needed."
        return 0
    fi

    # Find managed websockify
    local managed_pid
    managed_pid=$(read_pid "novnc")
    if [[ -z "${managed_pid}" ]]; then
        die "No managed noVNC PID found. Cannot safely repair. Run audit first."
    fi
    if ! kill -0 "${managed_pid}" 2>/dev/null; then
        die "Managed PID ${managed_pid} is not running. Run audit to diagnose."
    fi

    # Verify managed identity
    local saved current
    saved=$(read_identity "novnc")
    current=$(build_identity "${managed_pid}")
    log "Managed PID: ${managed_pid}"
    log "Saved:  ${saved}"
    log "Current: ${current}"

    if ! identity_matches "${saved}" "${current}"; then
        die "Identity mismatch for managed PID ${managed_pid}. Refusing to proceed."
    fi

    # Verify current process IS websockify
    local cmdline
    cmdline=$(tr '\0' ' ' < "/proc/${managed_pid}/cmdline" 2>/dev/null || echo "")
    if [[ "${cmdline}" != *"websockify"* ]]; then
        die "PID ${managed_pid} does not appear to be websockify: ${cmdline}"
    fi

    # Verify no OTHER process is listening on 6006
    local all_pids
    all_pids=$(ss -tlnp 2>/dev/null | grep ':6006 ' | grep -oP 'pid=\d+' | cut -d= -f2 || true)
    for pid in ${all_pids}; do
        if [[ "${pid}" != "${managed_pid}" ]]; then
            local other_cmd
            other_cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || echo "")
            die "Another process (PID ${pid}) is also on port 6006: ${other_cmd}. Manual investigation required."
        fi
    done

    # ---- All checks passed, proceed with controlled restart ----
    log "Identity verified. Proceeding with controlled restart."

    # Stop: SIGTERM with identity re-check
    safe_kill "${managed_pid}" "${saved}" "TERM"
    local waited=0
    while kill -0 "${managed_pid}" 2>/dev/null && [[ ${waited} -lt 15 ]]; do
        sleep 1; waited=$((waited + 1))
    done

    if kill -0 "${managed_pid}" 2>/dev/null; then
        log "SIGTERM did not stop process after ${waited}s"
        # Re-verify identity before SIGKILL
        local current2
        current2=$(build_identity "${managed_pid}")
        if identity_matches "${saved}" "${current2}"; then
            safe_kill "${managed_pid}" "${saved}" "KILL"
            sleep 1
        else
            die "Identity changed during shutdown! Refusing SIGKILL."
        fi
    fi

    if kill -0 "${managed_pid}" 2>/dev/null; then
        die "Failed to stop PID ${managed_pid} even with SIGKILL"
    fi
    log "  Stopped PID ${managed_pid}"

    # Verify port is free
    sleep 1
    if ss -tlnp 2>/dev/null | grep -q ':6006 '; then
        die "Port 6006 still occupied after stopping managed process"
    fi

    # Start new websockify on 127.0.0.1:6006
    log "Starting new websockify on 127.0.0.1:6006..."
    nohup /home/zjf/.local/bin/websockify --web=/home/zjf/noVNC-1.5.0 \
        127.0.0.1:6006 127.0.0.1:5901 > "${LOG_DIR}/novnc.log" 2>&1 &
    local new_pid=$!
    sleep 2

    if ! kill -0 "${new_pid}" 2>/dev/null; then
        die "New websockify (PID ${new_pid}) died immediately. Check ${LOG_DIR}/novnc.log"
    fi

    # Save new identity atomically
    echo "${new_pid}" > "$(pid_file novnc)"
    save_identity "novnc" "${new_pid}"

    # Verify binding
    local new_bind
    new_bind=$(ss -tlnp 2>/dev/null | grep ':6006 ' | awk '{print $4}' | head -1)
    if [[ "${new_bind}" != "127.0.0.1:6006" ]]; then
        warn "New binding is ${new_bind}, expected 127.0.0.1:6006"
        warn "Rollback: NOT restoring old 0.0.0.0 binding"
        exit 1
    fi

    # Verify HTTP access
    if curl -s --connect-timeout 3 http://127.0.0.1:6006/vnc.html >/dev/null 2>&1; then
        log "HTTP check: OK"
    else
        warn "HTTP check: FAILED (may need browser refresh)"
    fi

    log "Repair SUCCESS: noVNC bound to 127.0.0.1:6006 (PID ${new_pid})"
    return 0
}

# ============================================================
# ADOPT MODE (--adopt)
# ============================================================
run_adopt() {
    log "=== noVNC Adoption ==="
    ensure_dirs

    local pids
    pids=$(ss -tlnp 2>/dev/null | grep ':6006 ' | grep -oP 'pid=\d+' | cut -d= -f2 || true)
    if [[ -z "${pids}" ]]; then
        die "No process listening on port 6006"
    fi
    local pid_count
    pid_count=$(echo "${pids}" | wc -w)
    if [[ ${pid_count} -gt 1 ]]; then
        die "Multiple processes on port 6006: ${pids}. Manual investigation required."
    fi

    local pid="${pids}"
    log "Adopting PID ${pid} on port 6006..."

    local identity cmdline exe
    identity=$(build_identity "${pid}")
    exe=$(echo "${identity}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('exe',''))" 2>/dev/null || "")
    cmdline=$(echo "${identity}" | python3 -c "import json,sys;print(json.load(sys.stdin).get('cmdline',''))" 2>/dev/null || "")
    log "Identity: ${identity}"

    if [[ "${exe}" != *"python"* ]] && [[ "${cmdline}" != *"websockify"* ]]; then
        die "PID ${pid} does not appear to be websockify"
    fi
    if [[ "${cmdline}" != *"6006"* ]]; then
        die "PID ${pid} cmdline does not reference port 6006"
    fi

    local existing
    existing=$(read_pid "novnc")
    if [[ -n "${existing}" ]] && [[ "${existing}" != "${pid}" ]]; then
        if kill -0 "${existing}" 2>/dev/null; then
            die "Existing managed noVNC PID ${existing} still running. Cannot adopt another."
        fi
        warn "Stale PID file for ${existing} - cleaning up"
        rm -f "$(pid_file novnc)" "$(identity_file novnc)"
    fi

    echo "${pid}" > "$(pid_file novnc)"
    echo "${identity}" > "$(identity_file novnc)"
    log "Adoption SUCCESS: PID ${pid} registered as managed noVNC (NO signal sent)"
    log "  UID=$(echo "${identity}"|python3 -c "import json,sys;print(json.load(sys.stdin).get('uid',''))" 2>/dev/null)"
    log "  EXE=${exe}"
    log "  Run 'bash $0 --apply' to restart with 127.0.0.1:6006 binding."
}

# ============================================================
# Main
# ============================================================
case "${1:-}" in
    --apply)
        run_audit
        echo ""
        run_apply
        ;;
    --adopt)
        run_adopt
        ;;
    audit|status|"")
        run_audit
        ;;
    *)
        echo "Usage: $0 [--apply|--adopt]" >&2
        echo "  (no args)   Audit mode: inspect only, no changes" >&2
        echo "  --adopt     Adopt current 6006 listener as managed (no restart)" >&2
        echo "  --apply     Apply mode: controlled restart (requires prior adoption)" >&2
        exit 2
        ;;
esac