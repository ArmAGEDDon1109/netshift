# shellcheck shell=ash

auto_learn_ensure_state_dir() {
    mkdir -p "$NETSHIFT_STATE_DIR"
}

auto_learn_init_state_file() {
    auto_learn_ensure_state_dir
    if [ ! -f "$AUTO_LEARN_STATE_FILE" ]; then
        jq -n '{domains: []}' > "$AUTO_LEARN_STATE_FILE"
    fi
}

auto_learn_is_enabled() {
    local enabled

    config_get_bool enabled "auto_learn" "enabled" 0
    [ "$enabled" -eq 1 ]
}

auto_learn_zapret_enabled() {
    local enabled

    config_get_bool enabled "auto_learn" "zapret_enabled" 1
    [ "$enabled" -eq 1 ]
}

auto_learn_get_target_section() {
    local target_section

    config_get target_section "auto_learn" "target_section" "main"
    if section_has_configured_outbound "$target_section"; then
        echo "$target_section"
        return 0
    fi
    return 1
}

auto_learn_get_max_domains() {
    local max_domains

    config_get max_domains "auto_learn" "max_domains" "$AUTO_LEARN_DEFAULT_MAX_DOMAINS"
    case "$max_domains" in
        *[!0-9]*) max_domains="$AUTO_LEARN_DEFAULT_MAX_DOMAINS" ;;
    esac
    echo "$max_domains"
}

auto_learn_normalize_domain() {
    local domain="$1"

    domain="$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    domain="$(echo "$domain" | sed 's/^[Hh][Tt][Tt][Pp][Ss]*://;s/^[Hh][Tt][Tt][Pp]://')"
    domain="${domain%%/*}"
    domain="${domain%%:*}"
    echo "$domain"
}

auto_learn_validate_domain() {
    local domain="$1"

    domain="$(auto_learn_normalize_domain "$domain")"
    [ -n "$domain" ] && is_domain_suffix "$domain"
}

auto_learn_domain_in_state() {
    local domain="$1"

    auto_learn_init_state_file
    jq -e --arg domain "$domain" \
        '.domains[] | select(.name == $domain) | .name' \
        "$AUTO_LEARN_STATE_FILE" >/dev/null 2>&1
}

auto_learn_upsert_domain() {
    local domain="$1" stage="$2" reason="$3"
    local now tmpfile

    auto_learn_init_state_file
    now="$(date +%s)"
    tmpfile="$(mktemp)"

    jq --arg domain "$domain" \
        --arg stage "$stage" \
        --arg reason "$reason" \
        --argjson now "$now" \
        '
        .domains = (
            [.domains[] | select(.name != $domain)]
            + [{
                name: $domain,
                stage: $stage,
                reason: $reason,
                updated_at: $now
            }]
        )
        ' "$AUTO_LEARN_STATE_FILE" > "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }

    mv "$tmpfile" "$AUTO_LEARN_STATE_FILE"
}

auto_learn_remove_domain_from_state() {
    local domain="$1"
    local tmpfile

    auto_learn_init_state_file
    tmpfile="$(mktemp)"
    jq --arg domain "$domain" \
        '.domains = [.domains[] | select(.name != $domain)]' \
        "$AUTO_LEARN_STATE_FILE" > "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }
    mv "$tmpfile" "$AUTO_LEARN_STATE_FILE"
}

auto_learn_list_netshift_domains() {
    auto_learn_init_state_file
    jq -r '.domains[] | select(.stage == "netshift") | .name' "$AUTO_LEARN_STATE_FILE"
}

auto_learn_hotpatch_ruleset() {
    local section="$1"
    local domain="$2"
    local ruleset_tag ruleset_filepath json_array

    [ -n "$section" ] && [ -n "$domain" ] || return 1

    ruleset_tag="$(get_ruleset_tag "$section" "$AUTO_LEARN_RULESET_NAME" "domains")"
    ruleset_filepath="$TMP_RULESET_FOLDER/$ruleset_tag.json"

    if ! file_exists "$ruleset_filepath"; then
        log "Auto-learn ruleset $ruleset_filepath is not present (sing-box not running?); domain queued in state only" "warn"
        return 1
    fi

    json_array="$(comma_string_to_json_array "$domain")"
    patch_source_ruleset_rules "$ruleset_filepath" "domain_suffix" "$json_array"
    log "Auto-learn hot-patched $domain into $ruleset_filepath" "info"
}

auto_learn_remove_from_ruleset() {
    local section="$1"
    local domain="$2"
    local ruleset_tag ruleset_filepath tmpfile

    ruleset_tag="$(get_ruleset_tag "$section" "$AUTO_LEARN_RULESET_NAME" "domains")"
    ruleset_filepath="$TMP_RULESET_FOLDER/$ruleset_tag.json"
    [ -f "$ruleset_filepath" ] || return 0

    tmpfile="$(mktemp)"
    jq --arg domain "$domain" \
        '
        .rules = [
            .rules[]
            | if has("domain_suffix") then
                .domain_suffix = (.domain_suffix | map(select(. != $domain)))
              else .
              end
        ]
        ' "$ruleset_filepath" > "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }
    mv "$tmpfile" "$ruleset_filepath"
}

auto_learn_add_netshift_domain() {
    local domain="$1" reason="$2"
    local section max_domains count

    domain="$(auto_learn_normalize_domain "$domain")"
    if ! auto_learn_validate_domain "$domain"; then
        log "Auto-learn: invalid domain '$domain'" "warn"
        return 1
    fi

    section="$(auto_learn_get_target_section)" || {
        log "Auto-learn: no valid target section configured" "warn"
        return 1
    }

    max_domains="$(auto_learn_get_max_domains)"
    count="$(auto_learn_list_netshift_domains | wc -l | tr -d ' ')"
    if [ "$count" -ge "$max_domains" ] && ! auto_learn_domain_in_state "$domain"; then
        log "Auto-learn: max_domains ($max_domains) reached" "warn"
        return 1
    fi

    auto_learn_upsert_domain "$domain" "netshift" "$reason"
    auto_learn_hotpatch_ruleset "$section" "$domain"
}

auto_learn_probe_direct() {
    local domain="$1"
    local code

    domain="$(auto_learn_normalize_domain "$domain")"
    code="$(curl -m "$AUTO_LEARN_CURL_TIMEOUT" -sS -o /dev/null -w "%{http_code}" "https://$domain/" 2>/dev/null)" || return 1
    case "$code" in
        2*|3*) return 0 ;;
    esac
    return 1
}

auto_learn_probe_via_service_proxy() {
    local domain="$1"
    local code proxy_url

    domain="$(auto_learn_normalize_domain "$domain")"
    if ! sing_box_process_exists; then
        return 1
    fi

    proxy_url="http://$SB_SERVICE_MIXED_INBOUND_ADDRESS:$SB_SERVICE_MIXED_INBOUND_PORT"
    code="$(curl -m "$AUTO_LEARN_CURL_TIMEOUT" -sS -x "$proxy_url" -o /dev/null -w "%{http_code}" "https://$domain/" 2>/dev/null)" || return 1
    case "$code" in
        2*|3*) return 0 ;;
    esac
    return 1
}

auto_learn_process_domain() {
    local domain="$1"
    local reason="blocked"

    domain="$(auto_learn_normalize_domain "$domain")"
    if ! auto_learn_validate_domain "$domain"; then
        echo '{"success":false,"message":"invalid domain"}'
        return 1
    fi

    if ! auto_learn_is_enabled; then
        echo '{"success":false,"message":"auto-learn disabled"}'
        return 1
    fi

    if auto_learn_probe_direct "$domain"; then
        auto_learn_upsert_domain "$domain" "resolved_direct" "reachable"
        echo "{\"success\":true,\"stage\":\"resolved_direct\",\"domain\":\"$domain\"}"
        return 0
    fi

    if auto_learn_zapret_enabled && zapret_adapter_is_installed && zapret_adapter_has_api; then
        if ! zapret_adapter_is_excluded "$domain"; then
            zapret_adapter_add_exclude "$domain"
            zapret_adapter_apply_debounced
            auto_learn_upsert_domain "$domain" "zapret_pending" "trying_exclude"
            echo "{\"success\":true,\"stage\":\"zapret_pending\",\"domain\":\"$domain\",\"message\":\"added to zapret exclude; re-probe later\"}"
            return 0
        fi

        if auto_learn_probe_direct "$domain"; then
            auto_learn_upsert_domain "$domain" "resolved_zapret" "exclude_helped"
            echo "{\"success\":true,\"stage\":\"resolved_zapret\",\"domain\":\"$domain\"}"
            return 0
        fi
    fi

    if auto_learn_probe_via_service_proxy "$domain"; then
        reason="geo_or_block"
    fi

    if auto_learn_add_netshift_domain "$domain" "$reason"; then
        echo "{\"success\":true,\"stage\":\"netshift\",\"domain\":\"$domain\",\"reason\":\"$reason\"}"
        return 0
    fi

    auto_learn_upsert_domain "$domain" "failed" "$reason"
    echo "{\"success\":false,\"stage\":\"failed\",\"domain\":\"$domain\"}"
    return 1
}

auto_learn_status_json() {
    local enabled=0 target_section="" count=0 zapret_status

    if auto_learn_is_enabled; then
        enabled=1
    fi
    target_section="$(auto_learn_get_target_section 2>/dev/null)" || target_section=""
    auto_learn_init_state_file
    count="$(jq '.domains | length' "$AUTO_LEARN_STATE_FILE" 2>/dev/null)"
    zapret_status="$(zapret_adapter_status_json)"

    jq -n \
        --argjson enabled "$enabled" \
        --arg target_section "$target_section" \
        --argjson count "$count" \
        --argjson zapret "$zapret_status" \
        '{enabled: ($enabled == 1), target_section: (if $target_section == "" then null else $target_section end), domain_count: $count, zapret: $zapret}'
}

auto_learn_list_json() {
    auto_learn_init_state_file
    jq '{domains: .domains}' "$AUTO_LEARN_STATE_FILE"
}

auto_learn_clear_netshift_domains() {
    local section domain

    section="$(auto_learn_get_target_section)" || section=""
    auto_learn_init_state_file

    for domain in $(jq -r '.domains[] | select(.stage == "netshift") | .name' "$AUTO_LEARN_STATE_FILE"); do
        [ -n "$section" ] && auto_learn_remove_from_ruleset "$section" "$domain"
        auto_learn_remove_domain_from_state "$domain"
    done
}

auto_learn_remove_domain() {
    local domain="$1"
    local section stage

    domain="$(auto_learn_normalize_domain "$domain")"
    section="$(auto_learn_get_target_section 2>/dev/null)" || section=""
    stage="$(jq -r --arg domain "$domain" '.domains[] | select(.name == $domain) | .stage' "$AUTO_LEARN_STATE_FILE" 2>/dev/null)"

    if [ "$stage" = "netshift" ] && [ -n "$section" ]; then
        auto_learn_remove_from_ruleset "$section" "$domain"
    fi
    if zapret_adapter_has_api && zapret_adapter_is_excluded "$domain"; then
        zapret_adapter_remove_exclude "$domain"
        zapret_adapter_apply_debounced
    fi
    auto_learn_remove_domain_from_state "$domain"
}

configure_auto_learned_domain_list() {
    local section="$1"
    local route_rule_tag="$2"
    local target_section items ruleset_filepath json_array

    if ! auto_learn_is_enabled; then
        return 0
    fi

    target_section="$(auto_learn_get_target_section)" || return 0
    [ "$section" = "$target_section" ] || return 0

    items="$(auto_learn_list_netshift_domains | tr '\n' ',' | sed 's/,$//')"
    [ -n "$items" ] || return 0

    prepare_source_ruleset "$section" "$AUTO_LEARN_RULESET_NAME" "domains" "$route_rule_tag"
    ruleset_filepath="$TMP_RULESET_FOLDER/$(get_ruleset_tag "$section" "$AUTO_LEARN_RULESET_NAME" "domains").json"
    json_array="$(comma_string_to_json_array "$items")"
    patch_source_ruleset_rules "$ruleset_filepath" "domain_suffix" "$json_array"
    log "Configured auto-learned domains for section '$section'" "info"
}

auto_learn_cli() {
    local action="${1:-}"
    local arg="${2:-}"

    case "$action" in
    status)
        auto_learn_status_json
        ;;
    list)
        auto_learn_list_json
        ;;
    probe)
        auto_learn_process_domain "$arg"
        ;;
    add)
        if auto_learn_add_netshift_domain "$arg" "manual"; then
            echo "{\"success\":true,\"stage\":\"netshift\",\"domain\":\"$arg\"}"
        else
            echo '{"success":false,"message":"failed to add domain"}'
            return 1
        fi
        ;;
    remove)
        auto_learn_remove_domain "$arg"
        echo "{\"success\":true,\"domain\":\"$arg\"}"
        ;;
    clear)
        auto_learn_clear_netshift_domains
        echo '{"success":true}'
        ;;
    zapret-status)
        zapret_adapter_status_json
        ;;
    *)
        echo '{"success":false,"message":"unknown auto_learn action"}'
        return 1
        ;;
    esac
}
