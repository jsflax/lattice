# Attached004 actual post-build failure and narrow parser proposal

Original run 35386062763 and its downloaded artifact remain unchanged. Runner 004 seal `15a953804ff8f485f8a0c193a774a65899178a45e7bc7208cf6336f94cd7dbd9` was used. The first original Release build **succeeded**, exit0, in 1242.299s; the overall supervisor failed after 1443.810s. Owned process group 14815 was reaped/gone, with no cleanup signals/errors. The qualification result contains no arms, no accepted compiler proof, no corrected build and no correctness/performance acceptance. Swift was actual Apple 6.3.3; `-enable-testing` reached both Lattice and LatticeTests, and the 15 Core/bridge compile commands show explicit `-O2`.

The build log SHA256 is `72132feda93436588ab7e2d6d3fe7110b2a9a072f6270790224272bf10ea235a`, matching its command receipt. The last recorded command is the successful build. The next operation is `build_proof.make`; no compiler-proof receipt or after-build commands exist. The primary error is bare `AssertionError`, with no traceback or message, and evidenceErrors/receivedSignals are empty.

## Concrete log-to-source rejection

Actual log 1360 contains the Swift driver link for `LatticeMacros-tool`, using the stable owned path:

`original/scratch/arm64-apple-macosx/release/LatticeMacros-tool.product/Objects.LinkFileList`

Log 1363 contains its derived Clang invocation, same output, compiler directory, target and SDK, using:

`original/tmp/TemporaryDirectory.8AXicO/inputs-1.LinkFileList`

Runner 004 `build_proof.py:90` asserts every link-list path is beneath **scratch**. For this exact child path the predicate is false, before it attempts stat/read. The same structure occurs for WalEpochWriterChild 2440/2443, lattice-mcp 2445/2448, LatticeMain 2452/2455, and the actual test bundle 2718/2721. Simply accepting the temporary path would expose a second bug at line 106: driver and child records have different argv/list paths, so the same output is rejected as a conflicting duplicate.

This is a deterministic source/log incompatibility consistent with the actual bare assertion. Because 004 did not retain a traceback, it does not prove the precise runtime program counter or rule out an earlier filesystem-dependent assertion. The source location above is the first link-list rejection directly provable from retained command text. No native compiler defect or correctness failure is inferred.

Neither the stable list contents, the temporary list contents, output-file maps, objects nor binary were included in this downloaded artifact. The stable **path/argv** evidence is real; its remote **bytes** cannot be reconstructed from that evidence. Therefore the failed run cannot be retroactively assigned a successful compiler proof, and synthetic list contents are not a substitute.

## Proposed two-file delta

`after/build_proof.py` keeps the existing canonical Swift-driver record, whose actual stable list, objects and output must still be read/hashed/validated on the execution host. A subsequent Clang command with a temporary list is accepted only as a **derived invocation** after checking the same output/compiler directory/target/SDK, one owned temporary list, and no unexplained explicit object/archive. A missing preceding canonical driver, escaped list, mismatched invocation or second child rejects. Stable-list bounds, native/Swift source-object checks and transitive reachability into the selected test binary stay intact.

The child is recorded separately with its observed argv and list path, `contentsCaptured=false`, null content hash and `contentsIndependentlyVerified=false`. Its list is never read, fabricated or used as a graph edge. This proof establishes the canonical driver inputs and final output; it does **not** independently establish the temporary child's byte-expanded inputs. Ordinary unmatched stable links retain the original rules. No blanket widening of permitted input roots is introduced.

`after/qualify.py` supplies the exact owned temporary directory and retains a bounded compiler-proof failure receipt with stage, arm, original exception, up to 8 source frames and build-log hash. The raised primary error includes file/line/function. This prevents another blank assertion from erasing the failure position. Both-builds-before-tests, commands, limits, products, overlay and qualification gates are unchanged.

`observed-link-commands.json` contains the exact 10 retained command lines/argv and source-log join. Pure command-shape checks joined all 5 observed pairs and rejected 9 altered/unmatched cases. They deliberately supply **no file-list/object/binary content**, do not call the full compiler-proof routine, and qualify no native build. Both afterimages parse as Python. The prior 22 synthetic cases were not rerun; no Swift/Core build, test, network action or remote rerun occurred. This is a source delta for review, not a sealed dispatchable successor workflow.
