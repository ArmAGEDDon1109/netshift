"use strict";
"require form";
"require uci";
"require ui";
"require fs";
"require baseclass";
"require view.netshift.main as main";

const POLL_INTERVAL_MS = 30000;
let domainListPollTimer = null;

function fetchAutoLearnJson(args) {
  return fs
    .exec("/usr/bin/netshift", ["auto_learn"].concat(args || []))
    .then(function (result) {
      const code = result && result.code;
      const stdout = (result && result.stdout) || "";
      const stderr = (result && result.stderr) || "";

      if (code !== 0) {
        const message = (stderr || stdout || "netshift auto_learn failed").trim();
        return Promise.reject(new Error(message));
      }
      if (!stdout.trim()) {
        return null;
      }
      try {
        return JSON.parse(stdout);
      } catch (err) {
        return Promise.reject(
          new Error(_("Invalid response from netshift auto_learn")),
        );
      }
    });
}

function formatZapretExcludeSource(source) {
  if (source === "netshift_auto") {
    return _("Auto-learn");
  }
  if (source === "manual") {
    return _("Manual / other");
  }
  return source || "";
}

function parseUpdatedAt(value) {
  if (typeof value === "number" && isFinite(value)) {
    return value;
  }
  const n = parseInt(value, 10);
  return isFinite(n) ? n : 0;
}

function sortByUpdatedDesc(entries) {
  return (entries || []).slice().sort(function (a, b) {
    const ta = parseUpdatedAt(a && a.updated_at);
    const tb = parseUpdatedAt(b && b.updated_at);
    if (tb !== ta) {
      return tb - ta;
    }
    return String((a && a.name) || "").localeCompare(String((b && b.name) || ""));
  });
}

function formatUpdatedAt(value) {
  const ts = parseUpdatedAt(value);
  return ts ? new Date(ts * 1000).toLocaleString() : "—";
}

function updatedSortCell(value) {
  const ts = parseUpdatedAt(value);
  return E("span", { "data-value": String(ts) }, formatUpdatedAt(value));
}

function removeButton(name, onRemove) {
  return E(
    "button",
    {
      class: "cbi-button cbi-button-remove",
      click: function (ev) {
        ev.preventDefault();
        if (onRemove) {
          onRemove(name);
        }
      },
    },
    _("Remove"),
  );
}

function renderSortedTable(id, captions, sortable, rows, emptyMessage) {
  const Table = ui.Table || ui.table;
  if (typeof Table !== "function") {
    return E("p", { class: "cbi-value-description" }, emptyMessage);
  }

  const table = new Table(captions, {
    id: id,
    sortable: sortable,
    placeholder: emptyMessage,
  });
  table.sortState = [0, true];
  table.update(rows, emptyMessage);
  const node = table.render();
  node.setAttribute("style", "width:100%; margin-top:0.5em;");
  return node;
}

function renderZapretExcludeTable(entries, options) {
  const opts = options || {};
  const emptyMessage =
    opts.emptyMessage || _("No domains in Zapret exclude list.");
  const sorted = sortByUpdatedDesc(entries);

  if (!sorted.length) {
    return E("p", { class: "cbi-value-description" }, emptyMessage);
  }

  return renderSortedTable(
    "ns-auto-learn-zapret",
    [
      _("Updated"),
      _("Domain"),
      _("Source"),
      _("Stage"),
      _("Reason"),
      _("Actions"),
    ],
    ["numeric", true, true, true, true, false],
    sorted.map(function (entry) {
      const name = entry.name || "";
      return [
        updatedSortCell(entry.updated_at),
        name,
        formatZapretExcludeSource(entry.source),
        entry.stage || "—",
        entry.reason || "—",
        removeButton(name, opts.onRemove),
      ];
    }),
    emptyMessage,
  );
}

function renderDomainTable(domains, options) {
  const opts = options || {};
  const showStage = opts.showStage !== false;
  const emptyMessage =
    opts.emptyMessage || _("No auto-detected domains yet.");
  const sorted = sortByUpdatedDesc(domains);

  if (!sorted.length) {
    return E("p", { class: "cbi-value-description" }, emptyMessage);
  }

  const captions = [_("Updated"), _("Domain")];
  const sortable = ["numeric", true];
  if (showStage) {
    captions.push(_("Stage"));
    sortable.push(true);
  }
  captions.push(_("Reason"), _("Actions"));
  sortable.push(true, false);

  return renderSortedTable(
    showStage ? "ns-auto-learn-log" : "ns-auto-learn-routed",
    captions,
    sortable,
    sorted.map(function (entry) {
      const name = entry.name || "";
      const row = [updatedSortCell(entry.updated_at), name];
      if (showStage) {
        row.push(entry.stage || "");
      }
      row.push(entry.reason || "", removeButton(name, opts.onRemove));
      return row;
    }),
    emptyMessage,
  );
}

function removeDomainAndRefresh(domain, frame) {
  return fetchAutoLearnJson(["remove", domain])
    .then(function () {
      ui.addNotification(
        null,
        E("p", {}, _("Removed domain: %s").format(domain)),
      );
      return refreshAutoLearnFrame(frame);
    })
    .catch(function (err) {
      ui.addNotification(null, E("p", {}, String(err)));
    });
}

function refreshAutoLearnFrame(frame) {
  if (!frame) {
    return Promise.resolve();
  }

  const routedHost = frame.querySelector(".ns-auto-learn-domains__table");
  const logHost = frame.querySelector(".ns-auto-learn-domains__log");
  const logSummary = frame.querySelector(".ns-auto-learn-log__summary");
  const zapretHost = frame.querySelector(".ns-auto-learn-domains__zapret");
  const zapretSummary = frame.querySelector(".ns-auto-learn-zapret__summary");

  if (routedHost) {
    routedHost.innerHTML = "";
    routedHost.appendChild(
      E("p", { class: "cbi-value-description" }, _("Loading…")),
    );
  }
  if (logHost) {
    logHost.innerHTML = "";
    logHost.appendChild(
      E("p", { class: "cbi-value-description" }, _("Loading…")),
    );
  }
  return fetchAutoLearnJson(["list"])
    .then(function (data) {
      const all = sortByUpdatedDesc((data && data.domains) || []);
      const routed = all.filter(function (entry) {
        return entry.stage === "netshift";
      });
      const log = all.filter(function (entry) {
        return entry.stage !== "netshift";
      });

      if (logSummary) {
        logSummary.textContent = _("Detection log (%d)").format(log.length);
      }
      refreshZapretExcludeSummary(frame);

      if (routedHost) {
        routedHost.innerHTML = "";
        routedHost.appendChild(
          renderDomainTable(routed, {
            showStage: false,
            emptyMessage: _("No domains routed through NetShift yet."),
            onRemove: function (domain) {
              removeDomainAndRefresh(domain, frame);
            },
          }),
        );
      }

      if (logHost) {
        logHost.innerHTML = "";
        logHost.appendChild(
          renderDomainTable(log, {
            showStage: true,
            emptyMessage: _("Detection log is empty."),
            onRemove: function (domain) {
              removeDomainAndRefresh(domain, frame);
            },
          }),
        );
      }

      const zapretDetails = frame.querySelector(".ns-auto-learn-zapret");
      if (zapretDetails && zapretDetails.open) {
        loadZapretExcludeTable(frame);
      }
    })
    .catch(function (err) {
      const message = String(err);
      if (routedHost) {
        routedHost.innerHTML = "";
        routedHost.appendChild(
          E(
            "p",
            {
              class: "cbi-value-description",
              style: "color: var(--error-color-medium, #c00);",
            },
            message,
          ),
        );
      }
      if (logHost) {
        logHost.innerHTML = "";
        logHost.appendChild(
          E(
            "p",
            {
              class: "cbi-value-description",
              style: "color: var(--error-color-medium, #c00);",
            },
            message,
          ),
        );
      }
      if (zapretHost) {
        zapretHost.innerHTML = "";
        zapretHost.appendChild(
          E(
            "p",
            {
              class: "cbi-value-description",
              style: "color: var(--error-color-medium, #c00);",
            },
            message,
          ),
        );
      }
    });
}

function refreshZapretExcludeSummary(frame) {
  const zapretSummary = frame.querySelector(".ns-auto-learn-zapret__summary");
  if (!zapretSummary) {
    return Promise.resolve();
  }

  return fetchAutoLearnJson(["zapret-excludes-count"])
    .then(function (counts) {
      const total = counts && counts.total ? counts.total : 0;
      const ns = counts && counts.netshift_auto ? counts.netshift_auto : 0;
      zapretSummary.textContent = _(
        "Zapret exclude (NetShift %d · total %d)",
      ).format(ns, total);
    })
    .catch(function () {
      zapretSummary.textContent = _("Zapret exclude list");
    });
}

function loadZapretExcludeTable(frame) {
  const zapretHost = frame.querySelector(".ns-auto-learn-domains__zapret");
  const filterSel = frame.querySelector('[data-zapret-filter="1"]');
  const filter = (filterSel && filterSel.value) || "netshift_auto";

  if (!zapretHost) {
    return Promise.resolve();
  }

  zapretHost.innerHTML = "";
  zapretHost.appendChild(
    E("p", { class: "cbi-value-description" }, _("Loading…")),
  );

  return fetchAutoLearnJson(["zapret-excludes", filter, "200", "0"])
    .then(function (data) {
      const rows = sortByUpdatedDesc((data && data.excludes) || []);
      zapretHost.innerHTML = "";
      if (data && data.filter === "all" && data.count > data.limit) {
        zapretHost.appendChild(
          E(
            "p",
            { class: "cbi-value-description" },
            _("Showing %d of %d entries.").format(rows.length, data.count),
          ),
        );
      }
      zapretHost.appendChild(
        renderZapretExcludeTable(rows, {
          emptyMessage: _("No domains in this Zapret exclude view."),
          onRemove: function (domain) {
            removeDomainAndRefresh(domain, frame);
          },
        }),
      );
      refreshZapretExcludeSummary(frame);
    })
    .catch(function (err) {
      zapretHost.innerHTML = "";
      zapretHost.appendChild(
        E(
          "p",
          {
            class: "cbi-value-description",
            style: "color: var(--error-color-medium, #c00);",
          },
          String(err),
        ),
      );
    });
}

function refreshAllDomainPanels() {
  document.querySelectorAll("[data-ns-auto-learn]").forEach(function (frame) {
    refreshAutoLearnFrame(frame);
  });
}

function setZapretStatusBadge(badgeEl, state, title) {
  const ok = state === "ok";
  const color = ok
    ? "var(--success-color-medium, #28a745)"
    : "var(--error-color-medium, #c00)";

  badgeEl.textContent = ok ? "✓" : "×";
  badgeEl.title = title || "";
  badgeEl.style.color = color;
  badgeEl.style.borderColor = color;
  badgeEl.style.background = ok
    ? "var(--success-color-low, rgba(40, 167, 69, 0.12))"
    : "var(--error-color-low, rgba(204, 0, 0, 0.08))";
}

function initZapretStatusMounts() {
  document.querySelectorAll("[data-ns-zapret-status]").forEach(function (el) {
    if (el.dataset.nsInit === "1") {
      return;
    }
    el.dataset.nsInit = "1";

    const badgeEl = el.querySelector(".ns-zapret-status__badge");
    if (!badgeEl) {
      return;
    }

    fetchAutoLearnJson(["zapret-status"])
      .then(function (data) {
        if (data && data.installed && data.api) {
          setZapretStatusBadge(badgeEl, "ok", _("Zapret integration active"));
          return;
        }

        if (data && data.installed) {
          setZapretStatusBadge(
            badgeEl,
            "error",
            _("Zapret installed, 90-script API missing"),
          );
        } else {
          setZapretStatusBadge(badgeEl, "error", _("Zapret not detected"));
        }
      })
      .catch(function (err) {
        setZapretStatusBadge(badgeEl, "error", String(err));
      });
  });
}

function initDomainListMounts() {
  document.querySelectorAll("[data-ns-auto-learn]").forEach(function (frame) {
    if (frame.dataset.nsInit === "1") {
      return;
    }
    frame.dataset.nsInit = "1";

    const refreshBtn = frame.querySelector('[data-action="refresh-domains"]');
    const clearBtn = frame.querySelector('[data-action="clear-domains"]');
    const clearLogBtn = frame.querySelector('[data-action="clear-log"]');
    const reprobeUnreachableBtn = frame.querySelector(
      '[data-action="reprobe-unreachable"]',
    );

    if (refreshBtn) {
      refreshBtn.addEventListener("click", function (ev) {
        ev.preventDefault();
        refreshAutoLearnFrame(frame);
      });
    }

    if (clearBtn) {
      clearBtn.addEventListener("click", function (ev) {
        ev.preventDefault();
        fetchAutoLearnJson(["clear"])
          .then(function () {
            ui.addNotification(
              null,
              E("p", {}, _("Cleared NetShift auto-learn list")),
            );
            return refreshAutoLearnFrame(frame);
          })
          .catch(function (err) {
            ui.addNotification(null, E("p", {}, String(err)));
          });
      });
    }

    const zapretDetails = frame.querySelector(".ns-auto-learn-zapret");
    if (zapretDetails) {
      zapretDetails.addEventListener("toggle", function () {
        if (zapretDetails.open) {
          loadZapretExcludeTable(frame);
        }
      });
    }

    const zapretFilter = frame.querySelector('[data-zapret-filter="1"]');
    if (zapretFilter) {
      zapretFilter.addEventListener("change", function () {
        if (zapretDetails && zapretDetails.open) {
          loadZapretExcludeTable(frame);
        }
      });
    }

    if (clearLogBtn) {
      clearLogBtn.addEventListener("click", function (ev) {
        ev.preventDefault();
        fetchAutoLearnJson(["clear-log"])
          .then(function () {
            ui.addNotification(null, E("p", {}, _("Cleared detection log and matching Zapret auto-excludes")));
            return refreshAutoLearnFrame(frame);
          })
          .catch(function (err) {
            ui.addNotification(null, E("p", {}, String(err)));
          });
      });
    }

    if (reprobeUnreachableBtn) {
      reprobeUnreachableBtn.addEventListener("click", function (ev) {
        ev.preventDefault();
        reprobeUnreachableBtn.disabled = true;
        fetchAutoLearnJson(["reprobe-unreachable"])
          .then(function (data) {
            const probed = data && data.probed ? data.probed : 0;
            const netshift = data && data.netshift ? data.netshift : 0;
            const stillFailed =
              data && data.still_failed ? data.still_failed : 0;
            const resolved = data && data.resolved ? data.resolved : 0;
            const summary = _(
              "Re-probed %1 unreachable domain(s): %2 routed via NetShift, %3 resolved without tunnel, %4 still failed.",
            )
              .replace("%1", String(probed))
              .replace("%2", String(netshift))
              .replace("%3", String(resolved))
              .replace("%4", String(stillFailed));
            ui.addNotification(null, E("p", {}, summary));
            return refreshAutoLearnFrame(frame);
          })
          .catch(function (err) {
            ui.addNotification(null, E("p", {}, String(err)));
          })
          .finally(function () {
            reprobeUnreachableBtn.disabled = false;
          });
      });
    }

    refreshAutoLearnFrame(frame);
  });

  if (domainListPollTimer) {
    clearInterval(domainListPollTimer);
  }
  domainListPollTimer = setInterval(refreshAllDomainPanels, POLL_INTERVAL_MS);
}

function initManualProbeMounts() {
  document.querySelectorAll("[data-ns-manual-probe]").forEach(function (frame) {
    if (frame.dataset.nsInit === "1") {
      return;
    }
    frame.dataset.nsInit = "1";

    const input = frame.querySelector("input");
    const button = frame.querySelector('[data-action="probe-domain"]');
    if (!input || !button) {
      return;
    }

    button.addEventListener("click", function (ev) {
      ev.preventDefault();
      const domain = (input.value || "").trim();
      if (!domain) {
        ui.addNotification(null, E("p", {}, _("Enter a domain to probe")));
        return;
      }

      fetchAutoLearnJson(["probe", domain])
        .then(function (result) {
          ui.addNotification(
            null,
            E("pre", {}, JSON.stringify(result, null, 2)),
            "info",
          );
          refreshAllDomainPanels();
        })
        .catch(function (err) {
          ui.addNotification(null, E("p", {}, String(err)));
        });
    });
  });
}

function scheduleAutoLearnUiInit() {
  setTimeout(function () {
    initZapretStatusMounts();
    initDomainListMounts();
    initManualProbeMounts();
  }, 0);
}

function createAutoLearnContent(section) {
  let o = section.option(
    form.Flag,
    "enabled",
    _("Enable auto-detection"),
    _(
      "Automatically probe DNS queries from LAN clients (via dnsmasq logs): raw WAN (Zapret desync off), then Zapret desync, then route through NetShift. *.ru, Yandex (*.yandex.*, ya.ru), and local names (*.lan, *.local, *.home.arpa, unqualified hostnames, etc.) are ignored. Domains are stored outside UCI to avoid restarts on each add.",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "target_section",
    _("Target NetShift section"),
    _("Route auto-learned domains through this proxy/VPN section."),
  );
  o.default = "main";
  o.rmempty = false;
  o.depends("enabled", "1");
  o.load = function () {
    const sections = this.map?.data?.state?.values?.netshift ?? {};
    this.keylist = [];
    this.vallist = [];

    for (const secName in sections) {
      const sec = sections[secName];
      if (
        sec[".type"] === "section" &&
        sec["connection_type"] !== "block" &&
        sec["connection_type"] !== "exclusion"
      ) {
        this.keylist.push(secName);
        this.vallist.push(secName);
      }
    }

    return Promise.resolve();
  };

  o = section.option(
    form.Flag,
    "zapret_enabled",
    _("Integrate with Zapret"),
    _(
      "When enabled and saved, NetShift copies 90-script.sh to /opt/zapret/init.d/openwrt/custom.d/90-script.sh and reloads Zapret. On a failed direct probe, the domain is added to the Zapret exclude list first; if still blocked, it is routed through NetShift.",
    ),
  );
  o.default = "1";
  o.rmempty = false;
  o.depends("enabled", "1");

  o = section.option(form.Value, "zapret_probe_delay", _("Zapret re-probe delay (sec)"));
  o.default = "30";
  o.depends("enabled", "1");
  o.depends("zapret_enabled", "1");

  o = section.option(
    form.Value,
    "monitor_interval",
    _("Monitor interval (sec)"),
    _(
      "How often the background monitor reads DNS logs. 30s or more is easier on CPU and flash for 24/7 use.",
    ),
  );
  o.default = "30";
  o.datatype = "uinteger";
  o.depends("enabled", "1");

  o = section.option(
    form.Value,
    "max_probes_per_tick",
    _("Max TLS probes per tick"),
    _(
      "Cap concurrent domain probes per monitor cycle (1–8). Lower values reduce load when auto-learn runs 24/7.",
    ),
  );
  o.default = "2";
  o.datatype = "uinteger";
  o.depends("enabled", "1");

  o = section.option(
    form.Value,
    "probe_lan_ip",
    _("LAN probe client IP"),
    _(
      "Synthetic LAN client for TLS probes (veth + network namespace on the router). Must be a free address in the LAN subnet, outside the DHCP pool (default 192.168.1.242). Requires kmod-veth.",
    ),
  );
  o.placeholder = "192.168.1.242";
  o.rmempty = true;
  o.depends("enabled", "1");

  o = section.option(
    form.ListValue,
    "probe_dns_mode",
    _("Probe DNS source"),
    _(
      "DNS used by the synthetic LAN client for TLS probes. DHCP (default) requests DNS from dnsmasq like a real PC. Reserve probe_lan_ip in DHCP or use a static lease so dnsmasq answers the veth client.",
    ),
  );
  o.value("dhcp", _("DHCP (from LAN dnsmasq)"));
  o.value("gateway", _("Router LAN IP (gateway)"));
  o.value("custom", _("Custom servers"));
  o.default = "dhcp";
  o.depends("enabled", "1");

  o = section.option(
    form.Value,
    "probe_dns_servers",
    _("Custom probe DNS servers"),
    _("Space-separated IPv4 addresses when Probe DNS source is Custom."),
  );
  o.placeholder = "1.1.1.1 8.8.8.8";
  o.rmempty = true;
  o.depends("enabled", "1");
  o.depends("probe_dns_mode", "custom");

  o = section.option(form.Value, "max_domains", _("Max auto-learned domains"));
  o.default = "500";
  o.depends("enabled", "1");

  o = section.option(form.DummyValue, "_zapret_status", _("Zapret") + ":");
  o.depends("enabled", "1");
  o.depends("zapret_enabled", "1");
  o.rawhtml = true;
  o.cfgvalue = function () {
    scheduleAutoLearnUiInit();
    return (
      '<span class="ns-zapret-status" data-ns-zapret-status="1">' +
      '<span class="ns-zapret-status__badge" ' +
      'style="display:inline-flex;align-items:center;justify-content:center;' +
      "width:1.1em;height:1.1em;min-width:1.1em;min-height:1.1em;" +
      "border:1.5px solid var(--border-color-medium,#bbb);border-radius:2px;" +
      "font-size:0.78em;font-weight:700;line-height:1;box-sizing:border-box;" +
      'vertical-align:middle;">…</span></span>'
    );
  };

  o = section.option(
    form.DummyValue,
    "_domain_list",
    _("Routed through NetShift"),
  );
  o.depends("enabled", "1");
  o.rawhtml = true;
  o.cfgvalue = function () {
    scheduleAutoLearnUiInit();
    return (
      '<div class="ns-auto-learn-domains" data-ns-auto-learn="1">' +
      '<p class="cbi-value-description" style="margin-top:0;">' +
      _("Domains below are actively routed through the VPN tunnel.") +
      ' <span style="opacity:0.55;font-size:0.9em;">(UI v2)</span></p>' +
      '<div class="ns-auto-learn-domains__toolbar" style="margin-bottom:0.5em;">' +
      '<button type="button" class="cbi-button cbi-button-action" data-action="refresh-domains">' +
      _("Refresh") +
      "</button> " +
      '<button type="button" class="cbi-button cbi-button-remove" data-action="clear-domains">' +
      _("Clear NetShift list") +
      "</button>" +
      "</div>" +
      '<div class="ns-auto-learn-domains__table"></div>' +
      '<details class="ns-auto-learn-log" style="margin-top:1em;">' +
      '<summary class="ns-auto-learn-log__summary" style="cursor:pointer;font-weight:600;">' +
      _("Detection log (0)") +
      "</summary>" +
      '<p class="cbi-value-description">' +
      _("Probe history: direct access, Zapret, failed checks. These domains are not routed through NetShift. Remove or Clear log also drops NetShift-added Zapret excludes.") +
      "</p>" +
      '<div style="margin-bottom:0.5em;">' +
      '<button type="button" class="cbi-button cbi-button-remove" data-action="clear-log">' +
      _("Clear log") +
      "</button> " +
      '<button type="button" class="cbi-button cbi-button-apply" data-action="reprobe-unreachable">' +
      _("Re-probe unreachable") +
      "</button>" +
      "</div>" +
      '<div class="ns-auto-learn-domains__log"></div>' +
      "</details>" +
      '<details class="ns-auto-learn-zapret" style="margin-top:1em;">' +
      '<summary class="ns-auto-learn-zapret__summary" style="cursor:pointer;font-weight:600;">' +
      _("Zapret exclude (NetShift 0 · total 0)") +
      "</summary>" +
      '<p class="cbi-value-description">' +
      _(
        "Hostnames in zapret-hosts-user-exclude.txt (desync off). Default view: entries added by NetShift auto-learn only (fast). Full list can be large.",
      ) +
      "</p>" +
      '<label style="margin-right:0.5em;">' +
      _("Show") +
      ': <select data-zapret-filter="1" class="cbi-input-select">' +
      '<option value="netshift_auto">' +
      _("NetShift auto-learn only") +
      "</option>" +
      '<option value="manual">' +
      _("Manual / other (first 200)") +
      "</option>" +
      '<option value="all">' +
      _("All (first 200)") +
      "</option>" +
      "</select></label>" +
      '<div class="ns-auto-learn-domains__zapret"></div>' +
      "</details>" +
      "</div>"
    );
  };

  o = section.option(form.DummyValue, "_manual_probe", _("Manual probe"));
  o.depends("enabled", "1");
  o.rawhtml = true;
  o.cfgvalue = function () {
    scheduleAutoLearnUiInit();
    return (
      '<div class="ns-manual-probe" data-ns-manual-probe="1">' +
      '<input class="cbi-input-text" type="text" placeholder="example.com" style="width:20em;margin-right:0.5em;" />' +
      '<button type="button" class="cbi-button cbi-button-apply" data-action="probe-domain">' +
      _("Probe") +
      "</button>" +
      "</div>"
    );
  };
}

const EntryPoint = {
  createAutoLearnContent,
};

return baseclass.extend(EntryPoint);
