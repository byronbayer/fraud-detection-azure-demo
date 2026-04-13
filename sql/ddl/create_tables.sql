-- =============================================================================
-- Fraud Detection — PostgreSQL Schema (DDL)
-- =============================================================================
-- Target: Azure PostgreSQL Flexible Server 16
-- Database: fraud_detection
-- Encoding: UTF-8 / en_US.utf8
-- Note: gen_random_uuid() is built into PostgreSQL 13+; no extension needed.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Dimension: Customers
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_customer (
    customer_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(200) NOT NULL,
    email       VARCHAR(255) NOT NULL UNIQUE,
    phone       VARCHAR(20),
    country     VARCHAR(3)   NOT NULL,
    risk_score  DECIMAL(5,2) NOT NULL DEFAULT 0.00,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Dimension: Merchants
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_merchant (
    merchant_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        VARCHAR(200) NOT NULL,
    category    VARCHAR(50)  NOT NULL,
    country     VARCHAR(3)   NOT NULL,
    city        VARCHAR(100),
    risk_tier   VARCHAR(10)  NOT NULL DEFAULT 'medium'
                CHECK (risk_tier IN ('low', 'medium', 'high')),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Dimension: Accounts
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dim_account (
    account_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  UUID        NOT NULL REFERENCES dim_customer (customer_id),
    account_type VARCHAR(20) NOT NULL
                 CHECK (account_type IN ('current', 'savings', 'credit')),
    currency     VARCHAR(3)  NOT NULL DEFAULT 'GBP',
    balance      DECIMAL(15,2) NOT NULL DEFAULT 0.00,
    status       VARCHAR(15) NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active', 'suspended', 'closed')),
    opened_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at    TIMESTAMPTZ
);

-- ---------------------------------------------------------------------------
-- Fact: Transactions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fact_transaction (
    txn_id          UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    from_account_id UUID          NOT NULL REFERENCES dim_account (account_id),
    to_account_id   UUID          REFERENCES dim_account (account_id),
    merchant_id     UUID          REFERENCES dim_merchant (merchant_id),
    amount          DECIMAL(15,2) NOT NULL CHECK (amount > 0),
    currency        VARCHAR(3)    NOT NULL DEFAULT 'GBP',
    txn_timestamp   TIMESTAMPTZ   NOT NULL,
    channel         VARCHAR(20)   NOT NULL
                    CHECK (channel IN ('online', 'mobile', 'atm', 'branch', 'pos')),
    txn_type        VARCHAR(20)   NOT NULL
                    CHECK (txn_type IN ('payment', 'transfer', 'withdrawal', 'deposit')),
    is_flagged      BOOLEAN       NOT NULL DEFAULT false,
    flag_reason     VARCHAR(100)
);

-- ---------------------------------------------------------------------------
-- Indexes for fraud analysis queries
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_fact_txn_timestamp
    ON fact_transaction (txn_timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_fact_txn_from_account
    ON fact_transaction (from_account_id);

CREATE INDEX IF NOT EXISTS idx_fact_txn_to_account
    ON fact_transaction (to_account_id);

CREATE INDEX IF NOT EXISTS idx_fact_txn_merchant
    ON fact_transaction (merchant_id);

CREATE INDEX IF NOT EXISTS idx_fact_txn_flagged
    ON fact_transaction (is_flagged) WHERE is_flagged = true;

CREATE INDEX IF NOT EXISTS idx_dim_account_customer
    ON dim_account (customer_id);

CREATE INDEX IF NOT EXISTS idx_dim_customer_risk
    ON dim_customer (risk_score DESC);
