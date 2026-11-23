3. Deploy 3FS
3.1 Install ClickHouse on meta node
3.1.1 Install 
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

ARCH=$(dpkg --print-architecture)
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main" | sudo tee /etc/apt/sources.list.d/clickhouse.list
sudo apt-get update

sudo apt-get install -y clickhouse-server clickhouse-client
# password is need during the installation, we use `user`

For detail please refer to https://clickhouse.com/docs/install

3.1.2 Start
sudo clickhouse start 
3.1.3 Login

    Use the password which has been set during installation

root@3fs-meta:~# clickhouse-client --password 'user'
ClickHouse client version 25.2.1.3085 (official build).
Connecting to localhost:9000 as user default.
Connected to ClickHouse server version 25.2.1.

Warnings:
 * Delay accounting is not enabled, OSIOWaitMicroseconds will not be gathered. You can enable it using `echo 1 > /proc/sys/kernel/task_delayacct` or by using sysctl.

3fs-meta :)
3.1.4 Create Metric table

  The metric info of 3FS nodes will be record in this table. 

clickhouse-client --password 'user' -n  < ~/3fs/deploy/sql/3fs-monitor.sql
3.2 Install FoundationDB on meta node
3.2.1 Install 

Please refer to chapter 1.4 for install FoundationDB.   

The default configuration file is  /etc/foundationdb/foundationdb.conf which is shown as follow. The main parameters are cluster-file, datadir and logdir.



[general]
restart-delay = 60
## by default, restart-backoff = restart-delay-reset-interval = restart-delay
# initial-restart-delay = 0
# restart-backoff = 60
# restart-delay-reset-interval = 60
cluster-file = /etc/foundationdb/fdb.cluster

[fdbserver]
command = /usr/sbin/fdbserver
public-address = auto:$ID
listen-address = public
datadir = /var/lib/foundationdb/data/$ID
logdir = /var/log/foundationdb
3.2.2 Start 
systemctl start  foundationdb

Login with fdbcli tool and create database

Using cluster file `/etc/foundationdb/fdb.cluster'.

Welcome to the fdbcli. For help, type `help'.
fdb> writemode on ;
>>> writemode on
fdb> configure new single ssd
Database created

check status of foundationDB

fdb> status details

Using cluster file `/etc/foundationdb/fdb.cluster'.

Configuration:
  Redundancy mode        - single
  Storage engine         - memory-2
  Coordinators           - 1
  Usable Regions         - 1

Cluster:
  FoundationDB processes - 1
  Zones                  - 1
  Machines               - 1
  Memory availability    - 8.0 GB per process on machine with least available
  Retransmissions rate   - 2 Hz
  Fault Tolerance        - 0 machines
  Server time            - 03/25/25 10:52:17

Data:
  Replication health     - Healthy
  Moving data            - 0.000 GB
  Sum of key-value sizes - 13 MB
  Disk space used        - 203 MB

Operating space:
  Storage server         - 0.9 GB free on most full server
  Log server             - 0.5 GB free on most full server

Workload:
  Read rate              - 16 Hz
  Write rate             - 0 Hz
  Transactions started   - 4 Hz
  Transactions committed - 0 Hz
  Conflict rate          - 0 Hz

Backup and DR:
  Running backups        - 0
  Running DRs            - 0

Process performance details:
  127.0.0.1:4500         (  1% cpu;  0% machine; 0.000 Gbps;  1% disk IO; 0.4 GB / 8.0 GB RAM  )

Coordination servers:
  127.0.0.1:4500  (reachable)

Client time: 03/25/25 10:52:17
3.3 Start 3FS services

The main steps can be summarized as following:

Install monitor_collector in meta node.
Install admin_cli on all nodes.
Install mgmtd service on meta node.
Install meta service on meta node
Install storage service on storage nodes

Create admin user, storage targets and chain table

Install fuse client on the nodes which host AI training applications

For detail, please refer to official guide:  https://github.com/deepseek-ai/3FS/blob/main/deploy/README.md#step-2-monitor-service

We can check the mount info of 3FS after we finish installing fuse client:

root@3fs-client:/opt/3fs# mount | grep '/3fs/stage'
hf3fs.stage on /3fs/stage type fuse.hf3fs (rw,nosuid,nodev,relatime,user_id=0,group_id=0,default_permissions,allow_other,max_read=1048576)

root@3fs-meta:/opt/3fs# df -kh
Filesystem      Size  Used Avail Use% Mounted on
tmpfs           100G  1.9M  100G   1% /run
/dev/nvme0n1p3  394G   28G  350G   8% /
tmpfs           496G   16K  496G   1% /dev/shm
tmpfs           5.0M     0  5.0M   0% /run/lock
/dev/nvme0n1p2  197M  6.1M  191M   4% /boot/efi
tmpfs           100G  4.0K  100G   1% /run/user/0
hf3fs.stage     140T  999G  139T   1% /3fs/stage
4. FAQ
4.1 How to troubleshoot common deployment issues?

When encountering any error during deployment,

Check the log messages in stdout/stderr , especially during service startup.
Check log files stored in /var/log/3fs/ on service and client nodes.
Ensure that the directory /var/log/3fs/ exists before starting any service.
Check whether it is a existing issue on 3FS official site or not?  https://github.com/deepseek-ai/3FS/issues
4.2 How to process the build failed with io_uring?

https://github.com/deepseek-ai/3FS/issues/29

dpkg -S /usr/include/liburing.h
apt remove liburing-dev
then remove build directory and cmake again.
4.3 How to process Mgmtd::NotPrimary(5000) error?   

     https://github.com/deepseek-ai/3FS/issues/135

Mgmtd will extend the lease periodically (encapsulated as a FoundationDB transaction). In two cases it will become secondary without any other mgmtd instance:
fails to commit FoundationDB transaction, or
clock rolls back to a past time.
Please check the status of your FoundationDB and chrony, and if both are OK, delete the key "SINGMgmtdLease" in FoundationDB via FDB CLI.

For chrony, please refer to https://chrony-project.org/examples.html

4.4 If there are multiple NICs in the server, how to assign NICs which 3FS services can use?

  It is highly recommended to specify the RDMA NIC in the configuration files that can be used by 3FS. 

 Otherwise, 3FS will regard all active NICs are available and 3FS components will try to communicate with each other through all NICs.

We can modify the filter_list parameter in monitor_collector_main.toml, meta_main.toml, mgmtd_main.toml and storage_main.toml.

filter_list = ["ens4f1np1"]

For admin_cli, we can modify the device_filter parameter in admin_cli.toml



device_filter = ["ens4f1np1","enp202s0f0np0"]








