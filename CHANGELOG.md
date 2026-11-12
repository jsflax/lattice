# Changelog

## [3.0.0] - Unreleased

Release candidate: the core dependency remains pinned by revision during
qualification. It must move to the real LatticeCore 3.0.0 version before
this package is tagged; this entry describes that intended version pair.

**One-way storage change. Read this before you upgrade.** Lattice 3.0.0
requires LatticeCore 3.0.0. That core writes storage epoch 9 and installs
write-guard triggers when it first opens a store for writing. After that, a
build with an older core cannot write to the store. A raw SQLite connection
that lacks the core's guard function cannot write to it either. This holds even
when the 3.0.0 open itself then fails. There is no downgrade. Upgrade and
restart every process that shares a store together. If an older build must
still write to a store, copy that store before 3.0.0 first opens it.

This release also adds asynchronous and scoped local opens, checked
transactions nested across different stores, a larger read-only MCP tool set
with an optional host read policy, byte-bounded relay frames, and audit,
history and sync inspection calls.

### Compatibility
- One-way storage change, as described above. Lattice 3.0.0 requires
  LatticeCore 3.0.0. Once 3.0.0 has opened a store for writing, an older core
  cannot write to it, and neither can a raw SQLite connection without the
  core's guard function. There is no downgrade. Rebuild native and Swift
  bridge consumers together. The LatticeCore 3.0.0 changelog lists which opens
  convert a store, the error an older build reports, and the changed sync
  storage and transport rules.
- The conversion happens on the first ordinary writable open. Read-only opens
  do not convert a store. That covers `isReadOnly` handles and
  `Lattice.dynamic`, which LatticeMCP and `lattice-mcp` use. An open with
  `requiredExistingSchemaVersion` does not convert a store, and attaching a
  store to another handle does not convert the attached file.
- The owned MCP SDK fork requirement moves from exact 0.13.0 to exact 0.13.1.
  Only `LatticeMCPTransport` and the `lattice-mcp` executable depend on it.
- Declared platforms are unchanged: macOS 14 and iOS 15, with Swift tools
  6.3. `LatticeMCP` now opens its own read-only inspection connections through
  the system SQLite library, the same library LatticeCore already links. No
  new install step is needed. On Linux the existing `libsqlite3-dev`
  requirement covers it. See Known limits for LatticeMCP on iOS.
- A typed optional link on a managed object now reads `nil` when its target
  row is gone, for example after a synced delete left the link row in place,
  or when another connection removes the link between the presence check and
  the read. Earlier releases could crash on that read. The link also reads
  `nil` while its target row is not yet visible to the reading connection. A
  later read can return the object. Two cases are not covered: a link stored
  inside a `@Union` payload, and a non-optional model-typed property. See
  Known limits.
- Dynamic query filters are stricter. `DynamicQuery.whereSQL`, and the `where`
  argument of `lattice_query` and `lattice_count`, accept only primitive
  columns that are not geo-bounds, plus `id` and `globalId`. A filter on a
  link, list, geo-bounds or union property throws
  `DynamicQueryError.unknownProperty`, which the MCP tools report as
  `unknown_property`. Its message now ends "is not a filterable scalar column
  of the model". Operands must be JSON scalars: string, number, boolean or
  null. Convert Swift values such as `UUID` to a string first. A container
  operand or an empty operator object returns `invalid_predicate`. An empty
  `$or` now matches no rows.
- LatticeMCP without a read policy keeps the 2.6.1 limits: 100 rows by
  default, link depth 1, nearest `k` 10, a 10,000 row ceiling and a depth
  ceiling of 5. For the seven query tools, out-of-range values of `limit`,
  `offset`, `depth` and `k` are clamped and unknown top-level arguments are
  ignored, as before. A top-level argument whose value is JSON null is treated
  as omitted for those tools. Null is not treated as omitted in three places:
  inside a `sort` entry, for `lattice_status` and `lattice_changes`, and
  whenever a read policy is set.
- Other LatticeMCP inputs are checked more strictly than in 2.6.1, with or
  without a policy. Arguments must be a JSON object. These now return
  `invalid_arguments`: a wrong-typed argument other than `limit`, `offset`,
  `depth` and `k` (without a policy those four still fall back to their
  default), a missing required argument, a negative `primaryKey`, a malformed
  `sort` entry, a sort order other than `asc` or `desc`, both or neither of
  `primaryKey` and `globalId`, a `globalId` that is not a UUID, an unknown
  `metric`, a vector component that is not a finite number, and coordinates
  out of range or a radius that is not positive. `order` and `metric` must be
  exact lowercase; 2.6.1 ignored case. An empty `vector`, an empty `match`,
  and extra keys inside `near` or inside a `sort` entry also return
  `invalid_arguments`. A missing required argument returned
  `invalid_predicate` in 2.6.1. The catch-all code `error` is gone; unexpected
  failures now return `invalid_arguments`, `query_failed` or `open_failed`.
  `lattice_schema` with an unknown `model` returns `invalid_table`. A search
  on a field without the matching index returns `unsupported_search`.
- LatticeMCP results changed. Query results carry a `source` object.
  `source.id` is the absolute path of the store unless the pool was created
  with `sourceID:`, which replaces the path in results and errors.
  `lattice_query` adds `hasMore` and `nextOffset` and orders rows by `id`
  after any requested sort. The search tools add `limited`. A backend read
  failure returns `query_failed` where 2.6.1 returned an empty result. The
  pool checks the file before and after each call and returns
  `source_changed` when the file or its schema changed during the read. A
  SQLite file without Lattice metadata is refused. Without a read policy, a
  Lattice file with no readable model schema is refused too: the provider
  initializer throws and the pool returns `open_failed`. `lattice-mcp`
  reports server version 0.2.1, up from 0.1.0. In Swift,
  `LatticeDataProvider.handle` is now `async`, `toolNames` is a computed
  property with nine names, and the limit parameters of both initializers are
  optional.
- The relay still accepts inbound frames up to 64 MiB, so clients on earlier
  releases, which batch uploads by row count, keep working. Audit frames the
  relay sends are now bounded by `Lattice.maximumEncodedSyncMessageBytes`
  (4 MiB) in fan-out, catch-up and observer push, so one large upload can
  reach a peer as several frames. A stored row that exceeds the budget is
  sent alone, with no upper limit on the relay side, so it cannot block the
  rows behind it. Frames that are not audit uploads are forwarded unchanged.
  On an unfiltered channel a LatticeCore 3.0.0 client sends an entry above
  the ordinary 4 MiB budget alone when it and its audit-log envelope fit the
  8 MiB hard bound. A filtered sender also charges retained identifiers and
  routing metadata against its retained-byte bound, so its largest admitted
  entry depends on those fields. A larger entry is refused before upload
  with an error that names the audit id and table. The core does not impose
  this sender bound on received rows.
- Relay catch-up stops reading pages when its connection closes or is
  revoked. A connection revoked while pages are being read is closed with
  code 1001. Rows pruned ahead of a running catch-up are skipped and catch-up
  ends normally. A page holds at most `initialCatchUpPageSize` rows (1 to
  1000, default 1000) and is also bounded by bytes.
- `Lattice.openLocal` and `Lattice.withLocalOpen` open local stores only. A
  configuration with a WSS endpoint, sync identity, certificate pin, IPC
  targets or background sync throws
  `AsyncLocalOpenError.unsupportedConfiguration` before anything is opened.
  Every migration block must be registered with `Migration.addSendable`, or
  the open throws `unsafeMigrationCallbacks`. Those blocks run on a worker,
  not on the caller's actor. Cancellation waits for the native open and its
  cleanup. It cannot undo a migration that already committed.
- Scoped local open guarantee. `withLocalOpen` runs its body synchronously on
  the caller's actor with the opened handle. When the body returns or throws,
  the temporary native ownership is released on a worker, and the call waits
  for that release before it returns. The release never closes another handle
  on the same store. A handle that the body kept or returned stays valid,
  also if the task is cancelled after the body succeeded.
- File creation on open. `Configuration.allowsFileCreation` defaults to
  `true`, the earlier behaviour. With `false`, opening a missing file fails
  and creates nothing, and an existing file still gets normal schema setup
  and migration. Memory stores are not affected.
- `withTransaction` no longer refuses every nested call. A nested call on a
  different physical store now runs, and its commit survives a later rollback
  of the outer transaction. Review code that relied on the old refusal. The
  refusal message changed to "Nested checked transactions require a different
  physical store". See Changed for the full rule.
- Failure tracking in `withTransaction` is now per connection. In 2.6.1 a
  failed write or query on any handle on the same thread failed the enclosing
  transaction and rolled it back. From 3.0.0 only a failure on the connection
  that owns the transaction does. A failure on another connection, for
  example a handle on a second store or an independent handle on the same
  file, no longer rolls the outer transaction back and is not reported by it,
  unless that connection has a `withTransaction` of its own. Give a second
  store its own nested `withTransaction`, or check `lastQueryError()` on the
  other handle. Review blocks that write to more than one store.
- `attach(lattice:)` and `detach(lattice:)` now throw inside the handle's own
  `withTransaction`. `attach(lattice:)` and `attaching(lattice:)` throw when
  either handle was opened with `requiredExistingSchemaVersion`.
- `LatticeError` conforms to `LocalizedError`, and `localizedDescription` now
  includes the underlying database message. Remove any `LocalizedError`
  conformance your code adds to `LatticeError`.
- The local-open span hook is public API: `LatticePerf.spanHook`, `SpanHook`,
  `SpanScope`, `Span`, `Span.end()` and `beginSpan(_:scope:)`. 3.0.0 reports
  five spans around each local open. The set of span names may grow in a
  minor release, so a hook must accept names it does not know.
- Debug reads on dynamic objects are SPI, not public API.
  `DynamicObject.debugJSON`, `debugPrimaryKey` and `DynamicDebugReadError`
  need `@_spi(LatticeInternals) import Lattice` and are exempt from semantic
  versioning. `LatticeDebugBridge` is an implementation target, not a library
  product.
- Three protocol requirements were added with default implementations:
  `Model.authoredInitializers`, `EmbeddedModel.embeddedCodec` and
  `LatticeBackend.receiveSyncData(_:immutableTables:authorize:)`. The `@Model`
  macro now generates `authoredInitializers`. The five new `Configuration`
  fields listed under Added take part in equality and hashing, and handles
  that differ in them do not share a cached connection.

### Added
- Add `Lattice.openLocal(for:configuration:)` and
  `openLocal(independentFor:configuration:)`. They run the native open and
  any migration off the caller's actor and return a handle that keeps the
  caller's isolation. `Migration.addSendable(from:to:_:)` registers a
  migration block that may run on that worker.
- Add `Lattice.withLocalOpen(for:configuration:_:)` and
  `withLocalOpen(independentFor:configuration:_:)`, the scoped form described
  under Compatibility.
- Add `Lattice.init(independentFor:configuration:)` for a distinct connection
  outside the path and scheduler cache. Closing it does not close other
  handles on the same store.
- Add `Configuration.allowsFileCreation`, `requiredExistingSchemaVersion`,
  `uploadsEnabled`, `wssSyncIdentity` and `pinnedServerCertificateSHA256`. A
  required schema version opens an existing file at exactly that version with
  no create, migration, repair or automatic maintenance. Such handles cannot
  attach databases or own sync transports. `uploadsEnabled = false` stops
  outbound sync data and keeps downloads and their acknowledgements.
  `wssSyncIdentity` keeps a durable channel identity separate from the
  address that is dialed. The certificate pin is the SHA-256 of the server's
  leaf certificate in DER form, written as 64 lowercase hex characters, and
  needs a `wss` endpoint. Any other value makes the open throw
  `LatticeTLSPin.ConfigurationError.invalidPin`. `LatticeTLSPin` and
  `LatticeTLSTrust` expose the checks.
- Add the task-local `LatticePerf.spanHook` with `beginSpan(_:scope:)` and
  `Span`. A local open reports `Lattice.openLocal.prepare`,
  `Lattice.openLocal.worker.open`, `Lattice.openLocal.adopt`,
  `Lattice.openLocal.dispose` and `Lattice.openLocal.return`. With no hook
  installed, no callback runs.
- Add `Lattice.withCurrentReadScope(_:)` to read current committed rows for a
  synchronous decision while a renderer still holds an older batch.
- Add checked audit reads: `auditCursor()`, `auditReadFence()` and
  `latestAuditStamp(tableName:globalRowID:)`. Add `prepareForAuditedWrites()`
  to turn auditing back on for a store where it was left disabled.
- Add store-local metadata that is never synced or audited:
  `localMetadata(namespace:key:)` and, inside `withTransaction`,
  `insertLocalMetadataIfAbsent(_:namespace:key:)`.
- Add `requireMainFileUnmoved(expectedPath:)`, a check that the open
  connection's main file still occupies the path it was opened at.
- Add sync receive and history calls:
  `receive(_:immutableTables:authorize:)`,
  `appendCurrentSnapshots(tables:publicationKey:)`, `ensureCurrentHistory()`,
  `currentIdentitySnapshot()`, `hasAppliedSyncEvent(globalID:)`,
  `lateBindNoHistoryChecked(_:)` (throws `Lattice.NoHistoryBindingError`),
  `removeSyncChannelStateChecked(syncId:)`,
  `removeSyncChannelStateChecked(ipcChannel:)` and
  `Lattice.maximumEncodedSyncMessageBytes`.
- Add optional capability protocols for custom backends:
  `AuditCursorBackend`, `AuditReadFenceBackend`, `AuditedWritesBackend`,
  `LocalMetadataBackend`, `MainFileCurrentnessBackend` and
  `SyncChannelRetirementBackend`. A backend without a capability makes the
  matching call throw.
- Add `DynamicResults.groupedCounts(by:parameters:)`.
- Add declaration metadata that is read without creating a model:
  `Model.authoredInitializers`, `Model.validatedAuthoredInitializers()` and
  `EmbeddedModel.embeddedCodec`, with their descriptor types.
- LatticeMCP: add `LatticeReadPolicy` and the `readPolicy:` parameter on
  `LatticeDataProvider` and `LatticeProviderPool`. The pool also takes
  `sourceID:`. With a policy only the listed models and fields are readable.
  Defaults are 25 rows, depth 0 and `k` 25. `limit` and `k` must be 1 to 500
  and depth 0 to 3. Unknown arguments and out-of-range values are errors.
  Arguments are limited to 64 KiB and results to 32 KiB.
- LatticeMCP: add the `lattice_status` and `lattice_changes` tools, a
  `fields` argument on the read tools, a `model` filter on `lattice_schema`,
  `LatticeToolCatalog`, `LatticeToolDescriptor`, `LatticeDiagnostics` and
  `LatticeScopeValidation`. A host that passes a read policy must advertise
  `LatticeToolCatalog.tools(readPolicy:)` with the same policy. The plain
  `tools` list describes the limits without a policy. `lattice-mcp` gains
  `--version`, `--doctor` and `--help`.
- LatticeMCPTransport: add
  `LatticeSerializedStdioTransport.compatibleCodexInitialize(_:)`. The
  transport applies it to incoming messages. It drops an empty
  `codex/auth-change` experimental capability from an `initialize` request
  and leaves every other message unchanged.
- LatticeServerKit: `configureSyncRelay` gains `initialCatchUpPageSize:`,
  `revalidateAfterRegistration:`, `transactionAuthorization:` and
  `downloadExcludedTables:`. Add `SyncChannel.isCurrent` and
  `SyncWritePolicy.immutableTables`. A mount with excluded tables delivers
  through observer push. `initialCatchUpPageSize` outside 1 to 1000 stops the
  process with a precondition failure. An upload refused by `immutableTables`
  or by `transactionAuthorization` is answered with a `rejected` frame. It is
  not acknowledged and not forwarded to peers.

### Changed
- `withTransaction` nesting rule. A nested checked transaction on a different
  physical store is independent. Nesting is not a multi-store atomic commit,
  and callers must take stores in a consistent order. Still refused before
  BEGIN, all with the same message: the same handle, the same file through
  another handle or link, a memory store with the same name, any handle with
  attachments, a store whose file identity cannot be established, and any
  call inside a sync `authorize` callback. A failure is recorded on the
  connection that reported it, so a failure on an outer store does not stop
  an inner store's commit.
- The dynamic predicate translator quotes admitted column names, so a column
  named like an SQL keyword keeps its meaning.
- `LatticeProviderPool` drops a reader that was idle for 60 seconds and drops
  the oldest idle readers when it holds more than eight. With a read policy
  it serves only its default store and refuses a store that was replaced.
- `lattice-mcp` now rejects unknown options and a second database path.
- LatticeServerKit: on a mount whose store is opened read-only, a client
  acknowledgement is now treated as a receipt for that connection only. The
  relay writes nothing to the store and does not forward it. An
  acknowledgement frame that is not exactly `kind` plus an `ack` list of UUID
  strings is answered with a `rejected` frame.

### Fixed
- Cancelling a `changeStream` or `changeHeaders` consumer during delivery can
  no longer park the shared observer delivery thread. A batch already in
  flight at cancellation may finish resolving afterwards.
- A typed optional link whose target row is gone reads `nil`. See
  Compatibility.
- Relay catch-up no longer keeps reading pages for a connection that has
  closed.
- `Lattice.delete(for:)` no longer fails when the WAL or SHM file is already
  gone. A missing main file still fails.
- A materialized snapshot on a closed store reports the failure through
  `onQueryError` and `lastQueryError()`. It no longer looks like a successful
  empty read.
- Swift-encoded audit rows omit null placeholders from `changedFieldsNames`,
  so native receivers accept local UPDATE entries that a Swift relay sends.

### Known limits
- Links. A link stored inside a `@Union` payload still returns a blank,
  non-nil model when its target row is gone. A non-optional model-typed
  property has no guard for a missing target. Declare model links as
  optional properties.
- Dynamic filters. The refusal of link, list, geo-bounds and union properties
  relies on the schema snapshot stored in the file. A file without that
  snapshot reports every column as primitive. `sort` in `lattice_query` is
  not held to the filter rule and still accepts a link or list property name.
- LatticeMCP null handling. Without a read policy a null `order` inside a
  `sort` entry is refused, and `lattice_status` and `lattice_changes` refuse
  a null `db`. Those two tools also refuse unknown arguments in every mode. A
  wrong-typed optional argument other than `limit`, `offset`, `depth` and `k`
  is refused even without a policy.
- LatticeMCP schemas. Without a policy the advertised schemas of
  `lattice_status` and `lattice_changes` allow extra properties although the
  tools refuse them. `radiusMeters` advertises a minimum of 0 although the
  value must be greater than 0.
- LatticeMCP on iOS. `LatticeDiagnostics` uses Swift clock APIs that need
  iOS 16, while the package declares iOS 15. Only the `Lattice` product is
  built for iOS in this release's checks. Build LatticeMCP for macOS or
  Linux.
- Nested transactions. All refusals share one message, also when the cause is
  an attachment, an unknown store identity or a sync callback. Store identity
  for a file is read from the open connection. When it cannot be read, nested
  calls that involve that store are refused. A failure reported
  by a connection that has no checked transaction of its own is not recorded.
  See Compatibility.
- Local open. The last open wins: a local open republishes its own
  configuration and results tuning for a store that already has a live
  handle, as the synchronous initializer does. The scoped form does this
  before the body runs, also when the body then rejects the handle.
- No-create open. The refusal of a missing file is the ordinary native open
  failure. There is no dedicated error case to match. An open that is served
  from the connection cache does not check the file again, so it can succeed
  after the file was removed while another handle is still open. "Existing"
  means that the path exists.
- Errors. Open failures and several checked reads still throw non-public
  error types that cannot be matched by case. Some `LatticeError` cases name
  a neighbouring operation: `detach(lattice:)` reports its in-transaction
  refusal as `attachFailed`, and snapshot publication, history publication
  and the applied-event lookup report failures as `syncReceiveFailed`.
- Span hook. The five span names are string literals and are not yet
  documented on the declarations. The hook runs synchronously inside the
  open, so it should return quickly.
- Certificate pins work with the Apple WebSocket transport only. On other
  platforms an open with a pin throws.
- `requireMainFileUnmoved` reports the current state only. It cannot detect a
  file that was moved away and back between two checks.
- Relay rows. The relay does not apply the core's 8 MiB per-row limit to what
  it serves. See the LatticeCore 3.0.0 changelog for the client-side row
  limits and the other sync limits of this release.

## [2.6.1] - 2026-11-02

### Added
- Publish configuration-based iOS background refresh, independent finite
  `syncOnce`, and the lifecycle and sync correctness changes described in 2.6.0
  below. See the Background Sync on iOS guide for setup and ownership examples.

### Fixed
- Require LatticeCore 2.5.1 so concurrent first opens can finish enabling WAL
  within their configured busy timeout instead of failing immediately.
- Preserve native error details in relay test failures and isolate remaining
  bounded binding tests from unrelated parallel SQL workloads without changing
  their deadlines or assertions.

The 2.6.0 source tag is retained, but its GitHub Release was not published after
the required macOS check exposed the existing concurrent-open defect. Upgrade
to 2.6.1 with Core 2.5.1 and follow the coordinated restart guidance below.

## [2.6.0] - 2026-11-01

### Added
- Opt into iOS background refresh through `Lattice.Configuration.backgroundSync`.
  Lattice registers the configured task, observes application lifecycle, and
  binds work to the retained store. Lazy stores can call
  `Lattice.registerBackgroundTasks(configuration:)` before launch finishes.
- Add `syncOnce(maximumDuration:)` for a finite sync opportunity independent of
  Apple task registration. Completion confirms the starting upload horizon,
  negotiated initial replay, and owned cleanup; cancellation waits for cleanup.
- Send an ordered catch-up completion marker from `LatticeServerKit` only when
  a client requests it. Older servers remain usable but cannot confirm finite
  completion, so a finite caller receives an unconfirmed/budget outcome.
- Coordinate background suspension and foreground resumption across the
  original store, references resolved on other actors, and internal query
  connections. Derived handles stay local; the original owner syncs the file.

### Fixed
- Preserve public sync progress subscriptions across deferred ownership,
  repeated finite sessions, and foreground reconnection.
- Fence expired tasks and closed account bindings from successors. Settle
  owned work and retire managed readers before reporting task completion;
  preserve ordinary manual callers' existing reader behavior.
- Pair with Core's UUID acknowledgement case fix, durable filtered outbox,
  callback lifetime corrections, and cancellable owned SQLite waits.
- Build iOS 15 targets consistently with Xcode explicit modules through Core's
  shared-pointer-backed iOS handle layout.
- Keep blocking native sync and settlement off Swift's cooperative workers so
  cancellation and other actor work can advance under load.

### Compatibility
- Requires LatticeCore 2.5.0. Upgrade and restart every process owning a store's
  sync channels together; older Core owners do not replay pending durable
  outbox rows. Downgrading with pending outbox data is unsupported.
- Rebuild iOS native bridge objects and Swift consumers together. Previously
  compiled iOS foreign-reference bridge objects must not be mixed with Core 2.5.0.
- Background scheduling requires an iOS host app, Background fetch capability,
  the matching `BGTaskSchedulerPermittedIdentifiers` entry, and a writable
  file-backed WSS store with a nonempty authorization token. It is off by default.
- Register before app launch finishes. Intervals are scheduling hints; iOS
  controls delivery. No scene-state forwarding or swizzling is required.
- Close the retained original store at logout. Closing it also retires its
  managed derived connections; stale references cannot reopen that lineage.
  Reopen with new configuration and references for another account.

## [2.5.0] - 2026-10-30

### Added
- Add the optional `reauthorizeChannel` callback to `Lattice.configureSyncRelay`
  for a second grant check after revocation registration and before store access
  or initial delivery.
- Expose publicly readable, transient `AuditLog.noHistoryNulls` and
  `AuditLog.synthesized` metadata for observed nullable clears and snapshot
  provenance; neither adds a model column.

### Fixed
- When `reauthorizeChannel` is configured, recheck relay authorization after
  registering the connection for revocation and before opening its store or
  sending data. Pending connections cannot receive fan-out, and buffer-limit
  refusals revoke the connection.
- Preserve intentional NULL clears on nullable `@NoHistory` fields through
  Swift sync upload and replay. Keep the null provenance and synthesized-snapshot
  metadata intact, and reject malformed metadata instead of treating it as a
  valid change.
- Encode Swift `Int` values outside the signed 32-bit range using the existing
  Int64 wire representation, preserving wide values during native sync replay.
- Convert native dynamic-open failures into Swift `databaseError` values with
  the original error message instead of letting C++ exceptions escape the bridge.
- Keep `@Union` string conversion inside the SDK so consumer modules can use the
  generated code with `import Lattice`, without an additional `CxxStdlib` import.
- Surface native sync decode failures and server upload rejections through the
  paired Core diagnostics. Rejected uploads remain pending under the existing
  retry policy.
- Serialize test-relay compaction with its receive queue and report native
  maintenance errors, preserving snapshot and fresh-client catch-up assertions.

### Compatibility
- Requires LatticeCore 2.4.2 for the checked dynamic-open bridge, NACK/decode
  diagnostics, and indexed reverse-link lookups that distinguish link tables
  from union side tables. Core's storage-epoch 7 migration installs the indexes
  when an existing writable store opens.
- Rebuild native and Swift bridge consumers together. The owned MCP SDK remains
  pinned to 0.13.0.
- Upgrade peers and relays together to retain nullable-clear metadata. Older
  implementations may discard it; this release does not repair previously
  acknowledged missed clears.

## [2.4.0] - 2026-10-24

### Added
- Add `Configuration.syncStartup = .deferred` to open local storage before
  acquiring WebSocket sync ownership, repairing sync state or creating a
  transport. Start sync after the first local read with `connectSync()`.
- Add throwing `connectSync()`, `disconnectSync()` and `reconnectSync()` methods
  that retain the same local database handle, rows and observers. Custom
  backends can opt into the additive `SyncLifecycleBackend` capability.

### Fixed
- Retain the native callback bridge across transport disconnect/reconnect and
  retire it only when the transport is destroyed. Fence callbacks from retired
  URLSession and Linux NIO connection attempts.
- Prime explicit materialized snapshots from the scalars already fetched by
  Core, avoiding per-row refetches and retaining the captured scalar values.
  Relationship reads keep their existing live behavior.
- Join asynchronous test-server shutdown before releasing fixture resources.

### Compatibility
- Requires the new Core 2.4.0 lifecycle and row-hydration support. Automatic
  startup remains the default, and IPC startup behavior is unchanged.
- `disconnectSync()` pauses WebSocket sync while retaining local storage and
  ownership. Call `close()` to release native locks before app suspension.

## [2.3.0] - 2026-10-23

### Added
- Add throwing `Lattice.storedSchemaVersion()` to read the actual persisted
  schema version without migration or writes. Missing, malformed, nonpositive,
  out-of-range and closed-store metadata fails explicitly. Third-party backends
  can opt into the additive `StoredSchemaVersionBackend` capability.

### Fixed
- Release scheduler actor context and cached actor delivery metadata on explicit
  close. Core scheduler copies share one context owner, so temporary Swift bridge
  values cannot release a context still used by a native scheduler.
- Preserve callback lookup for surviving facades when a newer facade sharing the
  same native store is released. Query-error collectors remain separate for each
  facade. This does not change the requirement to explicitly close short-lived
  handles.

### Changed
- Require LatticeCore 2.3.0 and update the complete dependency lock and upstream
  release bindings together. Rebuild native and Swift bridge consumers together;
  store schemas, wire protocols and the owned MCP SDK requirement are unchanged.

## [2.2.5] - 2026-10-23

### Fixed
- Require LatticeCore 2.2.8 so existing dependency locks also receive vector
  reads during writer contention, cross-connection vector readiness invalidation,
  and rejection of malformed sync changes before apply, acknowledgement or
  receive-cursor advancement.
- Update the complete dependency lock and upstream binding checks to the released
  Core version. The Swift API and owned MCP SDK requirement are unchanged.
- Register sync URL-change test observers before writes and capture bounded
  concurrent-apply diagnostics, preserving the existing assertions and timeouts.

## [2.2.4] - 2026-10-22

### Fixed
- Copy Apple WebSocket binary transport bytes without invoking imported C++ collection witnesses, avoiding an iOS 26 startup crash when built with a newer toolchain. Text frames and send completion behavior are unchanged.

## [2.2.3] - 2026-10-22

### Fixed
- Require LatticeCore 2.2.4 so the first vector result and count include
  existing synced rows without reopening the store. Cold index creation,
  repair and historical-row fill complete atomically and can retry after
  a failed setup on the same connection.
- Include Core 2.2.3's atomic union-schema migration: preserve parent and
  custom triggers, and refuse unsafe view or foreign-key rewrites without
  losing stored data.
- Keep the complete dependency lock and strict upstream binding checks in
  sync with the released Core version. Add fresh-store Swift IPC coverage
  for the first vector result and count.

## [2.2.2] - 2026-10-22

### Fixed
- Require LatticeCore 2.2.2 so receipt-table or receive-cursor setup failures
  return no acknowledgement candidates and release the remote-apply flag.
  Reentrant or overlapping applies cannot clear an active delivery's flag.
- Carry the released Core version through the manifest, complete dependency
  lock and strict upstream binding checks. Existing chunk retry and
  committed-prefix acknowledgement/cursor handling are preserved.

## [2.2.1] - 2026-10-18

### Fixed
- Synchronize the relay write-policy regression with both initial empty-channel catch-ups before seeding its no-fanout baseline. Preserve strict rejection, unchanged peer-frame count and row-survival assertions.
- Evict read caches recreated during native close or deletion, so subsequent reads through existing and new results return empty instead of a pre-close cached count.

## [2.2.0] - 2026-10-18

### Added
- Add throwing `TableResults.groupedCounts(by:)` for stored String columns.
  It returns scalar keys and counts through one bound query without hydrating
  model payloads. Filtered unions and distinct counts retain their visibility
  rules; a distinct identity present under multiple keys can contribute to
  multiple counts. The representative key for conflicting copies is unspecified.
- Reject unsupported query shapes, computed properties and unavailable backend
  capabilities rather than reporting an empty successful result.

### Changed
- Require released LatticeCore 2.2.1 for the scalar grouped-count bridge
  with explicit closed-store errors.
  Rebuild native and Swift bridge consumers together. Store schemas, existing
  group queries and the owned MCP SDK requirement remain unchanged.
- Keep hosted source, build, temporary, log and evidence outputs under localdev,
  preserving the complete strict dependency-lock checks and existing test paths.

## [2.1.0] - 2026-10-17

### Added
- Add `LatticeThreadSafeReference.resolveIndependent()` for an independently
  owned connection to the referenced store. It preserves the original
  configuration, schemas and row migrations, returns `nil` if the backing
  file is missing, and throws other open failures.
- Independent connections bypass the path/scheduler cache and do not retain
  the calling actor. Keep the returned non-Sendable handle inside one actor
  or otherwise serialize its use. Named memory storage retains its configured
  identity; opening an independent connection does not create a separate store.

### Changed
- Require LatticeCore 2.1.0 for the checked uncached bridge constructor and
  native statement-lifetime and committed-observer-delivery fixes. Rebuild
  native and Swift bridge consumers together. Existing cached `resolve()`
  behavior and the owned MCP SDK requirement remain unchanged.

## [2.0.1] - 2026-10-17

### Fixed
- Require LatticeCore 2.0.8 so reopening a store does not request a writer
  transaction for sync-state repair when no rows need repair. Eligible repairs
  still acquire a writer transaction and recheck acknowledgments against the
  current live replication slots before atomically updating the audit log and
  removing the corresponding sync state.
- Carry this minimum through Lattice's package dependency so downstream
  consumers also receive the startup fix. The Swift API and owned MCP SDK
  requirement remain unchanged.

## [2.0.0] - Unreleased

LatticeCore dependency floor raised to `2.0.4` (audit-history hygiene,
reader lifetime and attachment topology, observer cursor correctness, and
native sync scheduling and watchdog lifetime fixes: see its changelog). An Orbital room store reached 17 GB with under 1 MB of live
data — every streamed rewrite of one message row was kept in full in the
audit log, nothing pruned it on a store without sync partners, and the one
nuclear tool renumbered ids and silenced every other process.

### Breaking changes
- `Lattice.vacuum()` and the corresponding `LatticeBackend` requirement now
  return `Bool`; `checkpoint()` returns `CheckpointResult`. Update typed
  method references and backend conformances. Ordinary calls can discard
  these results.
- Custom `LatticeBackend` conformers must implement `reclaimSpace`,
  `pruneAuditLog`, `recordAuditWatermark`, `backdateAuditWatermarks`,
  `setReplicationSlotObserver`, `noHistoryLiveValuesJSON` and `auditHeader`.
  These inherited audit requirements do not have default implementations.
- Bind this wrapper to the qualified LatticeCore 2.0.4 release, with matching
  manifest minimum and resolved tag revision.

### Added
- Add the optional **`LatticeMCPTransport`** product with serialized sends
  and shutdown that retains its connection, reader and queued writes until
  their owners finish. Its MCP dependency requires iOS 16; the plain Lattice
  product retains its existing platform declaration.
- **`withTransaction`** provides synchronous checked BEGIN/COMMIT handling,
  preserves the first captured operation failure and attempts rollback on
  failure. Through 2.6.1 it rejected every nested checked transaction before
  the nested body ran. From 3.0.0 a nested transaction on a different
  physical store is allowed; see the 3.0.0 entry. Checked backend
  BEGIN/COMMIT hooks include default implementations.
- **`@NoHistory`** property attribute: the column's UPDATE audit rows record
  the column name but not its value (INSERT/DELETE rows keep values). Live
  observers, `changeStream` and `changeHeaders` fire exactly as before. Sync
  delivers the row's latest value at upload/push time — core fills it on the
  upload path; `Lattice.lateBindNoHistory(_:)` does the same for audit rows
  serialized in Swift, and the relay's observer push and connect-time catch-up
  call it. `Model.noHistoryProperties` exposes the set. Applies to stored
  primitive columns only (a macro error otherwise).
- **`Configuration.auditRetention`** (`TimeInterval?`, default nil = keep
  forever): arms LatticeCore's retention thread — cursor-safe, insertion-time
  pruning that never renumbers ids, coordinated across processes.
  **`pruneHistory(olderThan:)`**, **`recordAuditWatermark()`** for callers
  that drive it themselves. `compactHistory` is documented as slot-only
  (returns -1 and deletes nothing on a store that never synced).
- **`changeHeaders`**: `changeStream` without the payload — `[ChangeHeader]`
  frames (audit id, table, operation, row id, global row id) read from the
  header columns only. `changeStream` itself no longer hydrates each audit
  row to build its references (it read the whole `changedFields` payload per
  change; consumers' `resolve(on:)` read it again).
- **`reclaimSpace(maxPasses:)`** → `ReclaimResult`: VACUUM then TRUNCATE
  checkpoint — the order WAL mode needs for the main file to shrink (a
  checkpoint-then-vacuum sequence leaves it at its peak). `vacuum()` now
  returns `Bool` and never lied about failing; `checkpoint()` returns
  `CheckpointResult` (busy / partial / complete).
- **`Configuration.SyncTuning.registersAsObserver`** (and `isReadOnly`
  implies it): this handle's own sync slot is an observer's — excluded from
  compaction floors, evicted on clean disconnect. `setReplicationSlotObserver
  (syncId:isObserver:)` for a connection whose scope is learned later.
- `LatticeBackend` protocol: `reclaimSpace`, `pruneAuditLog`, `recordAuditWatermark`,
  `backdateAuditWatermarks`, `setReplicationSlotObserver`, `noHistoryLiveValuesJSON`,
  `auditHeader`;
  `vacuum()`/`checkpoint()` now return values.

### Changed
- Observer-push watcher opens, page reads/encoding and final watcher release
  use two dedicated native workers, with per-file FIFO and fair store turns.
  A separate control executor handles pump state; coalesced commit/timer hints
  and one page or socket send per subscription avoid duplicate admission.
  External route/catch-up continuations retain their existing scheduling.
- Rotate the existing 8 MiB observer worker between ready backend identities,
  preserving FIFO within each backend and serial callback execution. A queued
  burst no longer has to drain before another backend receives a turn; a running
  callback can still block the shared worker.
- Deliver unfiltered collection events from their copied operation and row
  metadata without opening an unused query handle for each batch. Preserve the
  missing-file guard, attaching actor and order within each batch.
- Queue isolated collection deliveries in a mailbox bound to the handle's
  creation actor. Each turn delivers one batch and admits at most one next
  turn, preserving accepted payloads and FIFO across value copies and attached
  clones. Pending payload storage remains unbounded; a blocked actor or
  callback can still delay delivery.
- **`forceCompactHistory()` keeps the audit id sequence** and regenerates
  link/list rows (core 2.0.0). Fixes the relay's observer-push cursor going
  silent after a server-side compaction.
- `syncProgressStream`'s cross-process pending count is probed at most once
  per second (it is an unindexed COUNT over the audit log; idle hints arrive
  per commit burst).
- Doc fix: `SyncFilter()` (empty) is NOT a "sync nothing" switch — for
  uploads core treats it like `nil`.

### Fixed
- Require Core 2.0.4 for reader lifetime and attachment publication fixes,
  transaction-owned audit pruning and history generation, and native sync
  scheduling/watchdog corrections. Rebuild native and Swift bridge consumers
  together; see Core release notes for direct C++ scheduler and mock-helper
  adoption.
- Drain autoreleased Foundation objects after each relay native-worker job on
  Darwin, so idle long-lived workers do not retain them until shutdown.
  Captured owners still release outside the worker lock.
- Require Core 2.0.3 so stale shared readers cannot replay committed changes,
  and removing an observer releases its captures outside registry locks.
  A captured object can cancel a sibling observer during destruction without
  deadlocking the registry. Concurrent table/object registration allocates
  distinct tokens through the shared atomic counter.
- Install relay WebSocket receive handlers during synchronous upgrade so an
  upload sent immediately after connecting is buffered before asynchronous
  authorization and store setup begin.
- Preserve a collection observer's attaching actor when its query handle is
  resolved on the delivery worker.
- Release the wrapper cache lock before closing a deleted store's backends,
  so native shutdown can finish callbacks that need the cache.
- Surface preserving-global-ID insertion failures through the existing
  throwing `add` API instead of allowing a bridge failure to escape.
- Capture covered primitive, list, removal and query failures before later
  bridge calls can clear their error messages.
- `@Transient` detection in the macro compared against `"@Transient"` while
  the attribute key holds the bare identifier; the predicate could never
  match (the separate string compare in `MemberAttributeMacro` was carrying
  it). Attribute detection now scans every attribute name on a declaration.

### Transaction scope
- Legacy `transaction` behavior is unchanged. The checked API does not
  guarantee rollback of in-memory caches, external closure effects, every
  operation category or non-standard C++ exceptions.

## [1.7.2] - 2026-09-03

LatticeCore dependency floor unchanged; zero core changes. Closes the
WAL-epoch durability loss class on relay channel files (the checkpoint-
starvation / wedge / unlink triad — committed frames in an on-path -wal
always survived kill -9, but three shapes could lose an entire WAL epoch).

### Added
- **`RelayCheckpointGovernor`** (`LatticeServerKit`): apply-coupled WAL
  checkpointing for relay-shaped stores (4MiB threshold + 30s backstop),
  whose custom change hook otherwise displaces SQLite's autocheckpoint
  forever. TRUNCATE passes make a plain external read the durable view.
  Wedge alarm on repeated could-not-run with a non-shrinking WAL (never
  disturbs the open transaction); registry-driven `drain(stores:)` for
  shutdown; quiet-store sweep for mounts with no apply traffic.
- **`DurableHeadLedger`**: a sidecar `<db>-ledger` JSON recording the
  durable audit head at each successful checkpoint; `bootCheck` flags a
  regressed head as FLOOR-SUSPECT (sticky, attributed) so an epoch loss is
  loud and diagnosable forever after.
- **`ServerSentEvent.floorReset(durableHead:reason:)`**: floor honesty on
  the wire. When a client's claimed `last-event-id` names a globalId the
  channel's durable history does not contain, the relay says so BEFORE the
  catch-up pages instead of silently replaying from zero. Fresh JSON keys —
  every shipped client (dispatching on `auditLog`/`ack`/`replayRequest`)
  decodes it to nullopt and ignores it, the same wire-compat discipline
  `nack` rode in on. 1.7.2+ clients treat it as the uplink instruction to
  re-mark and re-upload rows above `durableHead`.

### Fixed
- Relay floor validation: claimed catch-up floors are probed against
  durable history; a floor violation emits `floorReset` (attributed to
  "server lost history" when the boot ledger shows head regression,
  "client floor unknown to this channel" otherwise) and the socket stays
  open for the full replay.


## [1.7.0] - 2026-08-20

LatticeCore dependency floor unchanged (`from: "1.4.2"`); zero core changes.

### Added
- **Observer push** (`LatticeServerKit`): `configureSyncRelay` gains
  `observerPush: SyncObserverPush?` (default `nil` — pre-1.7 behavior
  byte-for-byte). On a push-enabled mount, every commit to a channel's
  database file — a relay-socket apply on any mount sharing the file, an
  in-process co-writer such as a projector actor, or (best-effort) another
  process — is pushed to that mount's sockets as ordinary
  `ServerSentEvent.auditLog` catch-up frames, exactly-once and
  commit-ordered per socket ("nudge + pump": a payload-free per-file commit
  observer nudges per-socket pumps that re-run the catch-up machinery from a
  monotone AuditLog-pk cursor, with awaited sends for slow-consumer
  isolation). Watch groups live on ONE process-wide manager, so push mounts
  over the same channel file share one watcher Lattice and one commit
  observer; every pump holds its own strong watcher reference, so
  last-subscriber teardown can never trap or dangle an in-flight pump.
  Clients apply pushed frames with zero changes; app-level redial loops
  become cheap no-op fallbacks. Push-enabled mounts no longer fan client
  frames (observer acks) to same-channel peers. `SyncObserverPush.pageSize`
  is validated at init (`precondition`) and clamped positive per
  subscription, so a zero/negative page can never make a pump spin without
  draining. The per-file watcher open runs OFF the process-wide manager
  actor (concurrent first subscribers dedupe onto one in-flight open), so a
  slow SQLite open on one channel cannot stall another channel's pumps,
  nudges or teardowns; and a connection whose connect-time catch-up throws
  releases its parked subscription and closes, so a failed catch-up can
  neither strand a watch group nor leave a permanently silent observer.
- `Lattice.observeCommits(_:)` — payload-free AuditLog commit signal (no
  per-row hydration, no delivery-worker hop; consumers re-query by cursor).
- `Lattice.eventsAfter(id:)` — `Int64` primary-key-cursor overload beside
  the existing `eventsAfter(globalId:)`.
- `SyncSchemaHandshake`: native `?schema=` query-parameter declaration
  (checked before the header — browser WebSockets cannot set headers) and
  `Mode.exact(Int)`, which refuses both older ("upgrade required") and
  newer ("server behind client") clients with distinct legible close
  reasons. Query-param admission is OPT-IN: the legacy `minimumVersion`
  init stays header-only (behavior-identical to pre-1.7 — an upgrade never
  silently widens a mount's admission surface); the exact-mode init
  defaults `queryParameterName` to `"schema"`, and minimum-mode mounts can
  set it explicitly. Consumers adopting exact mode can delete their
  query-lift middleware and app-level newer-schema checks.

## [1.2.0] - 2026-08-04

### Added
- `IPCSyncTarget.narrowingEmitsRemovals` — Swift surface for the Stage A4
  core flag. Default `true` (narrowing trims the peer's mirror, unchanged);
  `false` makes narrowing bookkeeping-only, which is required when the peer
  is a shared multi-writer database (a group spoke): un-sharing must stop
  future sharing without deleting rows other members already have.

## [1.0.0] - 2026-07-25

The 1.0 release. Every breaking change below is also ledgered, one line per
change, in `MIGRATION-1.0.md` — read that alongside this section when
upgrading from 0.10.x. Binary consumers: an xcframework built against 0.10.x
fails at link against 1.0 (symbols changed for the throwing `add` family, the
`changeStream` getter's new return type, and the removed
`init(isStoredInMemoryOnly:)`) — vendored binaries must be rebuilt from
migrated sources.

### Added
- `Lattice.detach(lattice:)` — drops a previously attached database's views,
  DETACHes it, and rebuilds the merged schema. Add it to teardown paths that
  `attach`.
- `Lattice.rollbackTransaction()` alongside the existing begin/commit pair.
- `Results.element(at:)` — returns `nil` for a missing index instead of a
  fabricated element (see the subscript behavior change below).
- `Configuration.resultsTuning` (`ResultsTuning`) — tuning knobs for the new
  live-results read model: page size, cached pages and shapes, generation
  TTL, WAL eviction threshold, cross-process freshness interval.
- `Lattice.retireAllGenerations()` — releases every pinned read generation;
  required before suspension in some host configurations (see the
  backgrounding note under Changed).
- Public `ColumnValue` (`.null` / `.int64` / `.real` / `.text` /
  `.blob(Data)`, one case per SQLite storage class, with
  `int64Value`/`doubleValue`/`stringValue`/`dataValue`/`isNull` accessors)
  and `MigrationContext.setValue(table:rowId:column:value:)` for staging
  per-row writes during migration enumeration.
- New `LatticeError` cases: `addFailed`, `alreadyManaged`, `attachFailed`,
  `detachFailed`.

### Changed

Live results and observation:
- **Live `Results` reads are generation-consistent.** On file (WAL)
  databases, every `count`, page fill, and `snapshot()` within one
  main-thread render batch executes at a single pinned MVCC snapshot, served
  by a small pool of read-only connections; on in-memory databases the
  equivalent is a per-query-shape materialized id vector captured under the
  store's write gate. Same-handle read-your-writes stays exact — `add`,
  `delete`, `transaction`, and managed-property setters advance the read
  epoch synchronously before returning. A commit from another same-process
  handle (a second `Lattice` instance, a sync-applied chunk) also advances
  the epoch synchronously on the writer's thread; a commit from another
  thread becomes visible at the next render-batch boundary, so a single
  frame always renders one generation. `Results.refresh()` forces an
  advance.
- **`count` and `subscript` are generation-cached** — resolved at most once
  per main-thread runloop tick instead of issuing a fresh statement per
  read, backed by a bounded per-query-shape page cache (`pageSize` ×
  `maxCachedPages` hydrated rows per shape, at most `maxCachedShapes` shapes
  per lattice, LRU-evicted). Baseline memory grows by the size of that
  cache; tune it via `Configuration.resultsTuning`.
- **Out-of-bounds and cross-generation subscripts no longer trap.** Instead
  of `fatalError("Index out of bounds")`, `Results` and `Slice` subscripts
  serve a tolerant ladder: the current fill, then a retained previous page,
  then a last-known-good element, and finally an unmanaged default-valued
  placeholder. Use `element(at:)` when you want `nil` for a missing index.
  Accessing a `@Relation` on a not-yet-inserted instance returns empty
  results instead of trapping.
- **Unsorted live queries are now deterministic**: results with no explicit
  sort carry an implicit `ORDER BY id ASC` (oldest-first) instead of SQLite
  scan order.
- **Iteration is stable under concurrent change.** On file databases,
  `for x in results` walks a captured generation and, if that generation is
  retired mid-walk, transparently re-pins and resumes from a keyset anchor —
  rows are visited at most once, in order. On in-memory databases, a row
  deleted concurrently with a render can hydrate as an invalidated
  (default-valued) placeholder for at most one frame; iteration skips such
  rows.
- **File databases trade some WAL growth for pinned reads**: the `-wal` file
  may grow up to `ResultsTuning.walKeeperEvictionThresholdBytes` (default
  16 MB) before pinned snapshots are evicted, and up to three extra
  read-only connections are opened per instance. Idle read generations
  self-retire after `ResultsTuning.generationTTLSeconds` (default 30 s) via
  a maintenance timer that runs for every configuration, including non-sync
  lattices.
- **Backgrounding retires all read generations.** This is automatic where
  UIKit is available (resign-active / protected-data notifications), and
  transparent — results re-pin lazily on the next access after
  foregrounding. App extensions and non-UIKit hosts using a shared app-group
  container MUST call `Lattice.retireAllGenerations()` before suspension: a
  suspended process holding WAL read marks in a shared container is killed
  by the system (`0xdead10cc`). SwiftUI hosts where those notifications do
  not fire should call it from a `ScenePhase` handler.
- **Cross-process freshness is a bounded-staleness contract**: another
  process's commit becomes visible within
  `ResultsTuning.crossProcessBeltIntervalMs` (default 500 ms) or on any
  same-process write or notification, whichever comes first — not
  instantaneously. Same-process writes remain read-your-writes exact.
- **`DynamicResults` is a documented exemption** from the generation-pinned
  read model: it keeps live `count` and LIMIT/OFFSET
  `snapshot(limit:offset:)` semantics, and is trap-free under concurrent
  shrink by construction. `count` and a subsequent `snapshot` are not
  mutually consistent under a concurrent writer — take one `snapshot()` and
  derive counts from it.

Throwing APIs (wrap call sites in `try`):
- **The `add` family now throws**: `add(_:)`, `add(_:preservingGlobalId:)`,
  `add(contentsOf:)`, and the `any VirtualModel` overload. Backend insert
  failures (constraint violation, closed handle, I/O error) surface as
  `LatticeError.addFailed` where `add(_:)` previously terminated the process
  and the `VirtualModel` overload silently swallowed them. Re-adding an
  already-managed object throws `LatticeError.alreadyManaged` instead of an
  unconditional message-less `fatalError()`, and `add(contentsOf:)` now
  pre-checks every element and throws before anything is inserted. The
  `throws` cascades through wrappers: helpers that wrap `add` must become
  `throws` themselves, and detached work that adds becomes
  `try await Task.detached { … }.value` so the failure reaches the caller.
- **`Lattice.attach(lattice:)` and `attaching(lattice:)` now throw**
  `LatticeError.attachFailed` on schema mismatch or alias collision instead
  of terminating the process; the new `detach(lattice:)` throws
  `LatticeError.detachFailed`. `attach` and `detach` are `mutating`
  (`Lattice` is a struct) — a handle that attaches must be bound `var`, not
  `let`; recommended teardown is `defer { try? handle.detach(lattice:) }`,
  and the non-mutating `attaching(lattice:)` returns a new merged handle.
- **`Lattice.transaction { }` now rolls back on a thrown error and rethrows
  it.** Previously a throw left the write transaction open, wedging the
  connection until the busy timeout killed the process.
- **`LatticeBackend` protocol requirements changed** (custom conformers
  only; none known outside this repo): `attach` now throws; `detach(_:)`,
  `rollback()`, and throwing `addPreservingGlobalId`/`addBulk` are new or
  updated requirements; and the read-generation machinery adds
  invalidation-hook, generation acquire/retain/release/retire,
  pool-maintenance, and generation-pinned query entry-point requirements.

Storage and memory:
- **`Configuration.isStoredInMemoryOnly` is replaced by
  `Configuration.storage`**: `.file(URL)`, `.memory()` for a fresh private
  in-memory database, or `.memory(named:)` for a shared one — handles opened
  with the same name in one process share the database and observe each
  other's writes. Migrate `.init(isStoredInMemoryOnly: true)` to
  `.init(storage: .memory())`; `.init(fileURL:)` spellings keep working, and
  `configuration.fileURL` remains as a computed accessor whose setter
  switches storage to `.file`. Boolean read sites migrate too:
  `if configuration.isStoredInMemoryOnly` becomes
  `if case .memory = configuration.storage` (file branch:
  `if case .file(let url) = configuration.storage`). Do not test the storage
  kind via `fileURL` — for memory stores it returns the legacy `:memory:`
  placeholder URL, not a real path.
- `.memory(named:)` names are percent-encoded into the backing SQLite URI:
  names no longer need to be URI-safe, and two names that differ only by
  URI-hostile characters (`?`, `#`, `%`, space) are distinct databases.
- **`EmbeddedModel` reads are tolerant**: reading a property from empty or
  undecodable stored JSON returns the type's default value (with an error
  log) instead of trapping. JSON encode failures on the write path still
  trap, now with a message naming the type.

Sync progress and change stream:
- **`Lattice.changeStream` is now
  `AsyncThrowingStream<[AnySendableReference<AuditLog>], any Error>`** (was
  `AsyncStream`) — iterate with `for try await`. Creating or iterating the
  stream no longer blocks the calling task on the background database open,
  so time limits and cancellation can fire; the AuditLog observer still
  registers synchronously at stream creation, so commits made after the
  stream exists are always captured (early batches buffer and flush in
  order). A failed background open surfaces as a thrown error at first
  iteration instead of crashing the process, and cancellation promptly ends
  iteration and removes the observer. In non-throwing observer contexts
  (view models, `.task` modifiers) the recommended policy is
  catch-and-end-observation — strictly gentler than the 0.10 trap:
  `do { for try await batch in lattice.changeStream { … } } catch { … }`,
  logging the error and re-creating the stream to resume.

Migrations:
- **`MigrationContext.enumerateObjects(table:callback:)` is
  reimplemented.** The old `(any Model, any Model) -> Void` callback was a
  never-functional stub — it compiled but did nothing. The callback now
  receives each row's `id` (`Int64`) plus the full old row as
  `[String: ColumnValue]`, and per-row writes are staged with the new
  `setValue(table:rowId:column:value:)`. The versioned `[Int: Migration]`
  dictionary remains the wired migration path in 1.0 — no public open
  invokes a `MigrationContext` block yet. The versioned row-transform path
  migrates BLOB-bearing tables byte-for-byte (now test-pinned).
- **`DynamicResults.sorted(by:ascending:)` is renamed
  `sortedBy(_:ascending:)`** — one sort spelling across the API surface,
  matching the typed `Results` family.

### Removed
- **`Lattice.onSyncProgress(_:)`** — `syncProgressStream` is the canonical
  progress API (`for await progress in lattice.syncProgressStream`), with
  `syncProgressPublisher` as the Combine adapter. The publisher is now
  stream-backed, and cancelling its subscription clears the underlying
  handler, where the old callback leaked for the backend's lifetime.
  Migration is a mechanical callback → `for await` conversion. If the loop
  lives in a `Task { … }` closure, capturing the `Lattice` struct trips
  Swift 6 region isolation ("sending … risks causing data races") — hoist
  the stream out first: `let stream = lattice.syncProgressStream;
  Task { for await progress in stream { … } }` (`AsyncStream` is `Sendable`;
  `Lattice` is not).
- **`Model.__globalId`** — the deprecated requirement is gone and the
  `@Model` macro no longer emits it; `globalId` is now the stored property
  itself (public get, setter internal to the model's module). Migration is a
  mechanical rename `.__globalId` → `.globalId` in reads and query key
  paths; to seed a specific `globalId` on insert use
  `add(_:preservingGlobalId:)`. Also removed: the macro-emitted
  `__GlobalIdName`/`__GlobalIdKey` helper structs and the orphaned public
  `StaticString`/`StaticInt32` protocols (Lattice's `StaticString` shadowed
  `Swift.StaticString` in any file importing Lattice).
- **`List`'s `Codable` conformance** — its `init(from:)` was an
  unconditional `fatalError()` stub, so decoding any model graph containing
  a `List` terminated the process, and the working encode half had no
  callers. Serialize via `@Detached` (lists mirror as plain arrays with
  their own synthesized `Codable`); a `@Codable` model with a `List`
  property is now a compile-time error — mark it `@CodableIgnored` or detach
  first.
- **Dead symbols**: the public no-op `enum Deprecated`, the duplicate
  `typealias CxxManagedLatticeObject` (use `CxxManagedModel`), the
  long-commented-out `LatticeExampleServer` executable target, and the
  orphaned `fluent`/`fluent-sqlite-driver` package dependencies.
- **Twelve underscored support symbols are no longer `public`** — they were
  not referenced by macro expansions and had zero external users
  (`Query._constructForTesting`/`_constructPredicate`/`_unionSubquery`/
  `_caseWhen`/`_unionAccessTracker`/`_unionOverrides`, `Lattice._isolation`,
  `Model._registerIfNeeded`, `_ModelStorage`, `_defaultCxxLatticeObject`,
  `_pushDefaultToStorage`; `_UncheckedSendable` moves behind
  `@_spi(LatticeInternals)`). Macro-referenced underscored plumbing stays
  public and is exempt from semver — consumers must not call it directly.
  The full audit is in `docs/spi-audit-1.0.md`; the policy is in
  `VERSIONING.md`.

### Fixed
- **Read-your-writes inside explicit transactions on file stores**: inside
  `lattice.transaction { … }` on a file-backed store, collection reads
  (`objects()` snapshots, counts, indexed access and iteration),
  `Lattice.count`, and `object(primaryKey:)` now see the transaction's own
  uncommitted writes — previously they served the pre-transaction state
  because they routed through read/keeper connections that cannot observe
  the writer connection's open transaction (managed-property reads were
  always correct). In-transaction reads now execute on the writer
  connection, never mint read generations, and never publish into the shape
  caches, so a rollback leaves no trace of the discarded writes. Memory
  stores already behaved correctly; the cross-SDK conformance scenario
  `transactions/own-writes-visible-inside` now passes.
- **Bulk-update notification coalescing**: cross-instance notifications are
  coalesced per (instance, property) and delivered by a single drain task in
  commit order, fixing a multi-minute UI hang under bulk writes (issue #4).
  Also released separately as 0.10.12.
- `syncProgressStream` no longer crashes the process if its background query
  database fails to open (cross-process path) — it logs and finishes the
  stream. Its non-sync-agent path now rides the cross-process idle hint
  instead of opening a second database handle and AuditLog observer — one
  fewer failure mode, same yields.
- `Configuration.init` no longer traps when no documents directory exists
  (headless Linux daemons, some sandboxed utility processes): the default
  database location falls back to the current working directory with a
  warning log.

## [0.10.8] - 2026-07-10

(0.10.7 was tagged but never published — its release gate hung on a relay
frame-drop race this version fixes; rolled forward per policy.)

### Fixed
- **Relay connect-window frame drop**: LatticeServerKit registered its
  frame handlers only after the per-user lattice open plus an event-loop
  hop; WebSocketKit silently drops frames with no handler registered, so a
  client that uploaded within that window lost the frame and its entries
  sat unACKed until resend/reconnect. Handlers now go live synchronously
  first; frames arriving during the open buffer in order and replay when
  the lattice is ready. `test_NIORelayCatchUp` (quarantined for exactly
  this) is re-enabled.
- **Linux**: first green Linux test suite since 0.9.x — an interop
  segfault feeding a returned `std.vector` temporary straight into
  `Data.init(Sequence)` (production read path for Data/Vector fields), the
  Linux geo shim ported across two refactors it slept through, an
  unguarded Combine import, and a strict-concurrency capture.
- CI reliability: hang-catcher time limits sized for 25x-slower runners;
  the cooperative-pool-starvation tests (semaphore-blocking observer
  orchestration) and the D1b/D2 relay set are gated off macOS CI
  specifically — full coverage remains locally and on Linux CI, where
  hangs surface as interruptible failures; a 20-minute watchdog samples
  the test process so any future hang leaves stacks in the job log.
- CI: containers to swift:6.3-noble (6.2 refused the 6.3 manifest at parse
  time); 30-minute job timeouts so a hang fails fast instead of zombieing.

## [0.10.7] - 2026-07-10

### Added
- **Materialized reads API**: opt-in row-cache reads for read-heavy code paths. A live model handle issues one `SELECT` per property read (right for observation, catastrophic for bulk formatting); a materialized model serves reads from the row snapshot its originating query already hydrated — zero further SQL — falling through to the live path on any miss (slower, never wrong). Writes remain write-through.
  - `Model.materialize()` / `dematerialize()` / `isMaterialized` / `refreshMaterialized()`
  - `withMaterializedReads {}` / `withDetachSnapshot {}` scoped variants that restore the prior mode
  - `TableResults.materializedSnapshot()` — `snapshot()` with every element flipped to materialized reads
- **`Model.increment(_:by:)`**: atomic SQL-side field increment (`SET c = c + delta` under the write lock) — no read-modify-write race, and half the statements of `+= 1`
- **`Lattice.totalSQLStatementCount`** and **`Lattice.threadSQLStatementCount`**: statement-count primitives for statement-budget regression tests (thread-local twin for parallel in-process test suites)

### Changed
- **`@Detached`**: generated `detached()` routes through a snapshot — an explicitly materialized object detaches with zero SQL statements; a live object refreshes once (refresh-by-default preserved for existing callers) instead of paying one statement per field
- LatticeCore minimum version bumped to 0.10.4 (row-cache support floor)
- In-memory test configurations migrated to temp-file databases
- Five pre-existing failing/hanging tests quarantined with owner annotations (3 relay delivery hangs, 2 cross-instance observation failures) — tracked for 1.0

### Fixed
- **`@Union` compile break for class-payload unions** (present since 0.10.0): the macro emitted `Codable`/`Sendable`/`DetachableLeaf` unconditionally, so unions with model-class payloads (e.g. `case article(Article?)`) failed to compile ("associated value contains non-Sendable type"). The leaf conformances are now emitted only when every payload is a known value-leaf type (String, Int family, Double, Float, Bool, Date, UUID, Data — optionals included) or the author explicitly declares `Codable & Sendable` on the enum. Value-payload unions keep zero-boilerplate `@Detached` support; class-payload unions get `LatticeUnion` + `Equatable` and compile again

## [0.10.6] - 2026-07-05

### Fixed
- **Linux relay crash**: replaced C++ container protocol-conformance operations with index-based loops in the sync data path

## [0.10.5] - 2026-07-04

### Fixed
- **WSS transport**: stale-session URLSession delegate events are now ignored, preventing a dead connection's callbacks from corrupting the state of its replacement

## [0.10.4] - 2026-07-04

### Fixed
- **WSS transport**: each connect attempt uses a fresh ephemeral `URLSession`, so a poisoned session can no longer break every subsequent reconnect

## [0.10.3] - 2026-07-04

### Fixed
- **Sync relay**: one `Lattice` instance per connection — concurrent upload bursts previously segfaulted the server

## [0.10.2] - 2026-07-04

### Fixed
- **Linux build**: use `FileHandle.standardError` instead of `fputs(stderr)`

## [0.10.1] - 2026-07-04

### Added
- `pendingSyncEntryCount` — number of local changes not yet uploaded

### Fixed
- **Sync relay**: WS frame handlers registered before catch-up begins, closing a window where early client frames were dropped
- Sync tests no longer depend on leaked object lifetimes

## [0.10.0] - 2026-07-04

### Added
- **iOS 15 deployment floor**: minimum iOS version lowered from 16 to 15
  - Storage flipped to a pluggable boxed `any LatticeBackend`; backend selection centralized in `BackendFactory`
  - Parameterized-existential usage eliminated (witness dispatch, snapshot closures, concrete `TableResults` projections)
  - `os_unfair_lock` back-deployed below the `OSAllocatedUnfairLock` iOS 16 floor
  - Geo subsystem and `LatticeUnion` field accessors gated `@available(iOS 16.4, *)`
- **`@Union` macro**: sum types as model fields, with `switch`/`case let` query syntax and schema-evolution support
- **`@Detached` value-mirror macro**: generates a `Sendable` value-type mirror of a model plus `detached()`, with `DetachedResults` and a public memberwise initializer
- **Lattice MCP server** (`lattice-mcp`): dynamic schema-from-file API, generic query tool with per-call database routing, and `lattice_search` (FTS), `lattice_nearest` (vector), `lattice_geo` search tools
- **LatticePerf**: performance counters
- **IVF vector search**: public training API, reconcile and collection-map safety coverage
- Regression suites: close-guard (use-after-delete), observer/close races, cascade link cleanup, compound `@Unique` on link-kind fields, URL-change sync handover

### Changed
- **Cascade audits**: a single batched observer fire per WAL commit instead of one per cascaded row
- `AuditLog` uses hand-rolled `Codable` to lowercase wire UUIDs
- LatticeCore dependency resolved by version (`from: "0.10.0"`) instead of branch pin

### Fixed
- **LatticeServerKit**: WS frame handlers registered before any `await`, fixing dropped first-upload frames
- URL values were unquoted in SQL predicates
- Bare `@Unique` macro (no arguments) now works; unique-constraint auto-dedup fixed
- `.count` on `NearestResults` issues a count-only query and no longer materializes results
- `@LatticeQuery` rebinds when the lattice identity changes and no longer resurrects a deleted database
- `@Model` no longer shadows the `lattice` computed property
- Log file handling and `didSet`/`willSet` macro detection

## [0.9.1] - 2026-03-26

### Added
- `AnyProperty` decodes raw flat JSON values from SQLite audit-log triggers in addition to the typed `{"kind","value"}` format
- `_vacuumVec0` API and `setLogFile(URL)` convenience overload
- Combined geo + vector query tests

### Changed
- **`eventsAfter` is now lazy**: returns `TableResults<AuditLog>` for paginated access instead of loading all entries through the C++ bridge; `ServerSentEvent.auditLog` accepts any `Sequence<AuditLog>`, and LatticeServerKit paginates event catch-up in strides
- LatticeCore bumped to 0.9.1, swift-syntax to 603.0.0, swift-tools to 6.3

## [0.9.0] - 2026-03-16

### Added
- **Polymorphic relationships**: `VirtualList<any Protocol>` collections and `VirtualLink` (`(any Protocol)?`) single links backed by discriminated link tables, with the `@VirtualLinkProperty` macro
- **Observation infrastructure**: `ResultsChangePublisher` and `ObservableObject` conformance on `TableResults` and virtual results for SwiftUI reactivity; `List.observe()` and `VirtualList.observe()` for link-table mutation tracking; `observeLinkTable()`
- `globalId` public computed property (replaces `__globalId`, which remains as a deprecated shim); `object(globalId:)` is now public
- `add(any VirtualModel)` / `delete(any VirtualModel)` existential overloads
- IPC `socketPath` configuration for cross-platform sync
- `setLogFile()` API for file-based debug logging
- vec0 IPC sync and multi-connection lock-storm regression tests

### Changed
- Virtual results changed from struct to class for reference-semantic observation
- LatticeCore bumped to 0.9.0; NIO to 2.96.0 (Swift 6.2 Linux)

### Fixed
- Linux test compatibility (stderr concurrency safety, SQLite3 import)

## [0.8.8] - 2026-03-08

### Changed
- **LatticeServerKit**: `configureSyncRelay` takes a `storageURL: URL` instead of a `storagePath` string. The old API prepended `applicationSupportDirectory`, which on Linux resolves to an ephemeral overlay filesystem; a URL lets the caller target a persistent volume

### Fixed
- Cross-process tests hanging on CI: uncancellable `withCheckedContinuation` and polling patterns replaced with cancellation-aware `AsyncStream`

## [0.8.7] - 2026-03-07

### Fixed
- **Linux release builds**: worked around a swift-foundation type-metadata bug — `SortDescriptor` storage changed to an `(any SortComparator)?` existential so type metadata resolves at runtime via witness tables instead of failing at link time

## [0.8.6] - 2026-03-07

### Fixed
- **Linux**: link `FoundationInternationalization` explicitly — Swift 6.2 on Linux splits Foundation into sub-modules and `SortDescriptor.AllowedComparison` isn't auto-linked for downstream executables in release mode

## [0.8.5] - 2026-03-06

### Added
- Cross-process AuditLog UPDATE observer test: validates the passive sync-progress observer fires when a cross-process write only updates existing AuditLog rows

### Changed
- LatticeCore bumped to 0.8.5

## [0.8.4] - 2026-03-05

### Changed
- LatticeCore bumped to 0.8.4 (unlimited reconnect backoff — sync clients retry indefinitely instead of giving up)

## [0.8.3] - 2026-03-05

### Added
- `LatticeError.syncReceiveFailed`: `Lattice.receive()` checks the C++ `last_receive_error()` and throws instead of crashing the process — LatticeServerKit's catch block now fires on bad sync payloads

### Changed
- LatticeCore bumped to 0.8.3 (`last_receive_error` surface + deadlock fix)

## [0.8.2] - 2026-03-05

### Changed
- LatticeCore bumped to 0.8.2 (fixes a migration lookup crash)

## [0.8.1] - 2026-03-05

### Fixed
- **AuditLog `globalId` dropped during the C++ → Swift → JSON round-trip**: `JSONEncoder` emitted `"globalId": null`, which the C++ parser treated as an empty string. On multi-batch sync (>1000 events) the dedup query matched all empty-globalId rows from batch 1, silently skipping every subsequent batch
- **Linux build**: `import os` moved inside the `#if canImport(SwiftUI)` guard
- Flaky stale-slot eviction test on Linux CI

## [0.8.0] - 2026-03-04

### Added
- **Replication slots**: slot-aware `compactHistory()` (safe — respects unsynced peers) and `forceCompactHistory()` (nuclear), with stale-slot eviction
- **Sync observability**: `onSyncError()` and `onSyncStateChange()` callbacks
- **Cross-process sync progress**: passive AuditLog observation drives `onSyncProgress` when the process is not the sync agent
- `.distinct(by:)` on `TableResults`, `NearestResults`, and virtual results
- `@LatticeQuery` debounced fetch to coalesce rapid observer fires, and a fetchLimit-only initializer

### Changed
- LatticeCore bumped to 0.8.1

### Fixed
- `ModelInstanceRegistry` deadlock: the registry no longer holds its lock while accessing weak references, preventing a recursive deregister deadlock on deinit

## [0.7.0] - 2026-03-03

### Added
- **Sync Progress API**: Real-time upload/download progress tracking
  - `Lattice.SyncProgress` struct with `pendingUpload`, `totalUpload`, `acked`, `received`, `uploadFraction`, `isUploading`
  - `lattice.syncProgress` polling property
  - `lattice.onSyncProgress { progress in }` callback (fires on synchronizer background thread)
  - `lattice.syncProgressStream` — `AsyncStream<SyncProgress>` for async iteration
  - `lattice.syncProgressPublisher` — Combine `AnyPublisher<SyncProgress, Never>` (macOS/iOS)
- **Subquery Filtering with Predicate**: `Query.in(_:where:)` for filtered subqueries
  - `$0.field.in(\.otherField, where: { $0.condition == true })` generates `IN (SELECT col FROM table WHERE ...)`
- **Log Level Control**: `Lattice.setLogLevel(.debug)` to control C++ log output
- **`@LatticeEnum` default value**: Macro now generates `static var defaultValue` (first case), enabling graceful handling of unknown raw values during schema evolution
- IPC reconnection, multi-channel, filtered sync, blob round-trip, subquery-filtered link, cloud relay, and reverse cloud relay tests
- Sync progress tests (upload tracking, download tracking, ACK tracking, callback, owned-DB background thread)
- `Results.subquery` filtered links test
- Enum auto-migration test for unknown raw value deserialization

### Changed
- **LatticeServerKit simplified**: Removed built-in OAuth/JWT auth layer (`AuthController`, `OAuthAccount`, `JWKSFetcher`, `Token`, `User`). Server kit now provides sync relay only — auth is the application's responsibility.
- **`AuditLog` visibility**: Properties (`tableName`, `rowId`, `globalRowId`, `changedFields`, `changedFieldsNames`, `timestamp`, `isFromRemote`, `isSynchronized`) changed from `package`/`internal` to `public package(set)` for read access outside the module
- **`changeStream` performance**: Reuses a single query `Lattice` instance instead of creating one per AuditLog notification. Previous behavior ran `ensure_tables()` (WAL write lock) on every notification, causing `SQLITE_BUSY` under load.
- **WebSocket message size**: `maximumMessageSize` increased to 128 MB (from default 1 MB) to handle large sync batches
- **Enum deserialization**: Returns `defaultValue` instead of `fatalError` for unknown raw values
- LatticeCore dependency bumped to 0.7.0
- JWT dependency bumped to 5.0.0
- Added `fluent-sqlite-driver` dependency for `LatticeExampleServer`
- Added `LatticeExampleServer` executable target
- IPC sync tests: removed all `Task.sleep` calls (16 tests), replaced with deterministic `waitForChange` helper pattern
- Cross-platform test compatibility: replaced Darwin-only `OSAllocatedUnfairLock` with `NIOLockedValueBox`

### Fixed
- **IPC tests hanging in parallel**: `test_IPCSync_BlobColumnRoundTrip` and other tests hung when run in parallel due to race conditions from `Task.sleep`-based synchronization. Replaced all sleeps with `waitForChange` continuations.
- **IPC probe misidentifying live server**: Fixed in LatticeCore 0.7.0 — the root cause of `test_IPCSync_DeletedRowSkippedOnCatchup` hanging
- **MultipleChannels test flake**: Sequential `source.add()` calls triggered separate upload batches; `waitForChange` only caught the first. Fixed by adding notes sequentially with separate `waitForChange` calls per insert.
- **Linux build failure**: `OSAllocatedUnfairLock` (Darwin-only) replaced with `NIOLockedValueBox` from SwiftNIO (already a transitive dependency via Vapor)

## [0.6.0] - 2026-02-28

### Added
- **IPC Sync**: Cross-process database synchronization via Unix domain sockets
  - `IPCSyncTarget` configuration with `.server`/`.client` roles
  - Channel-based naming with auto-derived platform-specific socket paths
  - Bidirectional sync — changes flow both directions
  - Composable with WSS for cloud relay (`source →IPC→ target →WSS→ server`)
- **Filtered Sync**: Per-table upload filtering with predicate support
  - `SyncFilter` with `.include(Model.self, where:)` API
  - Only matching rows uploaded; incoming remote changes always applied
- **Per-Synchronizer Sync State**: Independent sync tracking per transport
  - `_lattice_sync_state` table tracks sync status per `sync_id`
  - Enables automatic cloud relay without loop prevention logic
- IPC + WSS integration tests including full Engram architecture end-to-end test
- Linux compatibility fixes for test suite

### Changed
- `websocket_client` renamed to `sync_transport` (C++ interface)
- LatticeCore minimum version bumped to 0.6.0

## [0.5.1] - 2026-02-27

### Added
- `preservingGlobalId` API for object insertion
- Profile picture support
- Migration moved into `Configuration` struct
- Attach tests and cache eviction regression test

## [0.5.0] - 2026-02-26

### Added
- `@Indexed` attribute for non-unique column indexes
