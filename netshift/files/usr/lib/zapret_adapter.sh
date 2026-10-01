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

zapret_adapter_is_netshift_auto_excluded() {
    local domain="$1"

    [ -n "$domain" ] && [ -f "$ZAPRET_NETSHIFT_AUTO_EXCLUDE_FILE" ] \
        && grep -qxF "$domain" "$ZAPRET_NETSHIFT_AUTO_EXCLUDE_FILE" 2>/dev/null
}

zapret_adapter_remove_exclude() {
    local domain="$1"
    local script

    [ -n "$domain" ] || return 1
    script="$(zapret_adapter_script_path)" || return 1
    sh "$script" remove-exclude-quiet "$domain"
}

zapret_adapter_apply_now() {
    if [ -x "$ZAPRET_INIT_SCRIPT" ]; then
        "$ZAPRET_INIT_SCRIPT" reload > /dev/null 2>&1
        log "Zapret reloaded (immediate)" "debug"
    fi
}

# Refresh Zapret hostlists after exclude edits. nfqws on OpenWrt does not reliably
# reload on SIGHUP; signaling it can leave zapret in "running (1/2)" — use init reload.
zapret_adapter_apply_hostlist() {
    zapret_adapter_apply_debounced
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

zapret_adapter_count_valid_exclude_lines() {
    local file="$1"

    [ -f "$file" ] || {
        echo 0
        return 0
    }
    grep -v '^#' "$file" 2>/dev/null | grep -v '^[[:space:]]*$' | grep -v '[[:space:]]' | wc -l | tr -d ' '
}

zapret_adapter_exclude_counts_json() {
    local user_file="$ZAPRET_EXCLUDE_HOSTLIST"
    local auto_file="$ZAPRET_NETSHIFT_AUTO_EXCLUDE_FILE"
    local total netshift_auto

    total="$(zapret_adapter_count_valid_exclude_lines "$user_file")"
    netshift_auto="$(zapret_adapter_count_valid_exclude_lines "$auto_file")"

    jq -n \
        --argjson total "$total" \
        --argjson netshift_auto "$netshift_auto" \
        '{total: $total, netshift_auto: $netshift_auto, manual: ($total - $netshift_auto)}'
}

# filter: netshift_auto (default) | manual | all
# limit/offset only for manual|all (default limit 150)
zapret_adapter_list_excludes_json() {
    local filter="${1:-netshift_auto}"
    local limit="${2:-150}"
    local offset="${3:-0}"
    local user_file="$ZAPRET_EXCLUDE_HOSTLIST"
    local auto_file="$ZAPRET_NETSHIFT_AUTO_EXCLUDE_FILE"
    local user_raw auto_raw counts

    case "$filter" in
    netshift_auto|manual|all) ;;
    *) filter="netshift_auto" ;;
    esac

    if [ -z "$limit" ]; then
        limit=200
    fi
    case "$limit" in
    *[!0-9]*) limit=200 ;;
    esac
    if [ -z "$offset" ]; then
        offset=0
    fi
    case "$offset" in
    *[!0-9]*) offset=0 ;;
    esac

    counts="$(zapret_adapter_exclude_counts_json)"

    if [ ! -f "$user_file" ]; then
        echo "$counts" | jq \
            --arg f "$filter" \
            --argjson l "$limit" \
            --argjson o "$offset" \
            '. + {filter: $f, limit: $l, offset: $o, count: 0, excludes: []}'
        return 0
    fi

    user_raw="$(cat "$user_file" 2>/dev/null)" || user_raw=""
    auto_raw=""
    if [ -f "$auto_file" ]; then
        auto_raw="$(cat "$auto_file" 2>/dev/null)" || auto_raw=""
    fi

    auto_learn_init_state_file

    echo "$counts" | jq \
        --arg user "$user_raw" \
        --arg auto "$auto_raw" \
        --arg filter "$filter" \
        --argjson limit "$limit" \
        --argjson offset "$offset" \
        --slurpfile state "$AUTO_LEARN_STATE_FILE" \
        '
        def lines($raw):
            $raw
            | split("\n")
            | map(select(. != "" and .[0:1] != "#" and index(" ") == null));
        def state_by_name:
            reduce (($state[0].domains // [])[]) as $d ({}; .[$d.name] = $d);
        def enrich($name; $source):
            (state_by_name | .[$name]) as $st |
            {
                name: $name,
                source: $source,
                stage: (if $st == null then null else $st.stage end),
                reason: (if $st == null then null else $st.reason end),
                updated_at: (if $st == null then null else $st.updated_at end)
            };
        (lines($auto) | unique) as $auto_set |
        (lines($user) | unique | sort) as $user_set |
        (if $filter == "netshift_auto" then
            $auto_set
        elif $filter == "manual" then
            [$user_set[] | select(($auto_set | index(.)) == null)]
        else
            $user_set
        end) as $picked |
        {
            total: .total,
            netshift_auto: .netshift_auto,
            manual: .manual,
            filter: $filter,
            limit: $limit,
            offset: $offset,
            count: ($picked | length),
            excludes: (
                $picked
                | map(
                    . as $name |
                    enrich(
                        $name;
                        if ($auto_set | index($name)) != null then "netshift_auto" else "manual" end
                    )
                )
                | sort_by(.updated_at // 0)
                | reverse
                | .[$offset:($offset + $limit)]
            )
        }
        '
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
