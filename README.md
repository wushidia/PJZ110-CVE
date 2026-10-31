# PJZ110

一加 13（`PJZ110` / `OP5D0DL1`）的 POSIX CPU timer UAF 本地提权载荷，
针对以下构建实测可用：

| 项目 | 值 |
| --- | --- |
| 设备 | 一加 13 / `PJZ110` / `OP5D0DL1` |
| 指纹 | `OnePlus/PJZ110/OP5D0DL1:17/CP2A.260605.016/V.487427a-2227f32-224bc4c:user/release-keys` |
| 内核 | `6.6.118-android15-8-g9bc34d5b0c79-abogki537459655-4k` |
| 页大小 / CPU | 4 KiB / 8 个在线 CPU |
| 起始身份 | `u:r:shell:s0`（selinux Enforcing） |

## 原理

漏洞在 `exec()` 与非 leader 线程的 POSIX CPU timer 清理之间。线程把它们共享的 TID
交换出去后 `execve()` 失败，释放掉的 `k_itimer` 的 `rb_node` 仍留在活任务的
`posix_cputimers` 红黑树里；之后的 `cleanup_timerqueue()` 会再次操作这个陈旧节点。

利用分四段：

1. **泄漏。** 通过 `events/kmem/rss_stat/trigger` 软开启隐藏的 kmem tracepoint，读取
   `per_cpu/cpuN/trace_pipe_raw` 原始记录（`trace`/`kallsyms` 在 shell 域不可读，raw
   记录才带真实指针），得到 direct-map 基址、子进程的 `cred` 与 `task_struct`，
   以及 page alloc/free 事件 id。
2. **制造受害对象。** 非 leader 线程建立大量 CPU timer，保留一个后 `execve()` 自身，
   让失败的 exec 留下陈旧 `rb_node`。
3. **回收。** 用 `posix_timers_cache` padding 防止 SLUB 滞留在半空 slab，再用 8 KiB
   `AF_UNIX` socket datagram 回收释放出的 order-1 页；载荷除 `rb_left = S` 外全零。
4. **写。** 收割 zombie 触发 `timerqueue_del()` → `rb_erase()` 的 case-1-left，在 `S`
   处产生一次 8 字节零写。`S` 依次指向子进程真实 `cred` 的 uid/gid、`current->cred`
   指针、`selinux_state.enforcing` 与伪造 cred 的 uid；最后一次 `task->cred` 指向回收页
   中的满权限伪造 cred，子进程 fork 后经 `ksud late-load` 装入已安装管理器的
   `libksud.so`，得到 `u:r:ksu:s0` 的 root。

每次 plant 都会先验证回收（slab 页确实释放、且由本进程的 spray 线程重新分配）才收割；
任何未验证的状态只 park 进程、不收割，因为对陈旧节点执行 `cleanup_timerqueue()`
会 panic 内核。park 后只能靠重启清理。

## 参考

- [zjns](https://github.com/zjns)：`src/timer.c` 直接的
  上游来源，触发时序、order-1 回收、真实 cred 零写与 fake cred / KernelSU late-load
  两条收尾都出自这里。
- [woshigenm](https://github.com/woshigenm)：最初的
  Android 移植思路（tracepoint 泄漏、timer UAF 触发）。
- [`YuKongA/ghostlock-app`](https://github.com/YuKongA/ghostlock-app)：KernelSU
  late-load 最终阶段与 App 侧集成参考。

本仓库只做设备化：按本构建重新推导了 `do_timer_create` / `copy_process` 调用点、
`selinux_state`、`panic_on_warn`、`init_*` 等符号地址，并把设备、镜像哈希和全部常量
固化在 `profiles/pjz110/cp2a.260605.016.json`。

## 目录

```text
bin/timer     静态、非 PIE 载荷（cred 写入后经 /proc/self/exe 重执行）
src/timer.c   对应源码
scripts/build.sh  NDK 28.2 / API 35 重建（产出与 bin/timer 同哈希）
profiles/pjz110/  设备、镜像哈希、常量与 trace 事件 id
```

## 用法

```sh
adb push bin/timer /data/local/tmp/timer
adb shell chmod 755 /data/local/tmp/timer

adb shell /data/local/tmp/timer ids     # 探测 tracefs page event id
adb shell /data/local/tmp/timer leak    # 只做泄漏，不触发 UAF
adb shell /data/local/tmp/timer         # uid-0 shell，打印 id + context
adb shell /data/local/tmp/timer shell   # 交互 sh
adb shell /data/local/tmp/timer fake    # fake cred + 安装版 ksud late-load
```

`fake` 成功标志：日志出现 `KSU_LOADED`，随后 `/system/bin/su -c id` 为
`uid=0 ... u:r:ksu:s0`。

## 测试

经过测试可以使用。

## 注意

- 失败会 park 并持有内核状态：不要 kill、不要 `timeout`，重启是唯一清理方式。
- root 只在本次开机有效，重启后需重跑。
- 常量对应上表构建；换内核需重新推导。