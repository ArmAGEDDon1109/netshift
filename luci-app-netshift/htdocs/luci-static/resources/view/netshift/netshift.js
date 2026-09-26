"use strict";
"require view";
"require form";
"require baseclass";
"require network";
"require uci";
"require fs";
"require ui";
"require view.netshift.main as main";

// Settings content
"require view.netshift.settings as settings";

// Sections content
"require view.netshift.section as section";

// Dashboard content
"require view.netshift.dashboard as dashboard";

// Diagnostic content
"require view.netshift.diagnostic as diagnostic";

// Auto-detection content
"require view.netshift.auto_learn as auto_learn";

// Component Manager content
"require view.netshift.manager as manager";

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();

    const netshiftMap = new form.Map(
      "netshift",
      _("NetShift Extended Settings"),
      _("Configuration for NetShift Extended service"),
    );
    // Enable tab views
    netshiftMap.tabbed = true;

    // Dashboard tab (first / landing tab)
    const dashboardSection = netshiftMap.section(
      form.TypedSection,
      "dashboard",
      _("Dashboard"),
    );
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    dashboardSection.cfgsections = function () {
      return ["dashboard"];
    };

    // Render dashboard content
    dashboard.createDashboardContent(dashboardSection);

    // Sections tab
    const sectionsSection = netshiftMap.section(
      form.TypedSection,
      "section",
      _("Sections"),
    );
    sectionsSection.anonymous = false;
    sectionsSection.addremove = true;
    sectionsSection.template = "cbi/simpleform";

    // Render section content
    section.createSectionContent(sectionsSection);

    // Auto-detection tab
    const autoLearnSection = netshiftMap.section(
      form.TypedSection,
      "auto_learn",
      _("Auto-detection"),
    );
    autoLearnSection.anonymous = true;
    autoLearnSection.addremove = false;
    autoLearnSection.cfgsections = function () {
      return ["auto_learn"];
    };
    auto_learn.createAutoLearnContent(autoLearnSection);

    // Settings tab
    const settingsSection = netshiftMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    // Make it named [ config settings 'settings' ]
    settingsSection.cfgsections = function () {
      return ["settings"];
    };

    // Render settings content
    settings.createSettingsContent(settingsSection);

    // Component Manager tab
    const managerSection = netshiftMap.section(
      form.TypedSection,
      "manager",
      _("Component Manager"),
    );
    managerSection.anonymous = true;
    managerSection.addremove = false;
    managerSection.cfgsections = function () {
      return ["manager"];
    };

    // Render Component Manager content
    manager.createManagerContent(managerSection);

    // Diagnostic tab
    const diagnosticSection = netshiftMap.section(
      form.TypedSection,
      "diagnostic",
      _("Diagnostics"),
    );
    diagnosticSection.anonymous = true;
    diagnosticSection.addremove = false;
    diagnosticSection.cfgsections = function () {
      return ["diagnostic"];
    };

    // Render diagnostic content
    diagnostic.createDiagnosticContent(diagnosticSection);

    // Inject core service
    main.coreService();

    const origSave = netshiftMap.save.bind(netshiftMap);
    netshiftMap.save = function () {
      return origSave().then(function () {
        const autoEnabled = uci.get("netshift", "auto_learn", "enabled");
        const zapretEnabled = uci.get("netshift", "auto_learn", "zapret_enabled");
        if (autoEnabled !== "1" || zapretEnabled !== "1") {
          return Promise.resolve();
        }

        return fs
          .exec("/usr/bin/netshift", ["auto_learn", "deploy-zapret"])
          .then(function (result) {
            if (result && result.code !== 0) {
              const detail = (result.stderr || result.stdout || "").trim();
              ui.addNotification(
                null,
                E(
                  "p",
                  {},
                  _("Zapret deploy failed") + (detail ? ": " + detail : ""),
                ),
              );
              return;
            }
            ui.addNotification(
              null,
              E(
                "p",
                {},
                _(
                  "Zapret 90-script deployed to /opt/zapret/init.d/openwrt/custom.d/ and Zapret was reloaded.",
                ),
              ),
              "info",
            );
          });
      });
    };

    return netshiftMap.render();
  },
};

return view.extend(EntryPoint);
