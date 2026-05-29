---
slug: cassandra-sai-indexes
title: "Cassandra SAI Indexes: When They Work and When They Don't"
authors: aidancarson
tags: [Cassandra, SAI, Databases, Performance, SPIRE]
toc_min_heading_level: 2
toc_max_heading_level: 5
---

# Cassandra SAI Indexes: When They Work and When They Don't

Storage-Attached Indexing (SAI) is Cassandra's modern approach to secondary indexing. It promises efficient queries on non-partition-key columns without the scaling problems of legacy secondary indexes. But SAI has boundaries — and when your query crosses them, Cassandra can end up performing slower than if the index didn't exist at all.

This post walks through how SAI works under the hood, when it can be used, and when Cassandra bypasses it entirely — even when your WHERE clause references a SAI-indexed column.

<!-- truncate -->

## Background: How Cassandra Organizes Data

Before understanding SAI, you need to understand how Cassandra stores data.

### Partitions

Every Cassandra table has a PRIMARY KEY composed of a partition key and optional clustering columns:

```sql
PRIMARY KEY (partition_key, clustering_col1, clustering_col2)
```

The partition key is hashed to determine which node stores the data. All rows sharing the same partition key are co-located on the same node(s) and stored contiguously on disk.

### Clustering Columns

Clustering columns determine the sort order of rows within a partition. This enables efficient range scans within a single partition:

```sql
-- Fast: reads a contiguous slice within one partition
SELECT * FROM events WHERE user_id = 'abc' AND timestamp > '2026-01-01'
```

### SSTables

On disk, data lives in SSTables (Sorted String Tables) — immutable, sorted files. When data is written, it goes to an in-memory memtable first, which periodically flushes to disk as a new SSTable. Compaction later merges multiple SSTables into consolidated ones.

Each SSTable contains:
- The actual row data (sorted by partition key, then clustering columns)
- A partition index (partition key to file offset mapping)
- A Bloom filter (to quickly rule out "this partition is not in this SSTable")

### The Problem SAI Solves

Without indexes, querying by a non-partition-key column requires a full table scan. Every node must read every SSTable and check every row. Cassandra refuses to do this unless you explicitly add `ALLOW FILTERING` to your query.

## How SAI Works

SAI creates index structures that are attached directly to SSTables. This is the key architectural decision that differentiates it from legacy secondary indexes (which maintained separate, globally partitioned index tables).

### Per-SSTable Index Segments

When a new SSTable is flushed to disk, SAI builds an index segment alongside it. The index segment maps column values to row positions within that SSTable:

```
SSTable-1:
  Data:  [row1, row2, row3, row4, row5]
  SAI:   status="active" → [row1, row3, row5]
         status="expired" → [row2, row4]
```

For numeric columns, SAI uses tree structures (kd-trees or tries) that support range lookups. For text columns, it uses trie-based structures optimized for equality and prefix matching.

### Query Execution With SAI

When a query uses a SAI-indexed column:

1. The coordinator sends the query to all nodes that might have relevant data
2. Each node checks its local SAI index segments (one per SSTable)
3. The index narrows which rows to read from the SSTable data files
4. Only matching rows are read and returned

The critical benefit: data that doesn't match the predicate is never read from disk. The index acts as a filter before I/O.

### Compaction Integration

When SSTables are compacted (merged), their corresponding SAI index segments are also merged into new consolidated index segments. This happens automatically — no manual index rebuilds needed.

## When SAI Indexes Work Well

To illustrate the examples below, here's a simple table with SAI indexes applied to several columns:

```sql
CREATE TABLE attested_node_entries (
    spiffe_id varchar,              -- PARTITION KEY: determines which node stores this data
    selector_type_value varchar,    -- CLUSTERING KEY: sorts rows within a partition
    serial_number varchar STATIC,   -- one value per partition (per spiffe_id)
    banned boolean STATIC,
    cert_not_after bigint STATIC,
    attestation_type varchar STATIC,
    index_terms set<text> STATIC,
    PRIMARY KEY (spiffe_id, selector_type_value)
);

-- SAI indexes on non-primary-key columns:
CREATE INDEX ON attested_node_entries (serial_number) USING 'sai';
CREATE INDEX ON attested_node_entries (banned) USING 'sai';
CREATE INDEX ON attested_node_entries (cert_not_after) USING 'sai';
CREATE INDEX ON attested_node_entries (index_terms) USING 'sai';
```

The PRIMARY KEY controls data placement and organization — `spiffe_id` determines which node stores the partition, `selector_type_value` determines row ordering within that partition. The SAI indexes are additional structures built alongside SSTables that allow queries to filter on `serial_number`, `banned`, `cert_not_after`, and `index_terms` without scanning every row.

### Equality Predicates Without a Partition Key

```sql
SELECT * FROM attested_node_entries WHERE serial_number = 'abc123'
```

Each node checks its local SAI index for `serial_number = 'abc123'`, finds which rows match in each SSTable, and reads only those rows. This is a scatter-gather to all nodes, but each node does minimal I/O.

### Equality Combined With a Partition Key

```sql
SELECT * FROM attested_node_entries
WHERE spiffe_id = 'spiffe://example/node-1' AND banned = true
```

Cassandra narrows to the specific node(s) holding this partition, then uses the SAI index within those nodes' SSTables to find matching rows. Very efficient.

### Range Predicates (When Selective)

```sql
SELECT * FROM attested_node_entries WHERE cert_not_after > 1748450000 AND cert_not_after < 1748460000
```

SAI's numeric index structures natively support range queries. The tree is traversed to find all entries within the range, and only those rows are read. This works well when the range is selective — filtering out most of the data.

### Collection Element Lookups

```sql
SELECT * FROM attested_node_entries WHERE index_terms CONTAINS 'some-term'
```

SAI indexes on sets, lists, and maps allow efficient lookups on individual collection elements.

### Conjunction of Multiple Indexed Columns

```sql
SELECT * FROM attested_node_entries WHERE banned = false AND serial_number = 'xyz'
```

SAI can intersect results from multiple index segments within each SSTable, narrowing the result set before any data rows are read.

## When SAI Indexes Don't Work (Even When They Exist)

This is where things get subtle. You can have a perfectly valid SAI index on a column, reference that column in your WHERE clause, and Cassandra will still bypass the index and perform a brute-force scan — or use the index in a way that makes performance worse.

### Case 1: DISTINCT Queries

```sql
SELECT DISTINCT partition_key, static_col FROM my_table WHERE indexed_col > ?
ALLOW FILTERING
```

`DISTINCT` tells Cassandra to return one result per partition key. Without a WHERE clause, Cassandra implements this as a partition-skipping scan — it walks partition boundaries efficiently, reading one result per partition.

But when you add a WHERE clause on a SAI-indexed column, the SAI index **is still consulted**. Cassandra uses the index scan path: it fans out to all token ranges and performs per-range index lookups. The DISTINCT deduplication is then applied on top of the index scan results.

This is the worst of both worlds:
1. SAI forces a parallel fan-out to every token range (expensive coordination overhead)
2. Per range, the replica performs index lookups: opening index segments, traversing trees, reading posting lists
3. DISTINCT then deduplicates the results at the partition level
4. You pay the full cost of the index scan without any selectivity benefit — DISTINCT needs partition-level results anyway

The SAI index is engaged but counterproductive. The index machinery adds overhead per range without reducing the amount of data that needs to be examined. `ALLOW FILTERING` is required because Cassandra recognizes this combination cannot be served efficiently.

### Case 2: Low Selectivity (Predicate Matches Most Data)

```sql
-- If 95% of nodes have cert_not_after in the future:
SELECT * FROM attested_node_entries WHERE cert_not_after > ?
```

When a predicate matches the vast majority of rows, SAI will still use the index — Cassandra does not have a cost-based optimizer that decides to skip it. But the performance can be worse than a sequential scan would have been.

Using an index involves: traversing the index structure, building a list of matching row positions, then performing random I/O to read those rows from the SSTable data file. If 95% of rows match, you're paying the overhead of index traversal plus random I/O to read nearly every row anyway. A sequential scan through the data file would have been cheaper, but Cassandra doesn't make that trade-off for you.

This isn't a case where the index is ignored — it's a case where having the index actively hurts read performance.

### Real-World Example

Here's the query that prompted this post — from a SPIRE server's Cassandra datastore plugin:

```sql
SELECT DISTINCT spiffe_id, selector_type_value_full
FROM attested_node_entries
WHERE cert_not_after > ?
ALLOW FILTERING
```

The table schema:

```sql
CREATE TABLE attested_node_entries (
    spiffe_id varchar,
    selector_type_value varchar,
    cert_not_after bigint STATIC,
    selector_type_value_full frozen<list<text>> STATIC,
    PRIMARY KEY (spiffe_id, selector_type_value)
);
CREATE INDEX cert_not_after_idx ON attested_node_entries (cert_not_after) USING 'sai';
```

This query hits multiple problems simultaneously:
1. `DISTINCT` — the index scan path is engaged but counterproductive, adding coordination overhead without reducing work
2. Most nodes are non-expired — low selectivity, index doesn't narrow results even where it is consulted

The result: the SAI index on `cert_not_after` is actively harmful for this query. Cassandra fans out to all 145 token ranges, performs per-range index lookups, then deduplicates at the partition level for DISTINCT. The index adds per-range overhead (index segment traversal, posting list reads) without filtering out any meaningful amount of data. At scale (large number of attested nodes), this averages 1.91 seconds and frequently times out at 5 seconds.

The fix was to remove the `WHERE` clause and filter in the application instead:

```sql
SELECT DISTINCT spiffe_id, selector_type_value_full, cert_not_after
FROM attested_node_entries
```

By dropping the WHERE clause and `ALLOW FILTERING`, Cassandra no longer engages the SAI index. The query becomes a pure DISTINCT partition-skipping scan — walking partition boundaries efficiently without per-range index lookups. The application receives all partitions and filters `cert_not_after > ?` in memory. The result: 203ms for the first page, 34ms for subsequent pages, ~271ms total — down from 1.91 seconds average with frequent 5-second timeouts.

## Understanding ALLOW FILTERING as a Signal

`ALLOW FILTERING` is not just a syntax requirement — it's a diagnostic signal. When Cassandra requires it, it's telling you:

"At least one predicate in this query cannot be satisfied by an index and will require post-read filtering."

This does not mean all indexes are bypassed. In a query with multiple predicates, SAI can still narrow results using indexed columns before post-filtering on the unindexed ones. For example:

```sql
-- SAI index exists on col1, but NOT on col2:
SELECT * FROM my_table WHERE col1 = 'hello' AND col2 < 1000 ALLOW FILTERING;
```

Here, SAI uses the index on `col1` to find matching rows, then post-filters on `col2`. The `ALLOW FILTERING` is required because of `col2`, not because the index on `col1` is being ignored.

## Alternatives When SAI Can't Help

When your query pattern fundamentally conflicts with SAI's execution model, consider:

### Materialized Views or Denormalized Tables

Create a table whose partition key aligns with your query:

```sql
CREATE TABLE nodes_by_expiry_bucket (
    expiry_bucket int,          -- e.g., day or hour bucket
    spiffe_id varchar,
    selector_type_value_full frozen<list<text>>,
    cert_not_after bigint,
    PRIMARY KEY (expiry_bucket, cert_not_after, spiffe_id)
);
```

Now "find all non-expired nodes" becomes a query on a known set of partition keys (recent time buckets), using the clustering key for range filtering.

### Application-Level Caching

If the query runs 4,000 times per hour but the underlying data changes infrequently (node attestation is relatively stable), cache the result in the application layer with a TTL. A stale-by-seconds result is often acceptable for "list all valid nodes."

### Restructuring the Query

If possible, break the query into two steps:
1. Maintain an application-managed set of "known active node spiffe_ids"
2. Query individual partitions by partition key when you need their selector data

This trades one expensive scatter-gather for many cheap single-partition lookups.

## Summary

SAI is effective when:
- The query can use index results at the row level
- The predicate is selective (filters out a meaningful portion of data)
- The execution path is a standard read (not DISTINCT or aggregation)

SAI is used but counterproductive when:
- `DISTINCT` forces partition-level deduplication on top of the index scan, adding coordination overhead without reducing work
- The predicate matches most rows (random I/O through the index is worse than a sequential scan would have been)

The takeaway: Cassandra does not have a cost-based optimizer. It won't intelligently decide to skip a SAI index when it would be cheaper to scan. If a WHERE clause references a SAI-indexed column, Cassandra will use the index — regardless of whether that helps or hurts performance.
