# Voice Memos SQLite/WAL 安全快照与并发策略（v0.1）

研究日期：2026-08-28。范围是私有 Voice Memos `CloudRecordings.db` 的**安全只读**访问；不读取任何用户录音、标题、转写或数据库行值，不执行真实库实验。本文把 SQLite 官方证据、工程推论和需实机验证明确分开。

## 结论

推荐 v0.1 默认采用方案 2：源以 `mode=ro` 打开，使用 `sqlite3_backup` 增量复制到临时 `0700`/`0600` 目录，再对目标短事务只读。SQLite 保证 backup 完成后目标是最后一次有效 start/restart 对应的一致、up-to-date snapshot；设置总 deadline、restart 次数和 progress/page 上限，防止持续写入导致永不收敛。

方案 1（直接对源使用 `mode=ro` + read transaction）只适合诊断或已证明目录可写、sidecar 完整的环境：WAL 只读打开可能需要创建/写入 `-shm`，因此不能承诺“不修改源”。`immutable=1` 可避免创建 sidecar，但它是“永远不会被其他进程修改”的断言；Voice Memos 正在并发写入时可能得到错误结果或 `SQLITE_CORRUPT`，不可默认使用。

方案 3（手工复制 DB+WAL）仅作为诊断 fallback，前提是能证明 source quiescent、无活动事务且复制期间不会写入。pre/post stat/hash 只能检测漂移，**不是一致性证明**；不复制 live `-shm`，让副本连接在临时目录中由 SQLite 重建 wal-index。若无法证明 quiescent，必须失败并回到 backup。

## 官方证据（SQLite）

- WAL 中每个读事务固定一个 end mark；同一事务只看到单一时间点，读者可与写者并发，但 WAL 只有一个写者；checkpoint 会避开仍被读者使用的 end mark。[WAL](https://www.sqlite.org/wal.html)
- 活跃 WAL 数据库由 `X`、`X-wal`、`X-shm` 三文件描述；`-shm` 是 mmap 的 wal-index。最后客户端正常关闭通常会 checkpoint 并删除 sidecar，但只读客户端或异常退出可能留下它们。[WAL 文件格式](https://www.sqlite.org/walformat.html)
- SQLite 3.22+ 可在 `-wal/-shm` 已存在且可读、目录可创建 sidecar，或连接使用 `immutable` 时打开只读 WAL；因此 `mode=ro` 并不等于绝不写目录。[WAL 只读数据库](https://www.sqlite.org/wal.html#readonly)
- URI `mode=ro` 强制只读；`immutable=1` 表示文件不会被其他进程改变，若断言不成立可能产生错误结果或损坏错误；`nolock=1` 禁用所有 VFS 锁，多个连接之一使用它可能导致损坏，不能用于 Voice Memos 源。[URI 文件名](https://www.sqlite.org/uri.html)、[sqlite3_open_v2](https://sqlite.org/c3ref/open.html)
- Online Backup API 完成后目标是与启动时刻一致的 bit-wise snapshot；若外部写入导致 restart，则对应**最后一次有效 start/restart** 的一致、up-to-date snapshot。源只在每次 `sqlite3_backup_step` 读取期间加读锁。SQLite API 文档允许 `SQLITE_BUSY`/`SQLITE_LOCKED` 稍后重试；但本设计使用 dedicated read-only source connection，不存在合法的同连接写事务，因此 `SQLITE_LOCKED` 视为内部/连接结构冲突，默认 fail-closed；只有另有证明安全的连接拓扑时才可单独启用 LOCKED retry。`SQLITE_IOERR`、`SQLITE_NOMEM`、`SQLITE_READONLY` 视为致命；目标在 `backup_init` 至 `backup_finish` 期间持有写事务且不可交给其他 API/线程。[Backup API 总览](https://www.sqlite.org/backup.html)、[backup C API](https://www.sqlite.org/c3ref/backup_finish.html)
- `busy_timeout`/busy handler 是 SQLite 官方的锁等待机制；超时后返回 `SQLITE_BUSY`，应用应有限次退避而非无限等待。[PRAGMA busy_timeout](https://sqlite.org/pragma.html#pragma_busy_timeout)、[Backup API 锁处理](https://www.sqlite.org/backup.html#file_and_database_connection_locking)
- SQLite 警告文件复制、绕过锁、删除/重建 WAL 等做法会破坏原子性；应用必须遵守锁协议。[How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html)
- SQLite 临时文件（journal、WAL、临时表 spill 等）可能写入磁盘；可通过临时目录/`SQLITE_TMPDIR` 等机制定向，故副本运行目录必须是 owner-only `0700`。[Temporary Files](https://www.sqlite.org/tempfiles.html)

## 三种方案比较

| 方案 | 快照一致性 | 对 Voice Memos 源的副作用 | 并发/失败 | 判定 |
|---|---|---|---|---|
| 1. 源 `mode=ro` + read transaction | 事务内有 WAL end mark，一致；事务外多次查询可能跨时间点 | 只读 WAL 可能创建/更新 `-shm`；不写主库但可能改目录；`nolock` 禁用锁，危险 | 需 busy timeout；源 checkpoint/写入可使打开或查询失败 | 诊断/受控环境；非默认 |
| 2. `sqlite3_backup` | 官方保证最后一次有效 start/restart 对应的一致 up-to-date snapshot；分步时源锁短 | 目标临时库会写 journal/WAL；源 `mode=ro` 仍可能涉及 source sidecar，需实机确认 | `BUSY` 有界退避；dedicated source 下 `LOCKED` fail-closed；设置 deadline/restart/progress 上限 | **v0.1 默认** |
| 3. 复制 DB+WAL（不复制 live SHM） | 仅 quiescent source 可用；stat/hash 仅漂移检测，不证明一致 | 不触及 source；副本由 SQLite 在 owner-only 目录重建 SHM/临时文件 | 证明不了 quiescent 或发现漂移即失败 | 诊断 fallback |

### 事务、锁和 checkpoint 规则

源访问禁止 `PRAGMA journal_mode`、`VACUUM`、写事务和 `nolock`。`PRAGMA query_only=1` 只是防护，不是一致性机制；schema 探测与业务查询必须在同一个显式 `BEGIN` read transaction 内完成。普通查询遇到 `SQLITE_BUSY` 时退避重试；`SQLITE_LOCKED` 表示连接/共享缓存内部冲突，在 dedicated read-only source 架构下直接 fail-closed（若未来证明存在安全的独立连接拓扑，才可另设 LOCKED retry 分支）。不要通过 WAL 文件是否存在推断“没有其他连接”。

`FD` 生命周期必须绑定连接：打开、事务、读取、关闭均在同一 owner；不把 SQLite FD 交给其他线程/库。POSIX advisory locks 仅能协调遵守 SQLite VFS 的客户端，不能停止 `voicememod`；因此锁不是 Voice Memos 的互斥协议。严禁 `nolock`。

## 推荐 v0.1 算法（伪代码）

```text
startup:
  acquire_owner_lock_or_verify_liveness()
  cleanup_stale_snapshots(prefix="voice-memos-cli.", older_than=24h) # TTL 仅兜底
  source = resolve_user_authorized_Recordings_directory()
  require source/CloudRecordings.db is regular, mode-readable
  before = stat(db, wal?, shm?)                 # existence,size,mtime,inode

  dir = mkdtemp(mode=0700)
  try:
    copy db -> dir/db with O_CREAT|O_EXCL, mode=0600
    if diagnostic_fallback and prove_source_quiescent_and_no_active_txn:
      if exists(db-wal): copy db-wal -> dir/db-wal with O_EXCL, mode=0600
      # never copy live db-shm; SQLite rebuilds it in dir
    else: use_sqlite3_backup_with_deadline_restart_and_progress_limits()
    fsync copied files and directory
    after = stat(db, wal?, shm?)
    if before != after: retry whole snapshot (max 3) # drift detection only

    conn = sqlite3_open_v2("file:"+dir+"/db?mode=ro", READONLY|URI)
    set busy_timeout(1000)
    reject if PRAGMA journal_mode attempts change or integrity probe fails
    BEGIN (read transaction)
      schema-detect + allowlisted metadata queries only
      copy/export assets only after independent regular-file/path checks
    COMMIT
  on SQLITE_BUSY: bounded backoff
  on SQLITE_LOCKED: fail closed (dedicated read-only source; no legal same-connection write)
  on SQLITE_CORRUPT/IOERR/READONLY or any copy/stat mismatch: fail closed
  finally: close conn/FDs; securely remove dir; if removal fails log path only
```

默认 backup 段：源 `mode=ro` 连接与临时目标连接分别建立，`sqlite3_backup_init(dest,"main",src,"main")`；每次 `backup_step(128)`，对 `SQLITE_OK` 继续、`BUSY` 退避，`LOCKED` 直接 fail-closed（仅证明存在安全独立连接拓扑时才允许专门 retry 分支）；追踪 restart/page/progress，任一总 deadline 或上限超出即 `finish`、关闭并失败。`DONE` 后 `backup_finish`，再只读打开目标。目标连接在 backup 生命周期内禁止共享；IOERR/CORRUPT/NOMEM/READONLY 立即失败。副本连接的 SQLite temp spill 定向至同一 `0700` owner 目录。

## 临时目录、权限、清理与数据最小化

- 临时目录必须由 `mkdtemp` 创建为 `0700`；文件 `0600`，不继承用户可写共享目录。路径不得包含标题或录音 ID。
- 正常、取消、异常路径都关闭连接和 FD 后递归删除；启动清扫前先取得 owner lock、检查目录是否仍被本进程存活实例使用；TTL 只是 owner/liveness 不可判定时的兜底。崩溃无法保证清理，故残留只存加密/受保护磁盘并设置短 TTL。
- 不复制音频、`.qta`、manifest，除非当前命令明确 export 且路径通过 allowlist/realpath 校验；SQLite 快照只保留完成当前查询所需最小生命周期。
- 日志只记录错误码、schema 版本、文件大小/mtime 摘要，不记录标题、转写、音频内容或完整路径；FD 不跨线程泄漏。

## 需实机验证（隔离测试库）

在独立 macOS 用户、无真实录音/独立 Apple Account、可丢弃 synthetic DB 上验证：

1. Voice Memos/`voicememod` 持续写入时，backup 是否在 deadline/restart 上限内得到最后一次有效一致快照；记录 source sidecar 是否被 `mode=ro` 创建/修改。
2. source 只有 DB、DB+WAL、DB+WAL+SHM，分别以 `mode=ro` 和 `immutable=1` 打开；确认错误码和结果，不把 immutable 用于活动库。
3. 并发 checkpoint、锁持有、WAL 增长/截断、进程 SIGKILL/断电模拟；验证副本完整性、启动清扫和失败关闭。
4. backup 外部写入导致重启/永不收敛时的上限；确认 `finish` 回滚目标且无残留。
5. macOS 15/26、系统 SQLite 版本、权限（FDA/用户选目录）、网络/云同步切换矩阵。

## 集成测试矩阵

| 场景 | 预期 |
|---|---|
| 静态 DB，无 sidecar（clean close） | backup 成功；副本 SQLite 自行创建所需临时文件；不创建 source 文件 |
| 活跃 WAL，sidecar 可读 | 读到已提交事务；副本方案源 inode/大小/mtime 不变 |
| WAL/SHM 同时不存在（正常 clean close） | backup/只读打开可成功；仅不完整或无法打开时失败 |
| WAL 存在但 SHM 缺失且源目录不可写 | `mode=ro` 明确失败；不回退 `nolock` |
| 复制期间 DB/WAL 增长 | 重试；仍变化则失败关闭并清理 |
| Voice Memos 持有写锁 | 有限退避；超限返回 BUSY，不死等 |
| checkpoint 与读事务并发 | 查询结果单事务一致，关闭后 checkpoint 可继续 |
| backup 返回 `SQLITE_LOCKED` | dedicated source 架构直接 fail-closed；最终 finish/回滚目标 |
| backup 返回 IOERR/CORRUPT/READONLY | 不重试；删除目标并报告错误 |
| sidecar 复制权限拒绝/磁盘满 | fail-closed；无半成品被读取 |
| SIGINT/SIGKILL 后重启 | 旧临时目录按 TTL 清扫；不触及 source |
| 标题/录音路径含敏感值 | 日志和临时路径不泄露字段值 |

## 决策

v0.1 使用方案 2 `sqlite3_backup` + `mode=ro` 副本读取；方案 3 仅在可证明 source quiescent/no transaction 时作为诊断 fallback，且不复制 live `-shm`。方案 1 仅诊断开关可用，必须报告其可能创建 source sidecar 的语义。所有策略只支持只读 list/search/show/export；不以快照支持 rename/delete，也不把 SQLite 一致性误称为 Voice Memos/CloudKit 业务一致性。
