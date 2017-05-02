# backup_plugin
### A configuration backup plugin for genDevConfig &amp; Cricket

In our network device monitoring system, we use [Cricket](http://cricket.sourceforge.net/) as the collecting tool, and [genDevConfig](http://acktomic.com/gendevconfig/) to generate device profile which is used in Cricket.

For normal workflow, genDevConfig generates device profile once everyday, Cricket collects data every 15 minutes. Also backup collected data once everyday.

Besides that, we also need to backup network configuration. So we decide to develop a plugin in genDevConfig to backup the device configuration when it generates device profile.
