#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <random>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// ============================================================================
//               SOFTWARE TRANSACTIONAL MEMORY (STM) - EDUCATIONAL CORE
// ============================================================================
//
// 1. WHAT IS SOFTWARE TRANSACTIONAL MEMORY?
//    Software Transactional Memory (STM) provides an ACID-like transactional
//    abstraction for concurrent programming in shared-memory multi-core systems.
//    Instead of manually acquiring and releasing fine-grained locks (which is
//    prone to deadlocks, priority inversions, and composition failures),
//    programmers wrap critical sections in declarative transactions:
//
//        runTransaction([&](Transaction& tx) {
//            int a = tx.read(accountA);
//            tx.write(accountA, a - 100);
//            tx.write(accountB, tx.read(accountB) + 100);
//        });
//
//    The runtime guarantees that the block executes ATOMICALLY (all-or-nothing)
//    and in ISOLATION (serializable with respect to concurrent transactions).
//
// 2. DESIGN CHOICES IN THIS IMPLEMENTATION:
//    - Update Policy: DEFERRED UPDATE (Write Buffering).
//      Writes during the transaction body do NOT modify shared memory immediately.
//      Instead, they are recorded in a private local write-set. If the transaction
//      aborts, discarding changes is instant ($O(1)$) with no rollback needed.
//
//    - Concurrency Control: COMMIT-TIME TWO-PHASE LOCKING (Commit-time 2PL).
//      Shared objects are only locked during the commit phase, maximizing read
//      concurrency during the execution phase.
//
//    - Lock Ordering: DETERMINISTIC ADDRESS SORTING.
//      To eliminate deadlocks (circular wait) when locking multiple shared
//      objects, locks are always acquired in strictly ascending order of their
//      memory addresses.
//
//    - Validation: POST-LOCK READ VALIDATION.
//      After acquiring write locks, the transaction validates that every object
//      in its read-set still has the same version observed at read time and is
//      not locked by another transaction.
//
//    - Contention Management: EXPONENTIAL BACKOFF WITH RANDOMIZED JITTER.
//      Prevents livelock, thread convoying, and retry storms under high contention.
//
//    - Error Handling: DOMAIN EXCEPTION PROPAGATION.
//      Distinguishes transient concurrency conflicts (which trigger retries)
//      from business logic exceptions (e.g. "Insufficient funds", which abort
//      and propagate immediately without pointless retries).
// ============================================================================


// ============================================================================
// 1. Telemetry and Statistics
// ============================================================================
// Real-world STM engines rely heavily on performance counters to diagnose
// contention patterns, validate design trade-offs, and tune backoff policies.

struct STMStats {
    // Total transactions that successfully passed all commit phases.
    std::atomic<uint64_t> commits{0};

    // Total transaction attempts that aborted (lock conflicts + validation failures).
    std::atomic<uint64_t> aborts{0};

    // Phase 1 failures: could not acquire a write lock because another transaction held it.
    std::atomic<uint64_t> lockConflicts{0};

    // Phase 2 failures: a read object was modified (version changed) or locked by a peer.
    std::atomic<uint64_t> validationFailures{0};

    // Total retry iterations executed across all threads.
    std::atomic<uint64_t> retries{0};

    // Reset all metrics to zero between benchmark runs.
    void reset() {
        commits.store(0, std::memory_order_relaxed);
        aborts.store(0, std::memory_order_relaxed);
        lockConflicts.store(0, std::memory_order_relaxed);
        validationFailures.store(0, std::memory_order_relaxed);
        retries.store(0, std::memory_order_relaxed);
    }

    // Formatted display of execution statistics.
    void print(const std::string& title = "STM STATISTICS") const {
        std::cout << "\n===== " << title << " =====\n";
        std::cout << std::left << std::setw(22) << "commits"
                  << ": " << commits.load(std::memory_order_relaxed) << "\n";
        std::cout << std::left << std::setw(22) << "aborts"
                  << ": " << aborts.load(std::memory_order_relaxed) << "\n";
        std::cout << std::left << std::setw(22) << "lock conflicts"
                  << ": " << lockConflicts.load(std::memory_order_relaxed) << "\n";
        std::cout << std::left << std::setw(22) << "validation failures"
                  << ": " << validationFailures.load(std::memory_order_relaxed) << "\n";
        std::cout << std::left << std::setw(22) << "retries"
                  << ": " << retries.load(std::memory_order_relaxed) << "\n";
    }
};

// Global statistics instance for benchmarks
inline STMStats g_stats;


// ============================================================================
// 2. SharedObject
// ============================================================================
// Represents a unit of transactional memory.
//
// In word-based STMs, every 64-bit word maps to a versioned lock (stripe).
// In object-based STMs, metadata is colocated with the object payload.
// Here, each SharedObject encapsulates:
//   - value_   : the actual payload.
//   - version_ : an epoch/timestamp counter incremented on every committed write.
//   - locked_  : a mutual-exclusion flag held only during Phase 3 of commit.

class SharedObject {
public:
    explicit SharedObject(int value = 0)
        : value_(value),
          version_(0),
          locked_(false)
    {
    }

    // Non-transactional, thread-safe read of the current committed value.
    // memory_order_acquire guarantees we observe all writes published prior
    // to the release store by the committing transaction.
    int getValue() const {
        return value_.load(std::memory_order_acquire);
    }

    // Inspect current version (used for diagnostics and tests).
    uint64_t getVersion() const {
        return version_.load(std::memory_order_acquire);
    }

private:
    // Only Transaction instances may read or manipulate internal STM metadata.
    friend class Transaction;

    // The shared payload.
    std::atomic<int> value_;

    // Monotonically increasing version counter.
    // Incremented whenever a committing transaction updates this object.
    std::atomic<uint64_t> version_;

    // Mutual exclusion flag held by a committing transaction.
    // Stored as atomic<bool> for fast compare-and-swap (CAS).
    std::atomic<bool> locked_;
};


// ============================================================================
// 3. Transaction
// ============================================================================
// Manages the read-set, write-set, commit validation, and lock lifecycle
// for a single transaction attempt.
//
// Key Invariant:
//   A transaction is either ACTIVE, COMMITTED, or ABORTED.
//   State transitions are one-way:
//       ACTIVE -> COMMITTED  (on successful commit())
//       ACTIVE -> ABORTED    (on conflict or exception)

class Transaction {
public:
    enum class Status {
        ACTIVE,
        COMMITTED,
        ABORTED
    };

    Transaction()
        : status_(Status::ACTIVE)
    {
    }

    // RAII destructor: guarantees that if an active transaction is destroyed
    // (e.g. due to an exception unwinding the stack), all locks held are released.
    ~Transaction()
    {
        releaseLocks();
    }

    // ------------------------------------------------------------------------
    // TRANSACTIONAL READ
    // ------------------------------------------------------------------------
    // Semantics:
    //   1. Read-Your-Own-Writes (Forwarding):
    //      If this transaction has already written to 'object', return the
    //      uncommitted buffered value from writeSet_.
    //   2. Otherwise, read the object's current value and version from shared memory.
    //   3. Record (object, version) in readSet_ so we can verify during commit
    //      that nobody modified this object while our transaction was computing.
    // ------------------------------------------------------------------------
    int read(SharedObject& object)
    {
        ensureActive();

        // Check if we previously buffered a write to this object in this transaction
        auto writeIt = writeSet_.find(&object);
        if (writeIt != writeSet_.end()) {
            return writeIt->second.newValue;
        }

        // Read current version and payload with acquire semantics to ensure consistency
        uint64_t version = object.version_.load(std::memory_order_acquire);
        int value = object.value_.load(std::memory_order_acquire);

        // Record the version observed at the time of this read
        readSet_[&object] = version;

        return value;
    }

    // ------------------------------------------------------------------------
    // TRANSACTIONAL WRITE
    // ------------------------------------------------------------------------
    // Semantics:
    //   - DEFERRED UPDATE: Do NOT modify shared memory yet.
    //   - Buffer the write locally in writeSet_.
    //   - If the object was already written within this transaction, update the
    //     buffered new value.
    // ------------------------------------------------------------------------
    void write(SharedObject& object, int newValue)
    {
        ensureActive();

        auto it = writeSet_.find(&object);
        if (it == writeSet_.end()) {
            // First time writing this object in this transaction attempt
            WriteEntry entry;
            entry.object = &object;
            entry.oldValue = object.value_.load(std::memory_order_acquire);
            entry.newValue = newValue;
            writeSet_.emplace(&object, entry);
        } else {
            // Overwrite previously buffered value
            it->second.newValue = newValue;
        }
    }

    // ------------------------------------------------------------------------
    // COMMIT PROTOCOL (5 Phases)
    // ------------------------------------------------------------------------
    // Phase 1: Acquire write locks deterministically (address sorted).
    //          If any lock fails, immediately roll back all acquired locks.
    // Phase 2: Validate read-set: check version counters and verify no peer locks.
    // Phase 3: Apply buffered writes to shared memory and increment versions.
    // Phase 4: Atomically transition status to COMMITTED.
    // Phase 5: Release all locks.
    // ------------------------------------------------------------------------
    bool commit()
    {
        ensureActive();

        // --------------------------------------------------------------------
        // Phase 1: Acquire Write Locks
        // --------------------------------------------------------------------
        if (!acquireWriteLocks()) {
            status_.store(Status::ABORTED, std::memory_order_release);
            // Partial locks were already released inside acquireWriteLocks()
            return false;
        }

        // --------------------------------------------------------------------
        // Phase 2: Read-Set Validation
        // --------------------------------------------------------------------
        // We hold our write locks. Now verify that no object in our read-set
        // was changed by another transaction between our read and now.
        if (!validate()) {
            status_.store(Status::ABORTED, std::memory_order_release);
            releaseLocks();
            return false;
        }

        // --------------------------------------------------------------------
        // Phase 3: Apply Buffered Writes
        // --------------------------------------------------------------------
        for (auto& [object, entry] : writeSet_) {
            // Publish the new payload
            object->value_.store(entry.newValue, std::memory_order_release);

            // Increment version counter with acq_rel to publish new version epoch
            object->version_.fetch_add(1, std::memory_order_acq_rel);
        }

        // --------------------------------------------------------------------
        // Phase 4: Mark Transaction Committed
        // --------------------------------------------------------------------
        status_.store(Status::COMMITTED, std::memory_order_release);
        g_stats.commits.fetch_add(1, std::memory_order_relaxed);

        // --------------------------------------------------------------------
        // Phase 5: Release Write Locks
        // --------------------------------------------------------------------
        releaseLocks();

        return true;
    }

    // ------------------------------------------------------------------------
    // ABORT
    // ------------------------------------------------------------------------
    // Explicitly aborts an active transaction and releases any locks held.
    // ------------------------------------------------------------------------
    void abort()
    {
        Status expected = Status::ACTIVE;
        status_.compare_exchange_strong(
            expected,
            Status::ABORTED,
            std::memory_order_acq_rel
        );
        releaseLocks();
    }

    Status status() const {
        return status_.load(std::memory_order_acquire);
    }

private:
    // Record of a buffered write
    struct WriteEntry {
        SharedObject* object;
        int oldValue;
        int newValue;
    };

    // State of this transaction
    std::atomic<Status> status_;

    // Map: SharedObject* -> version observed when read
    std::unordered_map<SharedObject*, uint64_t> readSet_;

    // Map: SharedObject* -> buffered write entry
    std::unordered_map<SharedObject*, WriteEntry> writeSet_;

    // Pointers to objects whose locks are currently held by this transaction
    std::vector<SharedObject*> lockedObjects_;

    // Guard: operations are only valid while the transaction is ACTIVE
    void ensureActive() const {
        if (status_.load(std::memory_order_acquire) != Status::ACTIVE) {
            throw std::runtime_error("Transaction is no longer active");
        }
    }

    // ========================================================================
    // Deterministic Lock Acquisition with Immediate Rollback
    // ========================================================================
    // Deadlock Prevention:
    //   If Transaction 1 locks A then B, and Transaction 2 locks B then A,
    //   circular wait causes a classic deadlock.
    //   By sorting all targets by their unique memory address before locking,
    //   all transactions acquire locks in the EXACT SAME global hierarchy.
    //   Therefore, circular wait is mathematically impossible.
    //
    // Partial Rollback:
    //   If lock acquisition fails on object K (because a peer transaction holds
    //   it), we must NOT hold on to objects 0..(K-1) while aborting. We release
    //   them immediately to prevent blocking other threads.
    // ========================================================================
    bool acquireWriteLocks()
    {
        if (writeSet_.empty()) {
            return true;
        }

        // Collect all distinct objects to lock
        std::vector<SharedObject*> toLock;
        toLock.reserve(writeSet_.size());
        for (auto& [obj, _] : writeSet_) {
            toLock.push_back(obj);
        }

        // Sort by memory address to establish a strict global lock hierarchy
        std::sort(toLock.begin(), toLock.end());

        for (SharedObject* object : toLock) {
            bool expected = false;

            // Attempt to acquire the spinlock flag
            if (object->locked_.compare_exchange_strong(
                    expected,
                    true,
                    std::memory_order_acquire,
                    std::memory_order_relaxed))
            {
                // Lock acquired successfully
                lockedObjects_.push_back(object);
            }
            else {
                // Lock conflict: another transaction currently owns this object.
                g_stats.lockConflicts.fetch_add(1, std::memory_order_relaxed);
                g_stats.aborts.fetch_add(1, std::memory_order_relaxed);

                // Immediately release all locks acquired in this attempt
                releaseLocks();
                return false;
            }
        }

        return true;
    }

    // ========================================================================
    // Read-Set Validation
    // ========================================================================
    // Ensures that the transaction observed a consistent snapshot of memory:
    //   1. Has any object we read been committed with a newer version?
    //   2. Is any object we read currently locked by another writing transaction?
    //      (If another transaction locked it, it is in the middle of committing
    //      a write to it, rendering our read snapshot stale/inconsistent).
    // ========================================================================
    bool validate()
    {
        for (auto& [object, observedVersion] : readSet_) {
            uint64_t currentVersion = object->version_.load(std::memory_order_acquire);

            // Condition 1: Version mismatch indicates a committed write occurred
            if (currentVersion != observedVersion) {
                g_stats.validationFailures.fetch_add(1, std::memory_order_relaxed);
                g_stats.aborts.fetch_add(1, std::memory_order_relaxed);
                return false;
            }

            // Condition 2: Object is locked by a peer committing transaction
            // Note: If our own transaction locked it (it is in our writeSet_), that is valid.
            if (object->locked_.load(std::memory_order_acquire)) {
                if (writeSet_.find(object) == writeSet_.end()) {
                    g_stats.validationFailures.fetch_add(1, std::memory_order_relaxed);
                    g_stats.aborts.fetch_add(1, std::memory_order_relaxed);
                    return false;
                }
            }
        }

        return true;
    }

    // ========================================================================
    // Release Locks
    // ========================================================================
    void releaseLocks()
    {
        for (SharedObject* object : lockedObjects_) {
            object->locked_.store(false, std::memory_order_release);
        }
        lockedObjects_.clear();
    }
};


// ============================================================================
// 4. Contention Management: Exponential Backoff with Jitter
// ============================================================================
// When multiple threads collide on the same memory locations, immediately
// retrying causes a "retry storm" (thundering herd), leading to live-lock where
// threads repeatedly abort each other without making forward progress.
//
// Solution:
//   - Early retries (attempts 0..3): Short CPU pause instruction (`_mm_pause`)
//     to avoid thread context switches on fleeting conflicts.
//   - Sustained contention (attempts >= 4): Truncated exponential backoff with
//     randomized uniform jitter to desynchronize colliding threads.

inline void contentionBackoff(int attempt)
{
    // Thread-local random number generator for fast, lock-free jitter
    thread_local std::mt19937 rng(std::random_device{}());

    if (attempt < 4) {
        // Low contention: emit hardware pause instructions
        for (int i = 0; i < (1 << attempt) * 4; ++i) {
#if defined(__GNUC__) || defined(__clang__)
            __builtin_ia32_pause();
#else
            std::this_thread::yield();
#endif
        }
    } else {
        // High contention: sleep for a randomized exponential duration (capped at 500 us)
        int maxBackoffUs = std::min(500, 1 << std::min(attempt, 9));
        std::uniform_int_distribution<int> dist(1, maxBackoffUs);
        std::this_thread::sleep_for(std::chrono::microseconds(dist(rng)));
    }
}


// ============================================================================
// 5. Transaction Runner (Control Loop)
// ============================================================================
// Repeatedly executes a transactional lambda until it successfully commits.
//
// Key Principles:
//   1. Clean Error Separation:
//      - Concurrency Conflict (commit() == false): Transient; retry with backoff.
//      - Program Exception (e.g. Insufficient funds): Permanent application error;
//        abort transaction, release locks, and re-throw immediately to the caller.
//   2. Indefinite / Controlled Retry:
//      - Default maxRetries = -1 ensures worker threads never throw unexpected
//        runtime_errors just because contention is high.

template <typename Function>
bool runTransaction(Function&& function, int maxRetries = -1)
{
    for (int attempt = 0; maxRetries < 0 || attempt < maxRetries; ++attempt) {
        if (attempt > 0) {
            g_stats.retries.fetch_add(1, std::memory_order_relaxed);
            contentionBackoff(attempt);
        }

        Transaction tx;

        try {
            // Execute user transactional logic
            function(tx);

            // Attempt two-phase commit
            if (tx.commit()) {
                return true; // Successfully committed!
            }

            // If commit() returned false, tx has aborted and released all locks.
            // Loop continues to retry.
        }
        catch (...) {
            // Application error occurred inside the transaction lambda.
            // Abort to clean up any locks, then immediately rethrow.
            tx.abort();
            throw;
        }
    }

    return false; // Exhausted maxRetries limit (if maxRetries >= 0 was specified)
}


// ============================================================================
// Example 1: Basic Single-Threaded Sanity Check
// ============================================================================
// Verifies fundamental read, write, and commit behavior in isolation.

void basicExample()
{
    std::cout << "\n===== BASIC EXAMPLE =====\n";

    g_stats.reset();

    SharedObject x(10);
    SharedObject y(20);

    bool success = runTransaction(
        [&](Transaction& tx)
        {
            int a = tx.read(x);
            int b = tx.read(y);

            // Deferred write: x = 10 + 20 = 30
            tx.write(x, a + b);
        }
    );

    std::cout << "Transaction: " << (success ? "COMMITTED" : "FAILED") << "\n";
    std::cout << "x = " << x.getValue() << " (expected 30)\n";
    std::cout << "y = " << y.getValue() << " (expected 20)\n";
}


// ============================================================================
// Example 2: High Contention Concurrent Counter
// ============================================================================
// Stress test: 8 threads concurrently increment the exact same SharedObject
// 10,000 times each (80,000 total increments).
//
// Under this extreme contention (single memory hotspot):
//   - Without backoff and deterministic locking: threads livelock or exceed
//     retry limits, throwing exceptions and terminating.
//   - With our robust core: transactions retry cleanly, telemetry exposes
//     the exact conflict profile, and the final value is guaranteed 80,000.

class Counter {
public:
    explicit Counter(int initial = 0)
        : value_(initial)
    {
    }

    void increment()
    {
        // Executes transactionally until committed.
        // Worker threads never throw on ordinary concurrency conflicts.
        runTransaction(
            [&](Transaction& tx)
            {
                int current = tx.read(value_);
                tx.write(value_, current + 1);
            }
        );
    }

    int get() const {
        return value_.getValue();
    }

private:
    SharedObject value_;
};

void counterExample()
{
    std::cout << "\n===== CONCURRENT COUNTER =====\n";

    g_stats.reset();

    Counter counter(0);

    constexpr int NUM_THREADS = 8;
    constexpr int INCREMENTS_PER_THREAD = 10000;

    std::vector<std::thread> threads;
    threads.reserve(NUM_THREADS);

    auto startTime = std::chrono::high_resolution_clock::now();

    // Launch worker threads
    for (int i = 0; i < NUM_THREADS; ++i) {
        threads.emplace_back(
            [&]()
            {
                for (int j = 0; j < INCREMENTS_PER_THREAD; ++j) {
                    counter.increment();
                }
            }
        );
    }

    // Wait for all workers to finish
    for (auto& thread : threads) {
        thread.join();
    }

    auto endTime = std::chrono::high_resolution_clock::now();
    auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(endTime - startTime).count();

    int expected = NUM_THREADS * INCREMENTS_PER_THREAD;
    int actual = counter.get();

    std::cout << "Expected: " << expected << "\n";
    std::cout << "Actual:   " << actual << "\n";
    std::cout << "Time:     " << elapsedMs << " ms\n";

    if (actual == expected) {
        std::cout << "RESULT: PASS\n";
    } else {
        std::cout << "RESULT: FAIL\n";
    }

    // Print detailed telemetry
    g_stats.print("STM STATISTICS");
}


// ============================================================================
// Example 3: Multi-Object Atomic Bank Transfer
// ============================================================================
// Modifies TWO shared objects atomically inside a single transaction.
//
// Invariant:
//   Account A + Account B must ALWAYS equal 2000 at any point of observation.
//   Neither account may be credited without the other being debited.
//
// Deterministic lock sorting ensures that even though Thread 1 transfers A->B
// and Thread 2 transfers B->A simultaneously, deadlocks CANNOT occur.

void transfer(SharedObject& from, SharedObject& to, int amount)
{
    runTransaction(
        [&](Transaction& tx)
        {
            int fromBalance = tx.read(from);
            int toBalance = tx.read(to);

            if (fromBalance < amount) {
                // Application domain error: balance insufficient
                throw std::runtime_error("Insufficient funds");
            }

            tx.write(from, fromBalance - amount);
            tx.write(to, toBalance + amount);
        }
    );
}

void transferExample()
{
    std::cout << "\n===== TRANSFER EXAMPLE =====\n";

    g_stats.reset();

    SharedObject accountA(1000);
    SharedObject accountB(1000);

    constexpr int NUM_THREADS = 4;
    constexpr int TRANSFERS_PER_THREAD = 1000;

    std::vector<std::thread> threads;
    threads.reserve(NUM_THREADS);

    for (int i = 0; i < NUM_THREADS; ++i) {
        threads.emplace_back(
            [&]()
            {
                for (int j = 0; j < TRANSFERS_PER_THREAD; ++j) {
                    transfer(accountA, accountB, 1);
                    transfer(accountB, accountA, 1);
                }
            }
        );
    }

    for (auto& thread : threads) {
        thread.join();
    }

    int a = accountA.getValue();
    int b = accountB.getValue();

    std::cout << "Account A: " << a << "\n";
    std::cout << "Account B: " << b << "\n";
    std::cout << "Total:     " << a + b << "\n";
    std::cout << "Expected:  2000\n";

    if (a + b == 2000) {
        std::cout << "RESULT: PASS\n";
    } else {
        std::cout << "RESULT: FAIL\n";
    }

    g_stats.print("STM STATISTICS (TRANSFER)");
}


// ============================================================================
// Example 4: Separation of Program Errors vs Transaction Conflicts
// ============================================================================
// Demonstrates that when application logic throws a business rule exception
// (such as "Insufficient funds"):
//   1. The transaction safely aborts and releases any partial locks.
//   2. The exception is rethrown to the caller immediately.
//   3. The STM does NOT waste time retrying an unrecoverable domain error.

void applicationErrorExample()
{
    std::cout << "\n===== APPLICATION ERROR TEST =====\n";

    SharedObject account(50);
    SharedObject recipient(0);

    try {
        // Attempt to transfer 100 from an account with only 50
        transfer(account, recipient, 100);
        std::cout << "UNEXPECTED: Transfer succeeded but should have failed!\n";
    }
    catch (const std::runtime_error& e) {
        std::cout << "Caught expected application error: \"" << e.what() << "\"\n";
        std::cout << "Account balance preserved: " << account.getValue() << "\n";
        std::cout << "RESULT: PASS\n";
    }
}


// ============================================================================
// MAIN ENTRY POINT
// ============================================================================

int main()
{
    // 1. Basic sanity test
    basicExample();

    // 2. High-contention concurrent counter benchmark
    counterExample();

    // 3. Multi-object atomic transfer benchmark
    transferExample();

    // 4. Exception propagation & error handling test
    applicationErrorExample();

    return 0;
}