// =============================================================================
// Fraud Detection Cypher Queries
// =============================================================================
// Showcase queries for the fraud detection demo.  Run against the Neo4j
// instance after data has been loaded via the Databricks 04-neo4j-export
// notebook or the direct Python loader.
//
// Browse results at http://localhost:7474
// =============================================================================


// -----------------------------------------------------------------------
// 1. CIRCULAR MONEY FLOW DETECTION
// -----------------------------------------------------------------------
// Identifies rings where money flows A→B→C→…→A, a classic money
// laundering pattern.  Depth 3-5 covers typical circular schemes.
// -----------------------------------------------------------------------

// Depth-3 rings
MATCH path = (a1:Account)-[:TRANSACTED_WITH]->(a2:Account)
             -[:TRANSACTED_WITH]->(a3:Account)
             -[:TRANSACTED_WITH]->(a1)
WHERE a1.account_id < a2.account_id   // avoid duplicate rings
  AND a2.account_id < a3.account_id
RETURN DISTINCT
  a1.account_id AS node_1,
  a2.account_id AS node_2,
  a3.account_id AS node_3,
  reduce(s = 0.0, r IN relationships(path) | s + r.total_amount) AS ring_total_amount,
  reduce(s = 0,   r IN relationships(path) | s + r.txn_count)    AS ring_txn_count
ORDER BY ring_total_amount DESC
LIMIT 20;

// Depth-4 rings
MATCH path = (a1:Account)-[:TRANSACTED_WITH]->(a2:Account)
             -[:TRANSACTED_WITH]->(a3:Account)
             -[:TRANSACTED_WITH]->(a4:Account)
             -[:TRANSACTED_WITH]->(a1)
WHERE a1.account_id < a2.account_id
  AND a2.account_id < a3.account_id
  AND a3.account_id < a4.account_id
RETURN DISTINCT
  a1.account_id AS node_1,
  a2.account_id AS node_2,
  a3.account_id AS node_3,
  a4.account_id AS node_4,
  reduce(s = 0.0, r IN relationships(path) | s + r.total_amount) AS ring_total_amount,
  reduce(s = 0,   r IN relationships(path) | s + r.txn_count)    AS ring_txn_count
ORDER BY ring_total_amount DESC
LIMIT 20;


// -----------------------------------------------------------------------
// 2. HIGH-VELOCITY TRANSACTION PAIRS
// -----------------------------------------------------------------------
// Account pairs with unusually high transaction counts — potential
// money mule or layering behaviour.
// -----------------------------------------------------------------------

MATCH (a1:Account)-[r:TRANSACTED_WITH]->(a2:Account)
WHERE r.txn_count >= 5
RETURN
  a1.account_id AS from_account,
  a2.account_id AS to_account,
  r.txn_count   AS txn_count,
  r.total_amount AS total_amount,
  r.avg_amount   AS avg_amount,
  r.has_flagged_txn AS has_flag
ORDER BY r.txn_count DESC
LIMIT 25;


// -----------------------------------------------------------------------
// 3. FLAGGED TRANSACTION NETWORK
// -----------------------------------------------------------------------
// Expand outward from accounts involved in flagged transactions to
// reveal connected suspicious clusters.
// -----------------------------------------------------------------------

MATCH (a:Account)-[r:TRANSACTED_WITH]->(b:Account)
WHERE r.has_flagged_txn = 1
WITH a, b, r
OPTIONAL MATCH (c:Customer)-[:OWNS]->(a)
OPTIONAL MATCH (d:Customer)-[:OWNS]->(b)
RETURN
  c.name AS sender_customer,
  c.risk_score AS sender_risk,
  a.account_id AS from_account,
  b.account_id AS to_account,
  d.name AS receiver_customer,
  d.risk_score AS receiver_risk,
  r.total_amount AS flagged_edge_amount,
  r.txn_count AS edge_txn_count
ORDER BY r.total_amount DESC
LIMIT 30;


// -----------------------------------------------------------------------
// 4. MULTI-ACCOUNT CUSTOMERS (POTENTIAL STRUCTURING)
// -----------------------------------------------------------------------
// Customers owning many accounts — a prerequisite for structuring
// patterns where funds are split across accounts.
// -----------------------------------------------------------------------

MATCH (c:Customer)-[:OWNS]->(a:Account)
WITH c, collect(a) AS accounts, count(a) AS acct_count
WHERE acct_count >= 3
RETURN
  c.customer_id  AS customer_id,
  c.name         AS customer_name,
  c.risk_score   AS risk_score,
  c.pct_flagged  AS pct_flagged,
  acct_count,
  [a IN accounts | a.account_id] AS account_ids
ORDER BY acct_count DESC, c.pct_flagged DESC
LIMIT 20;


// -----------------------------------------------------------------------
// 5. MONEY MULE IDENTIFICATION (PASS-THROUGH ACCOUNTS)
// -----------------------------------------------------------------------
// Accounts that both receive from AND send to many distinct accounts
// — characteristic of money mule intermediaries.
// -----------------------------------------------------------------------

MATCH (src:Account)-[:TRANSACTED_WITH]->(mule:Account)-[:TRANSACTED_WITH]->(dst:Account)
WITH mule,
     count(DISTINCT src) AS in_degree,
     count(DISTINCT dst) AS out_degree
WHERE in_degree >= 3 AND out_degree >= 3
OPTIONAL MATCH (c:Customer)-[:OWNS]->(mule)
RETURN
  mule.account_id  AS mule_account,
  c.name           AS owner_name,
  c.risk_score     AS owner_risk,
  in_degree,
  out_degree,
  in_degree + out_degree AS total_degree,
  mule.total_amount AS throughput,
  mule.balance_velocity AS velocity
ORDER BY total_degree DESC
LIMIT 20;


// -----------------------------------------------------------------------
// 6. MERCHANT RISK HOTSPOTS
// -----------------------------------------------------------------------
// Highest-risk merchants by flag rate, with connected customer counts.
// Useful for identifying compromised merchant terminals.
// -----------------------------------------------------------------------

MATCH (m:Merchant)
WHERE m.flag_rate > 10.0
RETURN
  m.merchant_id  AS merchant_id,
  m.name         AS merchant_name,
  m.category     AS category,
  m.country      AS country,
  m.risk_tier    AS risk_tier,
  m.total_txns   AS total_txns,
  m.flagged_txns AS flagged_txns,
  m.flag_rate    AS flag_rate_pct,
  m.unique_customers AS unique_customers,
  m.total_volume AS total_volume
ORDER BY m.flag_rate DESC
LIMIT 20;


// -----------------------------------------------------------------------
// 7. CROSS-BORDER TRANSACTION CLUSTERS
// -----------------------------------------------------------------------
// Account pairs where the owning customers are in different countries
// — higher risk for cross-border laundering.
// -----------------------------------------------------------------------

MATCH (c1:Customer)-[:OWNS]->(a1:Account)-[r:TRANSACTED_WITH]->(a2:Account)<-[:OWNS]-(c2:Customer)
WHERE c1.country <> c2.country
RETURN
  c1.name AS sender,
  c1.country AS sender_country,
  a1.account_id AS from_account,
  c2.name AS receiver,
  c2.country AS receiver_country,
  a2.account_id AS to_account,
  r.total_amount AS total_amount,
  r.txn_count AS txn_count,
  r.has_flagged_txn AS has_flag
ORDER BY r.total_amount DESC
LIMIT 25;


// -----------------------------------------------------------------------
// 8. GRAPH STATISTICS OVERVIEW
// -----------------------------------------------------------------------
// Quick summary of the loaded graph for demo verification.
// -----------------------------------------------------------------------

// Node counts
MATCH (n) RETURN labels(n)[0] AS label, count(n) AS count ORDER BY label;

// Relationship counts
MATCH ()-[r]->() RETURN type(r) AS relationship, count(r) AS count ORDER BY relationship;

// Connected component size (approximation)
MATCH (a:Account)
OPTIONAL MATCH (a)-[:TRANSACTED_WITH*1..3]-(connected:Account)
WITH a, count(DISTINCT connected) AS cluster_size
RETURN
  min(cluster_size) AS min_cluster,
  max(cluster_size) AS max_cluster,
  avg(cluster_size) AS avg_cluster,
  count(a) AS total_accounts;
