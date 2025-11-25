# Tests/LatticeTests - Test Suite

## Overview
Comprehensive test suite for Lattice ORM covering CRUD operations, queries, relationships, sync, and edge cases.

## Test Files

### LatticeTests.swift
**Main test suite** covering core functionality:
- Basic CRUD (Create, Read, Update, Delete)
- Query operations
- Relationships (to-one, to-many)
- Transactions
- Schema creation
- Error handling

**Key Test Patterns**:
```swift
@Test func test_BasicCRUD() throws {
    let path = "\(String.random(length: 32)).sqlite"
    let lattice = try testLattice(path: path, Trip.self)
    defer {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
    }
    
    // Test operations...
}
```

### PropertyTests.swift
**Property system tests**:
- Property type conversions
- Optional properties
- Private(set) support (lines 22-40)
- EmbeddedModel serialization
- LatticeEnum handling

**Notable Test**:
- `test_PrivateSet()` - Verifies private(set) properties are persisted correctly
  - Uses `testLattice()` helper for temporary DB
  - Tests both public and restricted properties

### ResultsTests.swift
**Query results tests**:
- Results iteration
- Live updates
- Observation
- Filtering
- Sorting
- Pagination

**Observation Tests**:
- Test that results update when underlying data changes
- Verify observers are called on correct isolation context
- Memory management (observers don't leak)

### SyncTests.swift
**Synchronization tests**:
- AuditLog generation
- Change upload/download
- Conflict resolution
- Multi-client scenarios
- Offline/online transitions

**Test Scenarios**:
- Two clients syncing via server
- Conflicting changes (last-write-wins)
- Network failure recovery
- Large change sets

### MeasureUtils.swift
**Performance measurement utilities**:
- Timing helpers
- Memory profiling
- Benchmark utilities

**Usage**:
```swift
@Test func test_Performance() throws {
    let result = measure {
        // Operation to benchmark
        for i in 0..<1000 {
            lattice.add(Trip(name: "Trip \(i)"))
        }
    }
    print("Time: \(result.duration)s")
}
```

## Test Utilities

### testLattice(path:types...)
**Critical helper function** - Creates temporary Lattice instance:

```swift
func testLattice(path: String, _ types: any Model.Type...) throws -> Lattice {
    let url = FileManager.default.temporaryDirectory.appending(path: path)
    return try Lattice(for: types, configuration: .init(fileURL: url))
}
```

**Why it's important**:
- Each test gets fresh database with clean schema
- Prevents schema conflicts from previous test runs
- Ensures consistent state
- Easy cleanup with `defer { Lattice.delete(...) }`

**Example from PropertyTests.swift:22-40**:
```swift
@Test func test_PrivateSet() throws {
    let path = "\(String.random(length: 32)).sqlite"
    let lattice = try testLattice(path: path, ModelWithPrivateSet.self)
    defer {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
    }

    let obj = ModelWithPrivateSet(publicVar: "public", restrictedVar: "restricted")
    lattice.add(obj)

    let results = lattice.objects(ModelWithPrivateSet.self)
    guard let retrieved = results.first else {
        Issue.record("No objects found")
        return
    }
    #expect(retrieved.publicVar == "public")
    #expect(retrieved.restrictedVar == "restricted")
}
```

## Running Tests

### All Tests
```bash
swift test
```

### Specific Test
```bash
swift test --filter test_PrivateSet
swift test --filter test_BasicSync
```

### Test Class
```bash
swift test --filter PropertyTests
swift test --filter SyncTests
```

### With Verbose Output
```bash
swift test --verbose
```

## Common Test Patterns

### Setup/Teardown
```swift
@Test func testSomething() throws {
    // Setup
    let path = "\(String.random(length: 32)).sqlite"
    let lattice = try testLattice(path: path, MyModel.self)
    
    // Teardown (always runs, even if test fails)
    defer {
        try? Lattice.delete(for: .init(fileURL: FileManager.default.temporaryDirectory.appending(path: path)))
    }
    
    // Test body
    // ...
}
```

### Testing Errors
```swift
@Test func testInvalidOperation() throws {
    #expect(throws: LatticeError.self) {
        try lattice.someInvalidOperation()
    }
}
```

### Testing Async Operations
```swift
@Test func testAsyncOperation() async throws {
    let result = await lattice.asyncQuery()
    #expect(result.count > 0)
}
```

### Testing Observations
```swift
@Test func testObservation() async throws {
    let expectation = expectation(description: "Observer called")
    
    let results = lattice.objects(Trip.self)
    let token = results.observe { trips in
        expectation.fulfill()
    }
    
    lattice.add(Trip(name: "Test"))
    
    await fulfillment(of: [expectation], timeout: 1.0)
}
```

## Test Models

Tests define their own models:

```swift
@Model
class TestTrip {
    var name: String
    var days: Int
    init(name: String, days: Int = 0) {
        self.name = name
        self.days = days
    }
}

@Model
class ModelWithPrivateSet {
    var publicVar: String
    public private(set) var restrictedVar: String = "hi"
    
    init(publicVar: String, restrictedVar: String) {
        self.publicVar = publicVar
        self.restrictedVar = restrictedVar
    }
}
```

**Why separate test models?**
- Isolation from production models
- Test-specific features (edge cases)
- Simpler than full production models
- Can change without breaking production

## Test Coverage

### Well-Covered Areas
- ✅ Basic CRUD operations
- ✅ Query filtering and sorting
- ✅ Relationships (to-one, to-many)
- ✅ Property types (primitives, optionals)
- ✅ Private(set) properties
- ✅ Schema creation and discovery

### Areas Needing More Tests
- ⚠️ Complex multi-table queries
- ⚠️ Large datasets (performance)
- ⚠️ Concurrent access (thread safety)
- ⚠️ Schema migrations
- ⚠️ Edge cases in sync (network failures)
- ⚠️ Memory leaks (observation cycles)

## Debugging Failed Tests

### Test Fails with "Count: 0"
**Symptom**: Objects aren't being saved/retrieved

**Possible Causes**:
1. Using default Lattice config instead of `testLattice()`
   - **Fix**: Use `testLattice(path:types...)` helper
2. Old database schema conflicts
   - **Fix**: Use unique path for each test
3. Missing type in schema
   - **Fix**: Pass all model types to `testLattice()`

**Example Fix** (PropertyTests.swift):
```swift
// Before (broken)
let lattice = try Lattice(ModelWithPrivateSet.self)

// After (fixed)
let lattice = try testLattice(path: "\(String.random()).sqlite", ModelWithPrivateSet.self)
```

### Test Hangs on Observation
**Symptom**: Test never completes

**Possible Causes**:
1. Observer never called (event didn't fire)
2. Deadlock in observation system
3. Waiting on wrong isolation context

**Debug Steps**:
1. Add timeout to expectation
2. Print statements in observer
3. Check isolation context matches

### Schema Errors
**Symptom**: "table has no column named X"

**Cause**: Database from previous test run has old schema

**Fix**: Always use `testLattice()` with unique path

## Performance Benchmarks

### Baseline Expectations
- Insert 1000 objects: < 1 second
- Query 10000 objects: < 100ms
- Update single object: < 10ms
- Complex query with joins: < 50ms

### Measuring Performance
```swift
import MeasureUtils

@Test func testInsertPerformance() throws {
    let lattice = try testLattice(path: "perf.sqlite", Trip.self)
    
    let duration = measure {
        for i in 0..<1000 {
            lattice.add(Trip(name: "Trip \(i)", days: i))
        }
    }
    
    print("Inserted 1000 objects in \(duration)s")
    #expect(duration < 1.0)
}
```

## CI/CD Integration

### GitHub Actions
```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: swift test
```

### Pre-commit Hook
```bash
#!/bin/bash
swift test || exit 1
```

## Common Issues

### Issue: Tests Pass Locally but Fail in CI
**Cause**: Timing differences, race conditions

**Fix**:
- Increase timeouts for async operations
- Use proper synchronization primitives
- Don't rely on execution order

### Issue: Flaky Tests
**Cause**: Tests depend on timing or external state

**Fix**:
- Use deterministic data (no random unless seeded)
- Proper cleanup in `defer` blocks
- Isolated test environments (unique DB per test)

### Issue: Slow Tests
**Cause**: Not using testLattice, accessing default DB

**Fix**:
- Always use `testLattice()` with temporary path
- Clean up databases in `defer`
- Use in-memory DB for fast tests (`:memory:`)

## Future Test Improvements

### Needed Tests
1. **Schema Migration** - Test database upgrades
2. **Concurrency** - Multi-threaded access patterns
3. **Stress Tests** - Large datasets, many connections
4. **Property Tests** - Generative testing with random inputs
5. **Integration Tests** - Full client-server sync scenarios

### Test Infrastructure
1. **Test Fixtures** - Reusable test data builders
2. **Mock Server** - In-memory sync server for tests
3. **Snapshot Testing** - Compare query results to snapshots
4. **Coverage Reports** - Track test coverage percentage

## Related Documentation
- See `../Sources/Lattice/CLAUDE.md` for core implementation details
- See `../Sources/LatticeMacros/CLAUDE.md` for macro testing
- See root `CLAUDE.md` for overall architecture
