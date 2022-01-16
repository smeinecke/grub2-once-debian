#
# Regular cron jobs for the grub2-once package
#
0 4	* * *	root	[ -x /usr/bin/grub2-once_maintenance ] && /usr/bin/grub2-once_maintenance
