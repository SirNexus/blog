---
slug: cassandra-sai-indexes
title: "Cassandra SAI Indexes: When They Work and When They Don't"
authors: aidancarson
tags: [Cassandra, SAI, Databases, Performance, SPIRE]
toc_min_heading_level: 2
toc_max_heading_level: 5
---

# Cassandra SAI Indexes: When They Work and When They Don't

Storage-Attached Indexing (SAI) is Cassandra's modern approach to secondary indexing. It promises efficient queries on non-partition-key columns without the scaling problems of legacy secondary indexes. But SAI has boundaries — and when your query crosses them, Cassandra silently falls back to a full table scan regardless of whether the index exists.

This post walks through how SAI works under the hood, when it can be used, and when Cassandra ignores it entirely — even when your WHERE clause references an SAI-indexed column.

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

When a query uses an SAI-indexed column:

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

This is where things get subtle. You can have a perfectly valid SAI index on a column, reference that column in your WHERE clause, and Cassandra will still ignore the index and perform a brute-force scan.

### Case 1: DISTINCT Queries

```sql
SELECT DISTINCT partition_key, static_col FROM my_table WHERE indexed_col > ?
ALLOW FILTERING
```

`DISTINCT` tells Cassandra to return one result per partition key. Cassandra implements this as a partition-skipping scan — it walks partition boundaries, reads the first row (or static columns), and jumps to the next partition.

SAI operates at the row level. It answers: "which rows in this SSTable match the predicate?" But DISTINCT operates at the partition level: "give me one result per partition." These are different execution strategies in Cassandra's query engine, and the planner does not compose them.

What actually happens:
1. Cassandra walks through every partition (the DISTINCT scan)
2. At each partition, it reads the relevant column from disk
3. It applies the WHERE predicate as a post-read filter
4. Rows that don't match are discarded after being read

The SAI index is never consulted. The predicate is pure post-filtering. Hence `ALLOW FILTERING` is required.

### Case 2: Predicates on Static Columns

```sql
CREATE TABLE my_table (
    pk text,
    ck text,
    static_col bigint STATIC,
    PRIMARY KEY (pk, ck)
);
CREATE INDEX ON my_table (static_col) USING 'sai';

SELECT * FROM my_table WHERE static_col > 1000 ALLOW FILTERING;
```

Static columns exist once per partition, but SAI indexes point to rows within SSTables. There's an impedance mismatch: the index maps values to row-level positions, but a static column doesn't correspond to any specific clustering row — it belongs to the partition as a whole.

When you filter on a static column, Cassandra reverts to scanning partitions and checking the static value after reading, rather than using the index to skip non-matching partitions.

### Case 3: Low Selectivity (Predicate Matches Most Data)

```sql
-- If 95% of nodes have cert_not_after in the future:
SELECT * FROM attested_node_entries WHERE cert_not_after > ?
```

When a predicate matches the vast majority of rows, Cassandra's query planner may skip the index entirely. Using an index involves: traversing the index structure, building a list of matching row positions, then performing random I/O to read those rows from the SSTable data file.

If 95% of rows match, the random I/O from index lookups is more expensive than a sequential scan through the data file. The planner recognizes this and falls back to a full scan with post-filtering. The cutoff is heuristic-based and depends on the data distribution.

### Case 4: Queries Requiring Global Ordering

```sql
SELECT * FROM events WHERE status = 'pending' ORDER BY created_at DESC
```

SAI does not maintain global sort order. It finds matching rows within each SSTable in token order (partition hash order), not in the order of any particular column. If your query requires results sorted by a non-clustering column, the index cannot provide sorted output — results must be collected and sorted after the fact.

### Case 5: The Combination Problem (Real-World Example)

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

This query hits three problems simultaneously:
1. `DISTINCT` — uses the partition-skipping execution path, incompatible with index lookups
2. `cert_not_after` is `STATIC` — impedance mismatch with row-level index
3. Most nodes are non-expired — low selectivity, index wouldn't help much even if it could be used

The result: the SAI index on `cert_not_after` is completely dormant for this query. Cassandra walks every partition in the table, reads the static `cert_not_after` value, checks `> ?`, and either returns or discards it. At scale (large number of attested nodes), this averages 1.91 seconds and frequently times out at 5 seconds.

## Understanding ALLOW FILTERING as a Signal

`ALLOW FILTERING` is not just a syntax requirement — it's a diagnostic signal. When Cassandra requires it, it's telling you:

"I cannot serve this query efficiently. I will read data first and apply the predicate after. This will be a full scan with post-read filtering."

If your query requires `ALLOW FILTERING`, the SAI index is not being used for that predicate (or Cassandra has determined the index won't help). The presence of both an SAI index on a column and `ALLOW FILTERING` in a query referencing that column is a red flag — it means you're paying for index maintenance (write amplification during flushes and compaction) without gaining any read benefit.

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

SAI is ignored when:
- `DISTINCT` forces a partition-skipping execution path
- The indexed column is `STATIC` (partition-level, not row-level)
- The predicate matches most rows (sequential scan beats random I/O)
- The query combines multiple factors that individually push toward filtering

The takeaway: an SAI index existing on a column does not guarantee it will be used. The query's full execution context — DISTINCT, static columns, selectivity, ordering requirements — determines whether Cassandra can leverage the index or falls back to brute-force filtering. When `ALLOW FILTERING` appears in your query, that's Cassandra telling you the index isn't helping.
