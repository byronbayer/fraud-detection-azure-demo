// =============================================================================
// Neo4j Constraints & Indexes — Fraud Detection Graph
// =============================================================================
// Run once after database creation, before loading data.
// Execute via: cat constraints.cypher | cypher-shell -u neo4j -p fraud-demo-2026
// Or paste into Neo4j Browser at http://localhost:7474
// =============================================================================

// -- Uniqueness constraints (also create indexes) --

CREATE CONSTRAINT customer_id_unique IF NOT EXISTS
FOR (c:Customer) REQUIRE c.customer_id IS UNIQUE;

CREATE CONSTRAINT account_id_unique IF NOT EXISTS
FOR (a:Account) REQUIRE a.account_id IS UNIQUE;

CREATE CONSTRAINT merchant_id_unique IF NOT EXISTS
FOR (m:Merchant) REQUIRE m.merchant_id IS UNIQUE;

// -- Composite indexes for query performance --

CREATE INDEX customer_country IF NOT EXISTS
FOR (c:Customer) ON (c.country);

CREATE INDEX customer_risk IF NOT EXISTS
FOR (c:Customer) ON (c.risk_score);

CREATE INDEX account_status IF NOT EXISTS
FOR (a:Account) ON (a.status);

CREATE INDEX account_type IF NOT EXISTS
FOR (a:Account) ON (a.account_type);

CREATE INDEX merchant_category IF NOT EXISTS
FOR (m:Merchant) ON (m.category);

CREATE INDEX merchant_risk_tier IF NOT EXISTS
FOR (m:Merchant) ON (m.risk_tier);

CREATE INDEX merchant_country IF NOT EXISTS
FOR (m:Merchant) ON (m.country);
