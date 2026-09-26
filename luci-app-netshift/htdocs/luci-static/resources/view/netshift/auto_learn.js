"use strict";
"require form";
"require uci";
"require ui";
"require fs";
"require baseclass";
"require view.netshift.main as main";

const POLL_INTERVAL_MS = 30000;

function fetchAutoLearnJson(args) {
  return fs.exec("/usr/bin/netshift", ["auto_learn"].concat(args || [])).then(
    function (result) {
      const stdout = (result && result.stdout) || "";
      if (!stdout.trim()) {
        return null;
      }
      return JSON.parse(stdout);
    },
  );
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

  o = section.option(form.DummyValue, "_zapret_status", "");
  o.depends("enabled", "1");
  o.depends("zapret_enabled", "1");
  o.render = function () {
    const frame = E("div", { class: "ns-zapret-status" });

    fetchAutoLearnJson(["zapret-status"]).then(function (data) {
      if (!data || !data.installed || !data.api) {
        return;
      }

      frame.appendChild(
        E(
          "span",
          {
            class: "ns-zapret-status__ok",
            style:
              "color: var(--success-color-medium, #28a745); font-size: 1.25em; font-weight: 600;",
            title: _("Zapret integration active"),
          },
          "✔",
        ),
      );
    });

    return frame;
  };

  o = section.option(form.DummyValue, "_domain_list", _("Detected domains"));
  o.rawhtml = true;

  let pollTimer = null;

  function refreshDomainPanel(container) {
    if (!container) {
      return Promise.resolve();
    }

    return fetchAutoLearnJson(["list"]).then(function (data) {
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
    });
  }

  o.render = function () {
    const frame = E("div", { class: "ns-auto-learn-domains" }, [
      E("div", { class: "ns-auto-learn-domains__toolbar" }, [
        E(
          "button",
          {
            class: "cbi-button cbi-button-action",
            click: function (ev) {
              ev.preventDefault();
              const tableHost = frame.querySelector(".ns-auto-learn-domains__table");
              refreshDomainPanel(tableHost);
            },
          },
          _("Refresh"),
        ),
        " ",
        E(
          "button",
          {
            class: "cbi-button cbi-button-remove",
            click: function (ev) {
              ev.preventDefault();
              fetchAutoLearnJson(["clear"])
                .then(function () {
                  ui.addNotification(null, E("p", {}, _("Cleared NetShift auto-learn list")));
                  const tableHost = frame.querySelector(".ns-auto-learn-domains__table");
                  return refreshDomainPanel(tableHost);
                })
                .catch(function (err) {
                  ui.addNotification(null, E("p", {}, String(err)));
                });
            },
          },
          _("Clear NetShift list"),
        ),
      ]),
      E("div", { class: "ns-auto-learn-domains__table" }),
    ]);

    const tableHost = frame.querySelector(".ns-auto-learn-domains__table");
    refreshDomainPanel(tableHost);

    if (pollTimer) {
      clearInterval(pollTimer);
    }
    pollTimer = setInterval(function () {
      refreshDomainPanel(tableHost);
    }, POLL_INTERVAL_MS);

    return frame;
  };

  o = section.option(form.DummyValue, "_manual_probe", _("Manual probe"));
  o.rawhtml = true;
  o.depends("enabled", "1");
  o.render = function () {
    const input = E("input", {
      class: "cbi-input-text",
      placeholder: "example.com",
      style: "width: 20em; margin-right: 0.5em;",
    });
    const button = E(
      "button",
      {
        class: "cbi-button cbi-button-apply",
        click: function (ev) {
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
            })
            .catch(function (err) {
              ui.addNotification(null, E("p", {}, String(err)));
            });
        },
      },
      _("Probe"),
    );

    return E("div", {}, [input, button]);
  };
}

const EntryPoint = {
  createAutoLearnContent,
};

return baseclass.extend(EntryPoint);
