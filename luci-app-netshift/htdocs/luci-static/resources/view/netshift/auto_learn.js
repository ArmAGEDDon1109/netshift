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

function renderDomainTable(domains, onRemove) {
  if (!domains || !domains.length) {
    return E(
      "p",
      { class: "cbi-value-description" },
      _("No auto-detected domains yet."),
    );
  }

  const rows = domains.map(function (entry) {
    const name = entry.name || "";
    const stage = entry.stage || "";
    const reason = entry.reason || "";
    const updated = entry.updated_at
      ? new Date(entry.updated_at * 1000).toLocaleString()
      : "";

    return E("tr", { class: "tr" }, [
      E("td", { class: "td" }, name),
      E("td", { class: "td" }, stage),
      E("td", { class: "td" }, reason),
      E("td", { class: "td" }, updated),
      E(
        "td",
        { class: "td right" },
        E(
          "button",
          {
            class: "cbi-button cbi-button-remove",
            click: function (ev) {
              ev.preventDefault();
              onRemove(name);
            },
          },
          _("Remove"),
        ),
      ),
    ]);
  });

  return E(
    "table",
    { class: "table", style: "width:100%; margin-top:0.5em;" },
    [
      E("tr", { class: "tr table-titles" }, [
        E("th", { class: "th" }, _("Domain")),
        E("th", { class: "th" }, _("Stage")),
        E("th", { class: "th" }, _("Reason")),
        E("th", { class: "th" }, _("Updated")),
        E("th", { class: "th" }, _("Actions")),
      ]),
    ].concat(rows),
  );
}

function refreshDomainPanel(container) {
  if (!container) {
    return Promise.resolve();
  }

  container.innerHTML = "";
  container.appendChild(
    E("p", { class: "cbi-value-description" }, _("Loading…")),
  );

  return fetchAutoLearnJson(["list"])
    .then(function (data) {
      const domains = (data && data.domains) || [];
      container.innerHTML = "";
      container.appendChild(
        renderDomainTable(domains, function (domain) {
          fetchAutoLearnJson(["remove", domain])
            .then(function () {
              ui.addNotification(
                null,
                E("p", {}, _("Removed domain: %s").format(domain)),
              );
              return refreshDomainPanel(container);
            })
            .catch(function (err) {
              ui.addNotification(null, E("p", {}, String(err)));
            });
        }),
      );
    })
    .catch(function (err) {
      container.innerHTML = "";
      container.appendChild(
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
  document
    .querySelectorAll(".ns-auto-learn-domains__table")
    .forEach(function (host) {
      refreshDomainPanel(host);
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

    const tableHost = frame.querySelector(".ns-auto-learn-domains__table");
    const refreshBtn = frame.querySelector('[data-action="refresh-domains"]');
    const clearBtn = frame.querySelector('[data-action="clear-domains"]');

    if (refreshBtn) {
      refreshBtn.addEventListener("click", function (ev) {
        ev.preventDefault();
        refreshDomainPanel(tableHost);
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
            return refreshDomainPanel(tableHost);
          })
          .catch(function (err) {
            ui.addNotification(null, E("p", {}, String(err)));
          });
      });
    }

    refreshDomainPanel(tableHost);
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
      "Detect blocked or geo-blocked sites. Domains are stored outside UCI to avoid restarts on each add.",
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

  o = section.option(form.DummyValue, "_domain_list", _("Detected domains"));
  o.depends("enabled", "1");
  o.rawhtml = true;
  o.cfgvalue = function () {
    scheduleAutoLearnUiInit();
    return (
      '<div class="ns-auto-learn-domains" data-ns-auto-learn="1">' +
      '<div class="ns-auto-learn-domains__toolbar" style="margin-bottom:0.5em;">' +
      '<button type="button" class="cbi-button cbi-button-action" data-action="refresh-domains">' +
      _("Refresh") +
      "</button> " +
      '<button type="button" class="cbi-button cbi-button-remove" data-action="clear-domains">' +
      _("Clear NetShift list") +
      "</button>" +
      "</div>" +
      '<div class="ns-auto-learn-domains__table"></div>' +
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
