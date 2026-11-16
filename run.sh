直接跑就行，脚本是自包含的单文件。三种用法：
1. 拷到目标机器
# 从本机分发（如果到目标机有 ssh 权限）
for h in 172.16.12.210 172.16.18.64 172.16.18.65 172.16.18.169; do
  scp /home/lzh/max_lab/collect_env_info.sh root@$h:/tmp/
done
2. 在每台机器上执行（推荐 root）
GPU 客户端 dskna004：
sudo bash /tmp/collect_env_info.sh -o /tmp \
  --peers 172.16.12.210,172.16.18.64,172.16.18.65,172.16.18.169
存储节点 dsksa304 / 305 / 348，分两次跑：
第一次（现在就能跑，只读，盘没格式化也没关系）：
sudo bash /tmp/collect_env_info.sh -o /tmp \
  --peers 172.16.12.210,172.16.18.64,172.16.18.65,172.16.18.169
第二次（XFS 格式化并挂载之后，加写探针，才能测出 GET_MAX）：
sudo bash /tmp/collect_env_info.sh -o /tmp --allow-write-probe \
  --peers 172.16.12.210,172.16.18.64,172.16.18.65,172.16.18.169
3. 收回报告
输出文件名：/tmp/<主机名>_envinfo_<时间戳>.txt。跑完会打印：
== 完成! 报告已写入: /tmp/dsksa304_envinfo_20261116_xxxxxx.txt ==
把 4 份 .txt 发回即可。每份最后第 9 节会自动汇总 PASS/WARN，例如：
[PASS] 内核带 FS_IOC_WRITE_STREAM = yes
[PASS] 开启 FDP 的 NVMe 数量 = 3
[WARN] fs.aio-max-nr = 65536 → 存储节点需调大
注意事项
- 默认完全只读，不改任何配置/服务；--allow-write-probe 才会在每个 XFS 挂载点创建 .fdp_probe_tmp（4KB）并立即删除。若某挂载点有生产数据且不允许写入，先不加这个参数。
- 需要 python3（仅第 4 节 ioctl 探针用到；没有也不影响其余收集）。
- 建议 root：nvme fdp status、dmesg 需要权限。
- 跑完注意看第 4 节：如果显示 GET_MAX 成功 ... max_streams=6，说明该盘 XFS 上 LMCache 只能用 3..6；如果显示 ENOTTY，说明当前启动内核不对（应切到 7.0.0-rc2+）。
- 单台大约 1–2 分钟（--peers 的 ping 和防火墙探测会占一点时间）。
