# Intel J1900 小型 NAS 安装 Ubuntu Server 26.04.1：UEFI GRUB 写入失败与修复（阶段性记录）

> **记录日期：** 2026-11-23  
> **阶段状态：** 基础系统已从内部 SSD 正常启动，`nasadmin` 本地登录成功；**网络、SSH 和 NAS 应用部署尚未完成**。  
> **关键结论：** 首次安装失败的直接原因是 GRUB 向主板 UEFI NVRAM 注册启动项时发生 `Input/output error`。通过 chroot 在 SSD 上执行 `grub-install --no-nvram --removable`，成功创建 EFI 回退启动文件，并已通过实际重启验证。  
> **适用边界：** 本文基于这台设备的现场截图、安装日志和实测反馈整理；不是所有 J1900 主板的通用 BIOS 设置。文中区分**已执行/已验证**与**待办/建议**。文中不包含账户密码。

## 1. 目的与环境

计划把一台老款 Intel NAS 小主机改造为 Ubuntu Server 服务器，后续在路由器就绪后配置 SSH、文件共享和容器环境；安装时希望清除原 SSD 上的旧系统。

| 项目 | 本次信息 |
| --- | --- |
| CPU | Intel Celeron J1900（64 位 x86 架构） |
| BIOS | AMI Aptio Setup Utility（界面标注 2017），`UEFI Boot = Enabled` |
| 系统镜像 | `ubuntu-26.04.1-live-server-amd64.iso` |
| 安装工具 | Windows 端 Rufus，制作可启动 U 盘 |
| 安装 U 盘 | aigo U330，安装环境中约 58.59 GiB，标记 `UBUNTU-SERV` |
| 目标系统盘 | BIWIN SSD，安装向导识别容量 29.50 GB（约 32 GB 级别） |
| 网络接口 | `enp1s0`：Realtek 千兆网卡；安装时另识别 `usb0`：小米手机 RNDIS USB 共享 |
| 最终本地账户 | `nasadmin`（现场手动创建） |
| 网络现状 | 本次未完成联网，最终决定等待安装路由器后配置 |

**未确认信息：** Rufus 最终采用的具体分区方案（MBR/GPT）、整机内存容量、主板精确型号均没有现场验证记录；不凭 CPU 型号推断这些配置。

## 2. 安装流程与正常步骤

### 2.1 U 盘启动与 BIOS

最初 BIOS 中仅有旧系统相关入口，例如 `ubuntu (P0: BIWIN SSD)`、`UEFI OS (P0: BIWIN SSD)`，没有看到 U 盘入口。插入制作好的爱国者 U330 后，BIOS 出现：

- `UEFI: aigo U330 PMAP`：U 盘的 UEFI 启动入口；
- `aigo U330 PMAP`：传统启动入口；
- `P0: BIWIN SSD` 等：内部 SSD。

**已执行并验证：** 把 `UEFI: aigo U330 PMAP` 设为优先启动项并保存，随后成功进入 Ubuntu Server 安装器的语言选择界面。无需重新制作 U 盘。

### 2.2 安装类型与网络

安装器选择标准 `Ubuntu Server`，未选择 `Ubuntu Server (minimized)`，第三方驱动搜索未启用。

网络配置页实际识别：

```text
enp1s0   Realtek ... Gigabit Ethernet   not connected / autoconfiguration failed
usb0     Xiaomi Mi/Redmi (RNDIS)        DHCPv4（没有成功获得 IP）
```

USB 共享网卡能被识别，**不代表 DHCP 已成功或外网可用**。尝试使用手机 USB 网络共享时未获得 IP，因此继续离线安装；`Proxy address` 留空，软件源没有通过可用网络完成在线操作。

> 这次的联网问题与后续确定的 GRUB 错误是两个独立事项。日志中的 GRUB 直接错误是 UEFI 变量写入失败，不能再笼统归因为“没有网络”。

### 2.3 整盘安装与分区方案

用户明确要清空旧系统，因此在 `Guided storage configuration` 中选择 `Use an entire disk`，目标为 **BIWIN SSD（29.50 GB）**；取消 `Set up this disk as an LVM group`，未启用 LUKS。

分区预览显示：

| 目标设备 | 分区 | 大小 | 文件系统 | 挂载点 | 本次动作 |
| --- | --- | --- | --- | --- | --- |
| BIWIN SSD | Partition 1 | 1.049 GB | FAT32（ESP） | `/boot/efi` | 新建、格式化 |
| BIWIN SSD | Partition 2 | 28.448 GB | ext4 | `/` | 新建、格式化 |
| aigo U330 | Partition 1 | 约 58.59 GiB | FAT32 | 安装介质 | **未选择格式化** |

确认 `Confirm destructive action → Continue` 后，安装器执行了 SSD 分区、格式化、系统镜像解压等步骤。

**重要：** 整盘重装会丢失 SSD 上原有文件，但不等同于对 SSD 进行安全擦除。执行前必须辨认磁盘，不能仅凭 `/dev/sda` 这个名字照抄到其他机器。

## 3. 故障现象与定位

### 3.1 表现

安装器在 `Installing system` 阶段后期弹出：

```text
Sorry, there was a problem completing the installation.
```

安装日志停在配置启动引导附近：

```text
installing target system boot loader
installing grub to target devices
```

### 3.2 进入安装环境终端并找日志

从安装失败界面按 `Ctrl + Alt + F2`，进入安装 U 盘的临时系统终端（提示符类似 `ubuntu-server@ubuntu-server:~$`）。

```bash
ls /var/log/installer/
sudo tail -n 40 /var/log/installer/curtin-install.log
```

当时存在 `curtin-install.log`、`subiquity-server-debug.log`、`subiquity-traceback.txt` 等文件。**注意：** `ls` 的首字母是小写字母 L，不是数字 1；当时曾因输成 `1s` 出现 `command not found`，并非系统故障。

其他可选筛查命令（用于复查，并非每条都已实际执行）：

```bash
sudo grep -inE 'error|failed|grub|efibootmgr' /var/log/installer/curtin-install.log | tail -n 30
sudo tail -n 40 /var/log/installer/subiquity-traceback.txt
```

### 3.3 日志中的决定性错误

```text
Installing grub to /boot/efi.
Installing for x86_64-efi platform.
grub-install: warning: Cannot set EFI variable Boot0015.
grub-install: warning: efivarfs_set_variable: writing to fd 9 failed: Input/output error.
grub-install: error: failed to register the EFI boot entry: Input/output error.
Exit code: 1
```

解释：

1. 安装程序已进入 x86_64 UEFI GRUB 引导安装阶段；
2. GRUB 尝试将启动项注册到主板 UEFI NVRAM（`Boot0015`）；
3. 固件变量写入返回 `Input/output error`，导致该命令以非零状态退出；
4. **能确定的是“EFI 启动项注册失败”**；主板固件实现、NVRAM 容量或其他底层因素哪个才是根本硬件原因，本次没有进一步证实。

同一段日志里出现了 Perl locale 警告（如 `Setting locale failed`），但它不是本次已确认的导致安装中断的直接错误。

## 4. 现场修复：不写 NVRAM，使用 EFI 回退路径

> **本节是本次实际执行并成功的流程。** 操作位置是从安装 U 盘启动的临时 Ubuntu，**不是**新系统已经正常启动后的终端。以下设备名、挂载目录仅对应本次现场状态；迁移到其他设备之前必须重新核实。

### 4.1 核实目标 SSD 和挂载点

```bash
lsblk -f
findmnt /target
findmnt /target/boot/efi
```

实际验证结果：

```text
/dev/sda1  vfat  FAT32  → /target/boot/efi  （BIWIN EFI 分区）
/dev/sda2  ext4         → /target           （BIWIN 根分区）
/dev/sdb1  vfat  FAT32  → 安装 U 盘（UBUNTU-SERV）
```

若 `/target`、`/target/boot/efi` 不是目标系统的正确分区，**必须停止**，不能直接执行后续 GRUB 命令。

### 4.2 `curtin` 不在当前 Shell 的 PATH：改为 chroot

曾尝试：

```bash
sudo curtin in-target --target=/target -- grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --removable
```

实际返回：

```text
sudo: 'curtin': command not found
```

这说明当前终端无法直接调用 `curtin`，**不是 GRUB 再次安装失败**。

先确认目标系统中 GRUB 程序存在：

```bash
ls -l /target/usr/sbin/grub-install
```

本次检查显示文件存在。

然后准备 chroot 需要的设备与虚拟文件系统（逐行执行）：

```bash
sudo mount --rbind /dev /target/dev
sudo mount --make-rslave /target/dev
sudo mount -t proc proc /target/proc
sudo mount --rbind /sys /target/sys
sudo mount --make-rslave /target/sys
sudo mount --rbind /run /target/run
sudo mount --make-rslave /target/run
```

本次过程中一度因输错命令出现 `mount: /target/sys: can't find in /etc/fstab`，修正后验证：

```bash
findmnt /target/sys
findmnt /target/run
```

两者均有挂载信息。

### 4.3 真正有效的修复命令

```bash
sudo chroot /target /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram --removable
```

参数含义：

- `--target=x86_64-efi`：安装 64 位 UEFI 版本的 GRUB；
- `--efi-directory=/boot/efi`：目标系统中 EFI 分区的挂载点；
- `--no-nvram`：**不尝试写入主板 UEFI 启动变量**，绕开此次报错环节；
- `--removable`：使用标准 UEFI 回退启动路径 `EFI/BOOT/BOOTX64.EFI`（虽然选项名为 removable，也可以用于这里的 SSD 分区）。

**现场返回：**

```text
Installing for x86_64-efi platform.
Installation finished. No error reported.
```

继续执行：

```bash
sudo chroot /target update-grub
sudo ls -l /target/boot/efi/EFI/BOOT/BOOTX64.EFI
```

实际观察到：

```text
Found linux image: /boot/vmlinuz-7.0.0-30-generic
Found initrd image: /boot/initrd.img-7.0.0-30-generic
done
/target/boot/efi/EFI/BOOT/BOOTX64.EFI  （文件存在）
```

`update-grub` 的 `os-prober will not be executed` 提示并非本次修复失败。

**修复局限：** 只是绕开 NVRAM 启动项写入，**没有修好主板固件写 NVRAM 的能力**；以后更换 SSD、重装或调整 GRUB/UEFI 入口时仍应留意这一点。主板是否会从回退路径自动启动，需要通过实际重启测试。

## 5. 安装中断后的账户补救与重启验证

原安装流程在 GRUB 阶段异常退出，尚未完成所有后续步骤。现场检查发现：

```bash
sudo ls /target/home
sudo chroot /target dpkg -s openssh-server | grep Status
sudo chroot /target getent passwd 1000
sudo find /target/var/lib/cloud/seed -maxdepth 3 -type f -name user-data -print 2>/dev/null
```

**观察：**

- `/target/home` 当时为空（初次还误把路径输入为 `/target/hone`）；
- `openssh-server` 返回 `is not installed`；
- 未观察到 UID 1000 用户；所检查的位置未找到 cloud-init `user-data`。

于是**手动执行**：

```bash
sudo chroot /target useradd -m -s /bin/bash -G sudo nasadmin
sudo chroot /target passwd nasadmin
```

现场返回：

```text
passwd: password updated successfully
```

密码仅在设备本地设置，**未存入仓库**。

随后建议并执行正常重启流程（相关对话给出的命令）：

```bash
sudo sync
sudo reboot
```

拔出安装 U 盘后，**实际拍照确认**内部 SSD 能启动到：

```text
Ubuntu 26.04.1 LTS localhost.localdomain tty1
localhost login:
```

以 `nasadmin` 登录成功；执行 `id` 显示：

```text
uid=1000(nasadmin) gid=1000(nasadmin) groups=1000(nasadmin),27(sudo)
```

并已通过 `cat /etc/os-release` 验证为 Ubuntu 26.04.1 LTS（Resolve Raccoon）。这证明**基础系统已从 SSD 启动、账户可登录、sudo 组存在**，但不等于所有安装器后续任务都已完成。

## 6. 本阶段网络检查与最终决定

首次成功登录后的现场命令：

```bash
ip -br addr
ls /etc/netplan
```

实际结果要点：

```text
lo       UNKNOWN  127.0.0.1/8 ::1/128
enp1s0   DOWN     （无 IPv4 地址）
/etc/netplan/00-installer-config.yaml
```

后续曾讨论 Windows 与 NAS **网线直连的备选示例地址**：

| 设备 | 建议地址（未实施） |
| --- | --- |
| Windows 有线网卡 | `192.168.50.1/24` |
| NAS `enp1s0` | `192.168.50.2/24` |

**注意：** 该静态 IP 方案**并未实际写入 Netplan，也未做 Ping 或 SSH 验证**。用户最后决定先不配置网络，等路由器安装好后再处理；后续联网优先确认路由器 DHCP，再根据实际网络考虑 DHCP 保留或静态 IP，不要机械套用上述示例网段。

已提供安全关机命令：

```bash
sudo poweroff
# 或 sudo shutdown -h now
```

对话没有获得最终关机命令执行输出，因此只记录为**已提供操作方法**，不宣称已验证关机过程。

## 7. 下次继续配置：待办清单（均未完成）

- [ ] **路由器接入与链路：** NAS 用网线连接路由器，查看 `ip -br addr`、`ip route`；检查 `/etc/netplan/00-installer-config.yaml`，先确认 DHCP 正常获取 IP 与网关。
- [ ] **网络连通性：** 测试网关连通、DNS 和外网访问；不要把“网卡 UP”单独视为已联网。
- [ ] **修复可能中断的软件包配置：** 根据实际检查结果决定是否执行 `sudo dpkg --audit`、`sudo dpkg --configure -a`、`sudo apt update`、`sudo apt -f install`；这几项**目前尚未执行**，联网后按错误情况处理。
- [ ] **安装 SSH：** 联网后安装 `openssh-server`，使用 `systemctl status ssh` 检查，并从 Windows 使用 `ssh nasadmin@<实际NAS地址>` 验证；后续建议配置密钥认证与必要的防火墙规则。
- [ ] **主机名：** 当前显示 `localhost.localdomain`，按需改为 `ubuntu-nas` 并核对 `/etc/hosts`。
- [ ] **启动与存储健康：** 复核 `lsblk -f`、`findmnt /boot/efi`、`df -h`，确认 UEFI 回退启动在下一次重启仍正常；适当检查 SSD 健康状态。系统盘容量约 32 GB，避免把大量容器数据直接堆在系统盘。
- [ ] **基础服务与插件：** 根据真实需求安装、验证 Docker、Samba、Cockpit、Portainer 等；本阶段**均未安装**。
- [ ] **补充验证结果：** 保存网络、SSH、软件包、服务自启动及备份方案的实际输出，回到本篇文档增补“后续阶段”，不另建重复记录。

## 8. 复现要点与结论

| 事项 | 证据等级 | 结论 |
| --- | --- | --- |
| U 盘从 UEFI 入口启动 | 已验证 | 进入 Ubuntu Server 安装器 |
| 整盘写入 BIWIN SSD | 安装器日志和分区记录 | 分区、格式化、系统文件解压已执行 |
| 最初安装中断 | 已验证 | `grub-install` 注册 EFI 启动项时 I/O 错误 |
| `--no-nvram --removable` 修复 | 已验证 | GRUB 返回成功，回退启动文件存在 |
| 从 SSD 启动并登录 | 已验证 | `nasadmin` 正常登录，属于 sudo 组 |
| 网络、SSH 与 NAS 软件 | 未完成 | 待路由器到位后继续 |

**本次最有价值的经验：** Ubuntu Server 安装器在末尾报错时，不应立即认定磁盘或系统镜像整体损坏。优先从 `/var/log/installer/curtin-install.log` 确认具体失败命令；对于 `failed to register the EFI boot entry: Input/output error`，在核实目标盘及挂载点后，可尝试 `chroot` 中的 `grub-install --no-nvram --removable`，再以实际开机验证。切勿把这些命令无差别应用到其他设备。

---

**维护标记：** 此文为 **第 1 阶段：系统安装与 UEFI 引导修复**。后续网络/SSH/插件与 NAS 应用部署完成后，继续更新本文件并补充验证证据。
