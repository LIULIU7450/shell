systemctl stop mgmtd_main foundationdb
rm -rf /var/lib/foundationdb/data/*
rm -f /opt/3fs/etc/.cluster_inited
systemctl start foundationdb
sudo bash 02_setup_meta.sh
