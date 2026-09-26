#!/bin/sh
# Remove corrupted auto_learn tail from netshift config
awk 'BEGIN{bad=0} /^\\  config auto_learn/{bad=1} bad==0{print}' /etc/config/netshift > /tmp/netshift.cfg.$$
mv /tmp/netshift.cfg.$$ /etc/config/netshift
cat >> /etc/config/netshift << 'EOF'

config auto_learn 'auto_learn'
	option enabled '0'
	option target_section 'main'
	option zapret_enabled '1'
EOF
uci show netshift | tail -6
