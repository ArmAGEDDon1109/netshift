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

auto_learn_get_zapret_probe_delay() {
    local delay

    config_get delay "auto_learn" "zapret_probe_delay" "$AUTO_LEARN_DEFAULT_ZAPRET_PROBE_DELAY"
    case "$delay" in
        *[!0-9]*) delay="$AUTO_LEARN_DEFAULT_ZAPRET_PROBE_DELAY" ;;
    esac
    echo "$delay"
}

auto_learn_get_domain_stage() {
    local domain="$1"

    auto_learn_init_state_file
    jq -r --arg domain "$domain" \
        '.domains[] | select(.name == $domain) | .stage' \
        "$AUTO_LEARN_STATE_FILE" 2>/dev/null
}

auto_learn_get_domain_updated_at() {
    local domain="$1"

    auto_learn_init_state_file
    jq -r --arg domain "$domain" \
        '.domains[] | select(.name == $domain) | .updated_at' \
        "$AUTO_LEARN_STATE_FILE" 2>/dev/null
}

auto_learn_domain_ready_for_probe() {
    local domain="$1"
    local stage now updated_at delay

    domain="$(auto_learn_normalize_domain "$domain")"
    if ! auto_learn_validate_domain "$domain"; then
        return 1
    fi

    if auto_learn_domain_covered_by_target_section_lists "$domain"; then
        auto_learn_mark_already_routed_in_section "$domain"
        return 1
    fi

    stage="$(auto_learn_get_domain_stage "$domain")"
    case "$stage" in
    already_routed)
        return 1
        ;;
    ""|failed)
        if [ -n "$stage" ]; then
            updated_at="$(auto_learn_get_domain_updated_at "$domain")"
            case "$updated_at" in
                *[!0-9]*) return 1 ;;
            esac
            now="$(date +%s)"
            if [ "$((now - updated_at))" -lt "$AUTO_LEARN_PROBE_COOLDOWN_SEC" ]; then
                return 1
            fi
        fi
        return 0
        ;;
    zapret_pending)
        updated_at="$(auto_learn_get_domain_updated_at "$domain")"
        case "$updated_at" in
            *[!0-9]*) return 1 ;;
        esac
        delay="$(auto_learn_get_zapret_probe_delay)"
        now="$(date +%s)"
        [ "$((now - updated_at))" -ge "$delay" ]
        ;;
    resolved_direct|resolved_zapret|resolved_desync|netshift)
        return 1
        ;;
    *)
        return 1
        ;;
    esac
}

auto_learn_ensure_ruleset_file() {
    local section ruleset_tag ruleset_filepath

    section="$(auto_learn_get_target_section)" || return 1
    ruleset_tag="$(get_ruleset_tag "$section" "$AUTO_LEARN_RULESET_NAME" "domains")"
    ruleset_filepath="$TMP_RULESET_FOLDER/$ruleset_tag.json"
    mkdir -p "$TMP_RULESET_FOLDER"
    create_source_rule_set "$ruleset_filepath"
}

auto_learn_normalize_domain() {
    local domain="$1"

    domain="$(echo "$domain" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    domain="$(echo "$domain" | sed \
        -e 's/^https:\/\///' \
        -e 's/^http:\/\///' \
        -e 's/^HTTPS:\/\///' \
        -e 's/^HTTP:\/\///' \
        -e 's/^Https:\/\///' \
        -e 's/^Http:\/\///')"
    domain="${domain%%/*}"
    domain="${domain%%:*}"
    echo "$domain"
}

auto_learn_is_http_reachable_code() {
    local code="$1"

    case "$code" in
    ""|000|000000) return 1 ;;
    esac
    return 0
}

auto_learn_domain_ends_with_suffix() {
    local domain="$1" suffix="$2"

    domain="$(auto_learn_normalize_domain "$domain")"
    [ "$domain" = "$suffix" ] && return 0
    case "$domain" in
    *."$suffix") return 0 ;;
    esac
    return 1
}

# User domain list for the auto-learn target section (same source as configure_user_domain_list).
auto_learn_collect_section_user_domain_suffixes() {
    local section="$1"
    local user_domain_list_type items

    config_get user_domain_list_type "$section" "user_domain_list_type" "disabled"
    case "$user_domain_list_type" in
    disabled) return 0 ;;
    dynamic) config_get items "$section" "user_domains" ;;
    text) config_get items "$section" "user_domains_text" ;;
    *) return 0 ;;
    esac

    parse_domain_or_subnet_string_to_commas_string "$items" "domains"
}

auto_learn_append_comma_suffixes_to_file() {
    local aggfile="$1"
    local items="$2"

    [ -n "$items" ] || return 0
    printf '%s' "$items" | tr ',' '\n' >> "$aggfile"
}

auto_learn_collect_local_domain_list_handler() {
    local filepath="$1"
    local part

    if ! file_exists "$filepath"; then
        return 0
    fi
    part="$(parse_domain_or_subnet_file_to_comma_string "$filepath" "domains")"
    auto_learn_append_comma_suffixes_to_file "$AUTO_LEARN_SUFFIX_AGG_FILE" "$part"
}

auto_learn_collect_ruleset_domain_suffixes() {
    local section="$1"
    local name="$2"
    local type="$3"
    local ruleset_tag ruleset_filepath

    ruleset_tag="$(get_ruleset_tag "$section" "$name" "$type")"
    ruleset_filepath="$TMP_RULESET_FOLDER/$ruleset_tag.json"
    [ -f "$ruleset_filepath" ] || return 0

    jq -r '.rules[]? | .domain_suffix[]?' "$ruleset_filepath" 2>/dev/null \
        >> "$AUTO_LEARN_SUFFIX_AGG_FILE"
}

# All domain_suffix entries that route the auto-learn target section (UCI + list files + built rulesets).
# Community geosite lists (.srs) are remote binary rulesets and are not expanded here.
auto_learn_collect_target_section_domain_suffixes() {
    local section="$1"
    local aggfile="$2"
    local items

    : > "$aggfile"
    AUTO_LEARN_SUFFIX_AGG_FILE="$aggfile"

    items="$(auto_learn_collect_section_user_domain_suffixes "$section")"
    auto_learn_append_comma_suffixes_to_file "$aggfile" "$items"

    config_list_foreach "$section" "local_domain_lists" auto_learn_collect_local_domain_list_handler

    auto_learn_collect_ruleset_domain_suffixes "$section" "user" "domains"
    auto_learn_collect_ruleset_domain_suffixes "$section" "local" "domains"
    auto_learn_collect_ruleset_domain_suffixes "$section" "remote" "domains"
    auto_learn_collect_ruleset_domain_suffixes "$section" "$AUTO_LEARN_RULESET_NAME" "domains"

    if [ -s "$aggfile" ]; then
        sort -u "$aggfile" > "${aggfile}.sorted"
        mv "${aggfile}.sorted" "$aggfile"
    fi
    unset AUTO_LEARN_SUFFIX_AGG_FILE
}

auto_learn_domain_covered_by_target_section_lists() {
    local domain="$1"
    local section aggfile rule

    domain="$(auto_learn_normalize_domain "$domain")"
    section="$(auto_learn_get_target_section)" || return 1

    aggfile="$(mktemp)"
    auto_learn_collect_target_section_domain_suffixes "$section" "$aggfile"

    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        if auto_learn_domain_ends_with_suffix "$domain" "$rule"; then
            rm -f "$aggfile"
            return 0
        fi
    done < "$aggfile"
    rm -f "$aggfile"
    return 1
}

auto_learn_mark_already_routed_in_section() {
    local domain="$1"

    domain="$(auto_learn_normalize_domain "$domain")"
    auto_learn_upsert_domain "$domain" "already_routed" "section_domain_lists"
}

auto_learn_should_skip_candidate() {
    local domain="$1" suffix

    domain="$(auto_learn_normalize_domain "$domain")"
    case "$domain" in
    localhost) return 0 ;;
    *.in-addr.arpa|*.ip6.arpa|in-addr.arpa|ip6.arpa) return 0 ;;
    ya.ru|*.ya.ru) return 0 ;;
    yandex.*|*.yandex.*) return 0 ;;
    esac
    case "$domain" in
    *.*) ;;
    *) return 0 ;;
    esac
    for suffix in $AUTO_LEARN_SKIP_DOMAIN_SUFFIXES; do
        auto_learn_domain_ends_with_suffix "$domain" "$suffix" && return 0
    done
    return 1
}

auto_learn_purge_skipped_domains() {
    local domain

    auto_learn_init_state_file
    for domain in $(jq -r '.domains[].name' "$AUTO_LEARN_STATE_FILE" 2>/dev/null); do
        [ -n "$domain" ] || continue
        if auto_learn_should_skip_candidate "$domain"; then
            auto_learn_unroute_domain_if_needed "$domain"
            auto_learn_remove_domain_from_state "$domain"
            log "Auto-learn: purged skipped domain $domain" "info"
        fi
    done
}

auto_learn_validate_domain() {
    local domain="$1"

    domain="$(auto_learn_normalize_domain "$domain")"
    if auto_learn_should_skip_candidate "$domain"; then
        return 1
    fi
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
        auto_learn_ensure_ruleset_file || {
            log "Auto-learn ruleset $ruleset_filepath is not present (sing-box not running?); domain queued in state only" "warn"
            return 1
        }
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
    auto_learn_hotpatch_ruleset "$section" "$domain" || \
        log "Auto-learn: $domain saved in state but ruleset hot-patch failed (reload NetShift if routing is missing)" "warn"
    return 0
}

auto_learn_is_fakeip_address() {
    local ip="$1"

    case "$ip" in
    198.18.*|198.19.*|127.*|0.*) return 0 ;;
    esac
    return 1
}

# Resolve A record via upstream DNS (not router dnsmasq/FakeIP).
auto_learn_resolve_real_ipv4() {
    local domain="$1"
    local dns ip

    domain="$(auto_learn_normalize_domain "$domain")"
    for dns in $AUTO_LEARN_PROBE_DNS_SERVERS; do
        ip="$(dig +short +time=3 +tries=1 "@$dns" A "$domain" 2>/dev/null \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)"
        if [ -n "$ip" ] && ! auto_learn_is_fakeip_address "$ip"; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# curl exit codes where TLS handshake completed (HTTP status/empty body may vary).
auto_learn_curl_tls_handshake_ok() {
    local rc="$1"

    case "$rc" in
    0|22|52) return 0 ;;
    35|51|53|54|58|59|60|64|66|77|83) return 1 ;;
    7|28|56) return 1 ;;
    *) return 1 ;;
    esac
}

# TLS handshake to $ip:443 with SNI=$domain (openssl when available).
auto_learn_openssl_tls_probe_ok() {
    local domain="$1" ip="$2"
    local out

    domain="$(auto_learn_normalize_domain "$domain")"
    [ -n "$ip" ] || return 1
    command -v openssl >/dev/null 2>&1 || return 1

    out="$(echo | openssl s_client -connect "${ip}:443" -servername "$domain" \
        -brief -tls1_2 2>/dev/null)" || return 1
    echo "$out" | grep -q 'CONNECTION ESTABLISHED' || return 1
    echo "$out" | grep -qi 'connection reset\|alert handshake failure\|ssl handshake failure' && return 1
    return 0
}

# TLS reachability via real DNS (--resolve), not router FakeIP.
# Zapret often breaks TLS while TCP still connects; openssl/curl SSL errors catch that.
auto_learn_tls_probe_ok() {
    local domain="$1"
    local proxy_url="$2"
    local ip rc resolve_args

    domain="$(auto_learn_normalize_domain "$domain")"

    if [ -n "$proxy_url" ]; then
        ip="$(auto_learn_resolve_real_ipv4 "$domain")"
        resolve_args=""
        if [ -n "$ip" ]; then
            resolve_args="--resolve ${domain}:443:${ip}"
        fi
        curl -4 -m "$AUTO_LEARN_CURL_TIMEOUT" --connect-timeout 5 \
            --max-redirs 0 -sS -x "$proxy_url" $resolve_args \
            -o /dev/null "https://${domain}/" 2>/dev/null
        rc=$?
        auto_learn_curl_tls_handshake_ok "$rc"
        return $?
    fi

    ip="$(auto_learn_resolve_real_ipv4 "$domain")"
    [ -n "$ip" ] || return 1

    if auto_learn_openssl_tls_probe_ok "$domain" "$ip"; then
        return 0
    fi

    curl -4 -m "$AUTO_LEARN_CURL_TIMEOUT" --connect-timeout 5 \
        --max-redirs 0 -sS --head \
        --resolve "${domain}:443:${ip}" \
        -o /dev/null "https://${domain}/" 2>/dev/null
    rc=$?
    auto_learn_curl_tls_handshake_ok "$rc"
}

auto_learn_probe_tls() {
    auto_learn_tls_probe_ok "$1" ""
}

# Ensure domain is in Zapret exclude, wait for apply, run TLS probe (desync off).
auto_learn_probe_tls_with_zapret_exclude() {
    local domain="$1"
    local added_for_probe

    domain="$(auto_learn_normalize_domain "$domain")"
    added_for_probe=0

    if ! zapret_adapter_is_installed || ! zapret_adapter_has_api; then
        return 1
    fi

    if zapret_adapter_is_excluded "$domain"; then
        auto_learn_probe_tls "$domain"
        return $?
    fi

    zapret_adapter_add_exclude "$domain"
    zapret_adapter_apply_now
    sleep "$AUTO_LEARN_ZAPRET_APPLY_WAIT_SEC"
    added_for_probe=1

    if auto_learn_probe_tls "$domain"; then
        return 0
    fi

    if [ "$added_for_probe" -eq 1 ]; then
        zapret_adapter_remove_exclude "$domain"
        zapret_adapter_apply_now
        sleep "$AUTO_LEARN_ZAPRET_APPLY_WAIT_SEC"
    fi

    return 1
}

# True direct path: Zapret desync off (exclude) when integration is active, else plain WAN TLS.
auto_learn_probe_raw_direct() {
    local domain="$1"

    domain="$(auto_learn_normalize_domain "$domain")"
    if auto_learn_zapret_enabled && zapret_adapter_is_installed && zapret_adapter_has_api; then
        auto_learn_probe_tls_with_zapret_exclude "$domain"
        return $?
    fi
    auto_learn_probe_tls "$domain"
}

# Reachability with Zapret desync active. Only meaningful when the domain is NOT
# in the exclude list — never strip exclude for a probe (manual or auto-learn
# entries must stay; removing them can break working sites).
auto_learn_probe_with_desync() {
    local domain="$1"

    domain="$(auto_learn_normalize_domain "$domain")"

    if auto_learn_zapret_enabled && zapret_adapter_is_installed && zapret_adapter_has_api; then
        if zapret_adapter_is_excluded "$domain"; then
            return 1
        fi
    fi

    auto_learn_probe_tls "$domain"
}

auto_learn_probe_via_service_proxy() {
    local domain="$1"
    local code proxy_url

    domain="$(auto_learn_normalize_domain "$domain")"
    if ! sing_box_process_exists; then
        return 1
    fi

    proxy_url="http://$SB_SERVICE_MIXED_INBOUND_ADDRESS:$SB_SERVICE_MIXED_INBOUND_PORT"
    auto_learn_tls_probe_ok "$domain" "$proxy_url"
}

auto_learn_unroute_domain_if_needed() {
    local domain="$1"
    local section stage

    domain="$(auto_learn_normalize_domain "$domain")"
    stage="$(auto_learn_get_domain_stage "$domain")"
    [ "$stage" = "netshift" ] || return 0
    section="$(auto_learn_get_target_section 2>/dev/null)" || return 0
    [ -n "$section" ] && auto_learn_remove_from_ruleset "$section" "$domain"
}

auto_learn_process_domain() {
    local domain="$1"
    local reason="blocked"

    domain="$(auto_learn_normalize_domain "$domain")"
    if auto_learn_should_skip_candidate "$domain"; then
        auto_learn_unroute_domain_if_needed "$domain"
        auto_learn_remove_domain_from_state "$domain"
        echo "{\"success\":true,\"stage\":\"skipped\",\"domain\":\"$domain\",\"message\":\"excluded suffix or local hostname\"}"
        return 0
    fi

    if ! auto_learn_validate_domain "$domain"; then
        echo '{"success":false,"message":"invalid domain"}'
        return 1
    fi

    if ! auto_learn_is_enabled; then
        echo '{"success":false,"message":"auto-learn disabled"}'
        return 1
    fi

    if auto_learn_domain_covered_by_target_section_lists "$domain"; then
        auto_learn_mark_already_routed_in_section "$domain"
        echo "{\"success\":true,\"stage\":\"already_routed\",\"domain\":\"$domain\",\"message\":\"already in section domain lists\"}"
        return 0
    fi

    # 1) TLS with Zapret desync off (exclude list). Keep exclude when TLS succeeds.
    if auto_learn_probe_raw_direct "$domain"; then
        auto_learn_unroute_domain_if_needed "$domain"
        auto_learn_upsert_domain "$domain" "resolved_direct" "reachable_raw_tls"
        echo "{\"success\":true,\"stage\":\"resolved_direct\",\"domain\":\"$domain\"}"
        return 0
    fi

    # 2) TLS with Zapret desync on — DPI bypass may be enough for some sites.
    if auto_learn_zapret_enabled && zapret_adapter_is_installed && zapret_adapter_has_api; then
        if auto_learn_probe_with_desync "$domain"; then
            auto_learn_unroute_domain_if_needed "$domain"
            auto_learn_upsert_domain "$domain" "resolved_desync" "zapret_desync_tls"
            echo "{\"success\":true,\"stage\":\"resolved_desync\",\"domain\":\"$domain\"}"
            return 0
        fi
    fi

    # 2.5) Desync breaks TLS but exclude restores it (e.g. Let's Encrypt ACME API).
    if auto_learn_zapret_enabled && zapret_adapter_is_installed && zapret_adapter_has_api; then
        if auto_learn_probe_tls_with_zapret_exclude "$domain"; then
            auto_learn_unroute_domain_if_needed "$domain"
            auto_learn_upsert_domain "$domain" "resolved_zapret" "zapret_exclude_tls"
            echo "{\"success\":true,\"stage\":\"resolved_zapret\",\"domain\":\"$domain\"}"
            return 0
        fi
    fi

    # 3) Still blocked — route through NetShift only if VPN TLS path works.
    if ! auto_learn_probe_via_service_proxy "$domain"; then
        auto_learn_upsert_domain "$domain" "failed" "unreachable"
        echo "{\"success\":false,\"stage\":\"failed\",\"domain\":\"$domain\",\"message\":\"unreachable direct and via proxy\"}"
        return 1
    fi

    reason="geo_or_block"
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

    prepare_source_ruleset "$section" "$AUTO_LEARN_RULESET_NAME" "domains" "$route_rule_tag"
    items="$(auto_learn_list_netshift_domains | tr '\n' ',' | sed 's/,$//')"
    [ -n "$items" ] || return 0

    ruleset_filepath="$TMP_RULESET_FOLDER/$(get_ruleset_tag "$section" "$AUTO_LEARN_RULESET_NAME" "domains").json"
    json_array="$(comma_string_to_json_array "$items")"
    patch_source_ruleset_rules "$ruleset_filepath" "domain_suffix" "$json_array"
    log "Configured auto-learned domains for section '$section'" "info"
}

auto_learn_parse_dnsmasq_query_line() {
    local line="$1"
    local domain

    case "$line" in
    *"query[A] "*|*"query[AAAA] "*|*"query[A]"*" from "*|*"query[AAAA]"*" from "*) ;;
    *) return 1 ;;
    esac

    domain="$(echo "$line" | sed -n 's/.*query\[[^]]*\] \([^ ]*\) from.*/\1/p')"
    domain="$(auto_learn_normalize_domain "$domain")"
    auto_learn_validate_domain "$domain" || return 1
    echo "$domain"
}

auto_learn_collect_dns_candidates() {
    local last_ts now line domain candidates

    last_ts="$(cat "$AUTO_LEARN_DNS_LOG_TS_FILE" 2>/dev/null)"
    case "$last_ts" in
        *[!0-9]*) last_ts=0 ;;
    esac
    now="$(date +%s)"
    candidates=""

    logread -t "$last_ts" 2>/dev/null | while IFS= read -r line; do
        case "$line" in
        *dnsmasq*|*DNSMasq*)
            domain="$(auto_learn_parse_dnsmasq_query_line "$line")" || continue
            if auto_learn_domain_ready_for_probe "$domain"; then
                echo "$domain"
            fi
            ;;
        esac
    done | sort -u > "${AUTO_LEARN_DNS_LOG_TS_FILE}.candidates.$$" 2>/dev/null

    if [ -f "${AUTO_LEARN_DNS_LOG_TS_FILE}.candidates.$$" ]; then
        candidates="$(cat "${AUTO_LEARN_DNS_LOG_TS_FILE}.candidates.$$" 2>/dev/null)"
        rm -f "${AUTO_LEARN_DNS_LOG_TS_FILE}.candidates.$$"
    fi

    echo "$now" > "$AUTO_LEARN_DNS_LOG_TS_FILE"
    echo "$candidates"
}

auto_learn_collect_pending_candidates() {
    local now delay domain updated_at

    auto_learn_init_state_file
    now="$(date +%s)"
    delay="$(auto_learn_get_zapret_probe_delay)"

    jq -r --argjson now "$now" --argjson delay "$delay" --argjson cooldown "$AUTO_LEARN_PROBE_COOLDOWN_SEC" \
        '
        .domains[]
        | select(
            (.stage == "zapret_pending" and ($now - .updated_at) >= $delay)
            or (.stage == "failed" and ($now - .updated_at) >= $cooldown)
        )
        | .name
        ' "$AUTO_LEARN_STATE_FILE" 2>/dev/null | sort -u
}

auto_learn_queue_probe_domain() {
    local domain="$1"

    domain="$(auto_learn_normalize_domain "$domain")"
    auto_learn_should_skip_candidate "$domain" && return 0
    auto_learn_domain_ready_for_probe "$domain" || return 0
    log "Auto-learn: probing $domain" "info"
    auto_learn_process_domain "$domain" >/dev/null 2>&1 || true
}

auto_learn_monitor_tick() {
    local candidates pending merged domain count limit

    if ! auto_learn_is_enabled; then
        return 0
    fi

    auto_learn_purge_skipped_domains

    pending="$(auto_learn_collect_pending_candidates)"
    candidates="$(auto_learn_collect_dns_candidates)"
    merged="$(printf '%s\n%s\n' "$pending" "$candidates" | sed '/^$/d' | sort -u)"
    [ -n "$merged" ] || return 0

    count=0
    limit="$AUTO_LEARN_MAX_PROBES_PER_TICK"
    for domain in $merged; do
        auto_learn_queue_probe_domain "$domain"
        count=$((count + 1))
        [ "$count" -ge "$limit" ] && break
    done
}

monitor_auto_learn() {
    echo $$ > "$AUTO_LEARN_MONITOR_PIDFILE"

    while true; do
        config_load "$NETSHIFT_CONFIG"
        if auto_learn_is_enabled; then
            auto_learn_monitor_tick
        fi
        sleep "$AUTO_LEARN_MONITOR_INTERVAL"
    done
}

auto_learn_clear_probe_log() {
    local tmpfile

    auto_learn_init_state_file
    tmpfile="$(mktemp)"
    jq '.domains = [.domains[] | select(.stage == "netshift")]' \
        "$AUTO_LEARN_STATE_FILE" > "$tmpfile" || {
        rm -f "$tmpfile"
        return 1
    }
    mv "$tmpfile" "$AUTO_LEARN_STATE_FILE"
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
    purge-skipped)
        auto_learn_purge_skipped_domains
        echo '{"success":true}'
        ;;
    clear-log)
        auto_learn_clear_probe_log
        echo '{"success":true}'
        ;;
    zapret-status)
        zapret_adapter_status_json
        ;;
    deploy-zapret)
        if zapret_adapter_deploy_script 1; then
            zapret_adapter_status_json
        else
            echo '{"success":false,"message":"failed to deploy Zapret 90-script"}'
            return 1
        fi
        ;;
    *)
        echo '{"success":false,"message":"unknown auto_learn action"}'
        return 1
        ;;
    esac
}
