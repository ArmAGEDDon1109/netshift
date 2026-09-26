# shellcheck shell=ash

# Zapret integration for NetShift auto-learn (exclude-list / 90-script.sh API).

zapret_adapter_script_path() {
    if [ -f "$ZAPRET_90_SCRIPT" ]; then
        echo "$ZAPRET_90_SCRIPT"
        return 0
    fi
    if [ -f "$ZAPRET_90_SCRIPT_SHIPPED" ]; then
        echo "$ZAPRET_90_SCRIPT_SHIPPED"
        return 0
    fi
    return 1
}

zapret_adapter_is_installed() {
    [ -x "$ZAPRET_INIT_SCRIPT" ]
}

# Copy shipped 90-script.sh into Zapret custom.d and reload Zapret.
# $1: force_reload (1 = reload even when the file was already up to date)
zapret_adapter_deploy_script() {
    local force_reload="${1:-0}"
    local shipped tmp deployed=0 target_dir

    shipped="$ZAPRET_90_SCRIPT_SHIPPED"
    if [ ! -r "$shipped" ]; then
        log "Zapret 90-script not found at $shipped" "error"
        return 1
    fi

    target_dir="${ZAPRET_90_SCRIPT%/*}"
    mkdir -p "$target_dir"

    if [ -f "$ZAPRET_90_SCRIPT" ] && cmp -s "$shipped" "$ZAPRET_90_SCRIPT" 2>/dev/null; then
        log "Zapret 90-script already deployed at $ZAPRET_90_SCRIPT" "debug"
    else
        if [ -f "$ZAPRET_90_SCRIPT" ]; then
            cp "$ZAPRET_90_SCRIPT" "${ZAPRET_90_SCRIPT}.bak.pre-netshift" 2>/dev/null || true
        fi
        tmp="${ZAPRET_90_SCRIPT}.tmp.$$"
        if ! cp "$shipped" "$tmp"; then
            log "Failed to copy Zapret 90-script to $tmp" "error"
            rm -f "$tmp" 2>/dev/null
            return 1
        fi
        chmod 0755 "$tmp"
        if ! mv "$tmp" "$ZAPRET_90_SCRIPT"; then
            log "Failed to install Zapret 90-script at $ZAPRET_90_SCRIPT" "error"
            rm -f "$tmp" 2>/dev/null
            return 1
        fi
        deployed=1
        log "Deployed Zapret 90-script to $ZAPRET_90_SCRIPT" "info"
    fi

    if [ "$deployed" -eq 1 ] || [ "$force_reload" -eq 1 ]; then
        if [ -x "$ZAPRET_INIT_SCRIPT" ]; then
            "$ZAPRET_INIT_SCRIPT" reload > /dev/null 2>&1
            log "Zapret reloaded after 90-script deploy" "info"
        else
            log "Zapret init script not found at $ZAPRET_INIT_SCRIPT; 90-script deployed but Zapret not reloaded" "warn"
        fi
    fi

    return 0
}

zapret_adapter_sync_from_uci() {
    if ! auto_learn_is_enabled || ! auto_learn_zapret_enabled; then
        return 0
    fi

    zapret_adapter_deploy_script 0
}

zapret_adapter_has_api() {
    local script
    script="$(zapret_adapter_script_path)" || return 1
    [ -f "$script" ]
}

zapret_adapter_is_excluded() {
    local domain="$1"
    local script

    script="$(zapret_adapter_script_path)" || return 1
    if sh "$script" is-excluded "$domain" 2>/dev/null; then
        return 0
    fi
    return 1
}

zapret_adapter_add_exclude() {
    local domain="$1"
    local script

    [ -n "$domain" ] || return 1
    script="$(zapret_adapter_script_path)" || return 1

    if zapret_adapter_is_excluded "$domain"; then
        return 0
    fi

    sh "$script" add-exclude-quiet "$domain"
}

zapret_adapter_remove_exclude() {
    local domain="$1"
    local script

    [ -n "$domain" ] || return 1
    script="$(zapret_adapter_script_path)" || return 1
    sh "$script" remove-exclude-quiet "$domain"
}

zapret_adapter_apply_debounced() {
    local now last pending

    now="$(date +%s)"
    if [ -f "$ZAPRET_RELOAD_DEBOUNCE_FILE" ]; then
        last="$(cat "$ZAPRET_RELOAD_DEBOUNCE_FILE" 2>/dev/null)"
        case "$last" in
            *[!0-9]*) last=0 ;;
        esac
        if [ "$((now - last))" -lt "$ZAPRET_RELOAD_DEBOUNCE_SEC" ]; then
            touch "$ZAPRET_RELOAD_DEBOUNCE_FILE.pending" 2>/dev/null
            return 0
        fi
    fi

    echo "$now" > "$ZAPRET_RELOAD_DEBOUNCE_FILE"
    rm -f "$ZAPRET_RELOAD_DEBOUNCE_FILE.pending" 2>/dev/null

    if [ -x "$ZAPRET_INIT_SCRIPT" ]; then
        "$ZAPRET_INIT_SCRIPT" reload > /dev/null 2>&1
        log "Zapret reloaded (debounced)" "info"
    fi
}

zapret_adapter_status_json() {
    local installed=0 api=0 script=""

    if zapret_adapter_is_installed; then
        installed=1
    fi
    if zapret_adapter_has_api; then
        api=1
        script="$(zapret_adapter_script_path)"
    fi

    jq -n \
        --argjson installed "$installed" \
        --argjson api "$api" \
        --arg script "$script" \
        --arg shipped "$ZAPRET_90_SCRIPT_SHIPPED" \
        --arg target "$ZAPRET_90_SCRIPT" \
        --arg exclude_file "$ZAPRET_EXCLUDE_HOSTLIST" \
        --arg auto_file "$ZAPRET_NETSHIFT_AUTO_EXCLUDE_FILE" \
        '{
            installed: ($installed == 1),
            api: ($api == 1),
            script: (if $script == "" then null else $script end),
            shipped_script: $shipped,
            target_script: $target,
            exclude_file: $exclude_file,
            auto_file: $auto_file
        }'
}
