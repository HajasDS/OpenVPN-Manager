#!/usr/bin/env bash
# =============================================================================
# lib/service.sh - systemd service management + status views
# =============================================================================

svc_start()   { systemctl start   "$OVPN_SERVICE" && log_info "OpenVPN started"; }
svc_stop()    { systemctl stop    "$OVPN_SERVICE" && log_info "OpenVPN stopped"; }
svc_restart() { systemctl restart "$OVPN_SERVICE" && log_info "OpenVPN restarted"; }
svc_enable()  { systemctl enable  "$OVPN_SERVICE" >/dev/null 2>&1; }
svc_disable() { systemctl disable "$OVPN_SERVICE" >/dev/null 2>&1; }

svc_is_active() { systemctl is-active --quiet "$OVPN_SERVICE"; }

svc_restart_checked() {
    # Restart and verify; on failure show the journal so the admin can react.
    ui_info "Restarting OpenVPN..."
    if systemctl restart "$OVPN_SERVICE" 2>/dev/null && sleep 1 && svc_is_active; then
        log_info "OpenVPN restarted"
        ui_msg "Service" "OpenVPN was restarted successfully and is running."
        return 0
    fi
    log_error "OpenVPN failed to (re)start"
    ui_show_text "OpenVPN failed to start" \
"The service did not come up. Recent journal entries:

$(journalctl -u "$OVPN_SERVICE" --no-pager -n 25 2>/dev/null)

Your previous configuration was backed up under:
${OVM_BACKUP_DIR}/${RUN_STAMP}"
    return 1
}

svc_status_text() {
    {
        echo "=== systemd status ==="
        systemctl status "$OVPN_SERVICE" --no-pager -l 2>&1 | head -n 20
        echo
        echo "=== Connected clients ==="
        svc_connected_clients
    } 2>/dev/null
}

svc_connected_clients() {
    if [[ -r "$OVPN_STATUS_LOG" ]]; then
        local out
        out="$(awk -F',' '/^CLIENT_LIST/ {printf "  %-20s real: %-22s vpn: %-16s since: %s\n", $2, $3, $4, $8}' \
                "$OVPN_STATUS_LOG")"
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
        else
            echo "  (no clients connected)"
        fi
    else
        echo "  (status log not available)"
    fi
}

service_menu() {
    while true; do
        local state choice
        state="$(systemctl is-active "$OVPN_SERVICE" 2>/dev/null || true)"
        choice="$(ui_menu "Service control" "OpenVPN service is currently: ${state^^}" \
            "status"  "Show detailed status and connected clients" \
            "restart" "Restart OpenVPN" \
            "start"   "Start OpenVPN" \
            "stop"    "Stop OpenVPN" \
            "logs"    "View OpenVPN journal (last 100 lines)" \
            "back"    "Back to main menu")" || return 0
        case "$choice" in
            status)  ui_show_text "OpenVPN status" "$(svc_status_text)" ;;
            restart) svc_restart_checked ;;
            start)   svc_start && ui_msg "Service" "OpenVPN started." ;;
            stop)
                if ui_yesno "Stop OpenVPN" "All VPN clients will be disconnected. Stop the service?" defaultno; then
                    svc_stop && ui_msg "Service" "OpenVPN stopped."
                fi ;;
            logs)
                ui_show_text "OpenVPN journal" \
                    "$(journalctl -u "$OVPN_SERVICE" --no-pager -n 100 2>/dev/null)" ;;
            back)    return 0 ;;
        esac
    done
}
