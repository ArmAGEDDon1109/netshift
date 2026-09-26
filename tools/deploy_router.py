#!/usr/bin/env python3
import base64
import subprocess
import sys

FILES = [
    (r"netshift\files\usr\bin\netshift", "/usr/bin/netshift"),
    (r"netshift\files\usr\lib\constants.sh", "/usr/lib/netshift/constants.sh"),
    (r"netshift\files\usr\lib\helpers.sh", "/usr/lib/netshift/helpers.sh"),
    (r"netshift\files\usr\lib\helpers.jq", "/usr/lib/netshift/helpers.jq"),
    (r"netshift\files\usr\lib\logging.sh", "/usr/lib/netshift/logging.sh"),
    (r"netshift\files\usr\lib\nft.sh", "/usr/lib/netshift/nft.sh"),
    (r"netshift\files\usr\lib\rulesets.sh", "/usr/lib/netshift/rulesets.sh"),
    (r"netshift\files\usr\lib\sing_box_config_facade.sh", "/usr/lib/netshift/sing_box_config_facade.sh"),
    (r"netshift\files\usr\lib\sing_box_config_manager.sh", "/usr/lib/netshift/sing_box_config_manager.sh"),
    (r"netshift\files\usr\lib\updater.sh", "/usr/lib/netshift/updater.sh"),
    (r"netshift\files\usr\lib\zapret_adapter.sh", "/usr/lib/netshift/zapret_adapter.sh"),
    (r"netshift\files\usr\lib\auto_learn.sh", "/usr/lib/netshift/auto_learn.sh"),
    (r"netshift\files\usr\lib\zapret\90-script.sh", "/opt/zapret/init.d/openwrt/custom.d/90-script.sh"),
]

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."

for rel, remote in FILES:
    path = f"{ROOT}/{rel}".replace("\\", "/")
    data = open(path, "rb").read()
    b64 = base64.b64encode(data)
    subprocess.run(
        ["ssh", "root@192.168.1.1", f"base64 -d > {remote}"],
        input=b64,
        check=True,
    )
    print(f"deployed {remote} ({len(data)} bytes)")

subprocess.run(
    [
        "ssh",
        "root@192.168.1.1",
        "chmod +x /usr/bin/netshift /opt/zapret/init.d/openwrt/custom.d/90-script.sh",
    ],
    check=True,
)
subprocess.run(["ssh", "root@192.168.1.1", "netshift auto_learn status"], check=False)
