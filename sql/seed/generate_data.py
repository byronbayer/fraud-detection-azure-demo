#!/usr/bin/env python3
"""
Fraud Detection — Sample Data Generator
========================================
Generates ~500 customers, ~200 merchants, ~800 accounts, and ~10 000 transactions
with deliberate fraud patterns seeded for demonstration purposes.

Fraud patterns embedded:
  1. Circular transaction rings   (A→B→C→A)
  2. Velocity spikes              (>10 txns from one account within 1 hour)
  3. Structuring                  (amounts just below £10 000 threshold)
  4. New-account exploitation     (high-value txns within 48h of opening)
  5. Cross-border anomalies       (domestic customer → high-risk country merchant)
  6. High-velocity pairs          (5-15 repeated transfers between same account pair)

Usage:
    pip install psycopg[binary] faker
    python generate_data.py                          # uses DATABASE_URL env var
    python generate_data.py --host <fqdn> --password <pw>
"""

import argparse
import os
import random
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import psycopg
from faker import Faker

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CUSTOMER_COUNT = 500
MERCHANT_COUNT = 200
ACCOUNTS_PER_CUSTOMER = (1, 3)  # min, max
NORMAL_TXN_COUNT = 9_000
SEED = 42

CHANNELS = ["online", "mobile", "atm", "branch", "pos"]
ACCOUNT_TYPES = ["current", "savings", "credit"]
CURRENCIES = ["GBP", "USD", "EUR"]
MERCHANT_CATEGORIES = [
    "retail", "grocery", "travel", "entertainment", "gambling",
    "electronics", "restaurant", "fuel", "healthcare", "utilities",
]
HIGH_RISK_COUNTRIES = ["NGA", "RUS", "BRA", "VNM", "UKR"]
NORMAL_COUNTRIES = ["GBR", "USA", "DEU", "FRA", "IRL", "NLD", "ESP", "ITA"]

fake = Faker("en_GB")
Faker.seed(SEED)
random.seed(SEED)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def ts(dt: datetime) -> str:
    """Format datetime for PostgreSQL."""
    return dt.strftime("%Y-%m-%d %H:%M:%S+00")


def rand_amount(low: float = 5.0, high: float = 2000.0) -> float:
    return round(random.uniform(low, high), 2)


# ---------------------------------------------------------------------------
# Data Generation
# ---------------------------------------------------------------------------

def generate_customers() -> list[dict[str, Any]]:
    customers = []
    for _ in range(CUSTOMER_COUNT):
        customers.append({
            "customer_id": str(uuid.uuid4()),
            "name": fake.name(),
            "email": fake.unique.email(),
            "phone": fake.phone_number()[:20],
            "country": random.choice(NORMAL_COUNTRIES),
            "risk_score": round(random.uniform(0, 30), 2),  # mostly low risk
            "created_at": fake.date_time_between(
                start_date="-2y", end_date="-30d", tzinfo=timezone.utc
            ),
        })
    return customers


def generate_merchants() -> list[dict[str, Any]]:
    merchants = []
    for _ in range(MERCHANT_COUNT):
        country = random.choice(
            NORMAL_COUNTRIES if random.random() > 0.15 else HIGH_RISK_COUNTRIES
        )
        risk_tier = "high" if country in HIGH_RISK_COUNTRIES else random.choice(["low", "medium"])
        merchants.append({
            "merchant_id": str(uuid.uuid4()),
            "name": fake.company(),
            "category": random.choice(MERCHANT_CATEGORIES),
            "country": country,
            "city": fake.city(),
            "risk_tier": risk_tier,
        })
    return merchants


def generate_accounts(customers: list[dict]) -> list[dict[str, Any]]:
    accounts = []
    for cust in customers:
        n = random.randint(*ACCOUNTS_PER_CUSTOMER)
        for _ in range(n):
            opened = cust["created_at"] + timedelta(days=random.randint(0, 60))
            accounts.append({
                "account_id": str(uuid.uuid4()),
                "customer_id": cust["customer_id"],
                "account_type": random.choice(ACCOUNT_TYPES),
                "currency": "GBP" if random.random() > 0.2 else random.choice(CURRENCIES),
                "balance": round(random.uniform(100, 50_000), 2),
                "status": "active",
                "opened_at": opened,
            })
    return accounts


def generate_normal_transactions(
    accounts: list[dict], merchants: list[dict]
) -> list[dict[str, Any]]:
    """Generate legitimate-looking transactions."""
    txns = []
    now = datetime.now(timezone.utc)
    for _ in range(NORMAL_TXN_COUNT):
        from_acct = random.choice(accounts)
        txn_type = random.choice(["payment", "transfer", "withdrawal"])
        merchant = None
        to_acct = None

        if txn_type == "payment":
            merchant = random.choice(merchants)
        elif txn_type == "transfer":
            to_acct = random.choice(accounts)
            # avoid self-transfer
            while to_acct["account_id"] == from_acct["account_id"]:
                to_acct = random.choice(accounts)

        txns.append({
            "txn_id": str(uuid.uuid4()),
            "from_account_id": from_acct["account_id"],
            "to_account_id": to_acct["account_id"] if to_acct else None,
            "merchant_id": merchant["merchant_id"] if merchant else None,
            "amount": rand_amount(),
            "currency": from_acct["currency"],
            "txn_timestamp": fake.date_time_between(
                start_date="-90d", end_date="now", tzinfo=timezone.utc
            ),
            "channel": random.choice(CHANNELS),
            "txn_type": txn_type,
            "is_flagged": False,
            "flag_reason": None,
        })
    return txns


# ---------------------------------------------------------------------------
# Fraud Pattern Generators
# ---------------------------------------------------------------------------

def generate_circular_rings(accounts: list[dict]) -> list[dict[str, Any]]:
    """Pattern 1: Circular money flow A→B→C→A (3-5 rings of length 3-5)."""
    txns = []
    num_rings = random.randint(3, 5)
    for _ in range(num_rings):
        ring_len = random.randint(3, 5)
        ring_accounts = random.sample(accounts, ring_len)
        base_time = fake.date_time_between(
            start_date="-30d", end_date="-1d", tzinfo=timezone.utc
        )
        base_amount = rand_amount(5_000, 25_000)

        for i in range(ring_len):
            from_acct = ring_accounts[i]
            to_acct = ring_accounts[(i + 1) % ring_len]
            txns.append({
                "txn_id": str(uuid.uuid4()),
                "from_account_id": from_acct["account_id"],
                "to_account_id": to_acct["account_id"],
                "merchant_id": None,
                "amount": round(base_amount + random.uniform(-100, 100), 2),
                "currency": "GBP",
                "txn_timestamp": base_time + timedelta(hours=i * 2),
                "channel": "online",
                "txn_type": "transfer",
                "is_flagged": True,
                "flag_reason": "circular_ring",
            })
    return txns


def generate_velocity_spikes(accounts: list[dict], merchants: list[dict]) -> list[dict[str, Any]]:
    """Pattern 2: >10 transactions from one account within 1 hour."""
    txns = []
    spike_accounts = random.sample(accounts, random.randint(8, 12))
    for acct in spike_accounts:
        base_time = fake.date_time_between(
            start_date="-14d", end_date="-1d", tzinfo=timezone.utc
        )
        n_txns = random.randint(11, 20)
        for j in range(n_txns):
            txns.append({
                "txn_id": str(uuid.uuid4()),
                "from_account_id": acct["account_id"],
                "to_account_id": None,
                "merchant_id": random.choice(merchants)["merchant_id"],
                "amount": rand_amount(50, 500),
                "currency": acct["currency"],
                "txn_timestamp": base_time + timedelta(minutes=random.randint(0, 55)),
                "channel": random.choice(["online", "mobile"]),
                "txn_type": "payment",
                "is_flagged": True,
                "flag_reason": "velocity_spike",
            })
    return txns


def generate_structuring(accounts: list[dict], merchants: list[dict]) -> list[dict[str, Any]]:
    """Pattern 3: Multiple transactions just below £10 000 reporting threshold."""
    txns = []
    struct_accounts = random.sample(accounts, random.randint(5, 8))
    for acct in struct_accounts:
        base_time = fake.date_time_between(
            start_date="-21d", end_date="-2d", tzinfo=timezone.utc
        )
        n_txns = random.randint(3, 6)
        for j in range(n_txns):
            amount = round(random.uniform(9_500, 9_999), 2)  # just under £10k
            txns.append({
                "txn_id": str(uuid.uuid4()),
                "from_account_id": acct["account_id"],
                "to_account_id": None,
                "merchant_id": random.choice(merchants)["merchant_id"],
                "amount": amount,
                "currency": "GBP",
                "txn_timestamp": base_time + timedelta(days=j, hours=random.randint(0, 12)),
                "channel": "branch",
                "txn_type": "payment",
                "is_flagged": True,
                "flag_reason": "structuring",
            })
    return txns


def generate_new_account_exploitation(
    customers: list[dict], accounts: list[dict], merchants: list[dict]
) -> list[dict[str, Any]]:
    """Pattern 4: High-value transactions within 48h of account opening."""
    txns = []
    # Create some brand-new accounts
    new_accounts = []
    selected = random.sample(customers, random.randint(10, 15))
    for cust in selected:
        opened = datetime.now(timezone.utc) - timedelta(days=random.randint(1, 5))
        acct = {
            "account_id": str(uuid.uuid4()),
            "customer_id": cust["customer_id"],
            "account_type": "current",
            "currency": "GBP",
            "balance": round(random.uniform(0, 500), 2),
            "status": "active",
            "opened_at": opened,
        }
        new_accounts.append(acct)
        # 2-4 high-value txns within 48h
        for _ in range(random.randint(2, 4)):
            txns.append({
                "txn_id": str(uuid.uuid4()),
                "from_account_id": acct["account_id"],
                "to_account_id": None,
                "merchant_id": random.choice(merchants)["merchant_id"],
                "amount": rand_amount(3_000, 15_000),
                "currency": "GBP",
                "txn_timestamp": opened + timedelta(hours=random.randint(1, 47)),
                "channel": "online",
                "txn_type": "payment",
                "is_flagged": True,
                "flag_reason": "new_account_exploitation",
            })
    return txns, new_accounts


def generate_high_velocity_pairs(accounts: list[dict]) -> list[dict[str, Any]]:
    """Pattern 6: Repeated transfers between the same account pairs (layering)."""
    txns = []
    num_pairs = random.randint(6, 10)
    for _ in range(num_pairs):
        pair = random.sample(accounts, 2)
        from_acct, to_acct = pair[0], pair[1]
        base_time = fake.date_time_between(
            start_date="-30d", end_date="-2d", tzinfo=timezone.utc
        )
        n_txns = random.randint(5, 15)
        base_amount = rand_amount(500, 5_000)
        for j in range(n_txns):
            txns.append({
                "txn_id": str(uuid.uuid4()),
                "from_account_id": from_acct["account_id"],
                "to_account_id": to_acct["account_id"],
                "merchant_id": None,
                "amount": round(base_amount + random.uniform(-200, 200), 2),
                "currency": "GBP",
                "txn_timestamp": base_time + timedelta(
                    days=j // 3, hours=random.randint(0, 8)
                ),
                "channel": random.choice(["online", "mobile"]),
                "txn_type": "transfer",
                "is_flagged": True,
                "flag_reason": "high_velocity_pair",
            })
    return txns


def generate_cross_border(
    accounts: list[dict], merchants: list[dict], customers: list[dict]
) -> list[dict[str, Any]]:
    """Pattern 5: Domestic customers transacting with high-risk country merchants."""
    txns = []
    hr_merchants = [m for m in merchants if m["country"] in HIGH_RISK_COUNTRIES]
    if not hr_merchants:
        return txns

    domestic_customers = [c for c in customers if c["country"] == "GBR"]
    domestic_account_ids = {
        a["account_id"]: a
        for a in accounts
        if a["customer_id"] in {c["customer_id"] for c in domestic_customers}
    }
    sample_accounts = random.sample(
        list(domestic_account_ids.values()),
        min(20, len(domestic_account_ids)),
    )
    for acct in sample_accounts:
        txns.append({
            "txn_id": str(uuid.uuid4()),
            "from_account_id": acct["account_id"],
            "to_account_id": None,
            "merchant_id": random.choice(hr_merchants)["merchant_id"],
            "amount": rand_amount(500, 8_000),
            "currency": "GBP",
            "txn_timestamp": fake.date_time_between(
                start_date="-30d", end_date="-1d", tzinfo=timezone.utc
            ),
            "channel": "online",
            "txn_type": "payment",
            "is_flagged": True,
            "flag_reason": "cross_border_anomaly",
        })
    return txns


# ---------------------------------------------------------------------------
# Database Loading
# ---------------------------------------------------------------------------

def get_connection_string(args: argparse.Namespace) -> str:
    """Build connection string from args or environment."""
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    return (
        f"host={args.host} port={args.port} dbname={args.dbname} "
        f"user={args.user} password={args.password} sslmode=require"
    )


def load_data(conninfo: str, customers, merchants, accounts, transactions):
    """Insert all generated data into PostgreSQL using batch executemany."""
    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            # Clear existing data (idempotent re-runs)
            cur.execute("TRUNCATE fact_transaction, dim_account, dim_merchant, dim_customer CASCADE")

            # -- Customers --
            print(f"  Loading {len(customers)} customers...")
            cur.executemany(
                """INSERT INTO dim_customer
                   (customer_id, name, email, phone, country, risk_score, created_at, updated_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
                [(c["customer_id"], c["name"], c["email"], c["phone"],
                  c["country"], c["risk_score"], c["created_at"], c["created_at"])
                 for c in customers],
            )

            # -- Merchants --
            print(f"  Loading {len(merchants)} merchants...")
            cur.executemany(
                """INSERT INTO dim_merchant
                   (merchant_id, name, category, country, city, risk_tier)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                [(m["merchant_id"], m["name"], m["category"],
                  m["country"], m["city"], m["risk_tier"])
                 for m in merchants],
            )

            # -- Accounts --
            print(f"  Loading {len(accounts)} accounts...")
            cur.executemany(
                """INSERT INTO dim_account
                   (account_id, customer_id, account_type, currency, balance, status, opened_at)
                   VALUES (%s, %s, %s, %s, %s, %s, %s)""",
                [(a["account_id"], a["customer_id"], a["account_type"],
                  a["currency"], a["balance"], a["status"], a["opened_at"])
                 for a in accounts],
            )

            # -- Transactions --
            print(f"  Loading {len(transactions)} transactions...")
            cur.executemany(
                """INSERT INTO fact_transaction
                   (txn_id, from_account_id, to_account_id, merchant_id,
                    amount, currency, txn_timestamp, channel, txn_type,
                    is_flagged, flag_reason)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                [(t["txn_id"], t["from_account_id"], t["to_account_id"],
                  t["merchant_id"], t["amount"], t["currency"],
                  t["txn_timestamp"], t["channel"], t["txn_type"],
                  t["is_flagged"], t["flag_reason"])
                 for t in transactions],
            )

        conn.commit()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate fraud detection sample data")
    parser.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("PGPORT", "5432")))
    parser.add_argument("--dbname", default=os.environ.get("PGDATABASE", "fraud_detection"))
    parser.add_argument("--user", default=os.environ.get("PGUSER", "pgadmin"))
    parser.add_argument("--password", default=os.environ.get("PGPASSWORD", ""))
    args = parser.parse_args()

    print("=== Fraud Detection Data Generator ===\n")

    # Generate base data
    print("[1/7] Generating customers...")
    customers = generate_customers()

    print("[2/7] Generating merchants...")
    merchants = generate_merchants()

    print("[3/7] Generating accounts...")
    accounts = generate_accounts(customers)

    print("[4/7] Generating normal transactions...")
    transactions = generate_normal_transactions(accounts, merchants)

    # Generate fraud patterns
    print("[5/7] Generating fraud patterns...")
    circular = generate_circular_rings(accounts)
    velocity = generate_velocity_spikes(accounts, merchants)
    structuring = generate_structuring(accounts, merchants)
    new_acct_txns, new_accounts = generate_new_account_exploitation(customers, accounts, merchants)
    cross_border = generate_cross_border(accounts, merchants, customers)
    high_velocity = generate_high_velocity_pairs(accounts)

    # Merge new accounts and all transactions
    accounts.extend(new_accounts)
    transactions.extend(circular)
    transactions.extend(velocity)
    transactions.extend(structuring)
    transactions.extend(new_acct_txns)
    transactions.extend(cross_border)
    transactions.extend(high_velocity)

    # Shuffle transactions for realistic ordering
    random.shuffle(transactions)

    print(f"\n  Summary:")
    print(f"    Customers:    {len(customers):>6}")
    print(f"    Merchants:    {len(merchants):>6}")
    print(f"    Accounts:     {len(accounts):>6}")
    print(f"    Transactions: {len(transactions):>6}")
    print(f"      - Normal:       {NORMAL_TXN_COUNT:>6}")
    print(f"      - Circular:     {len(circular):>6}")
    print(f"      - Velocity:     {len(velocity):>6}")
    print(f"      - Structuring:  {len(structuring):>6}")
    print(f"      - New account:  {len(new_acct_txns):>6}")
    print(f"      - Cross-border: {len(cross_border):>6}")
    print(f"      - Hi-velocity:  {len(high_velocity):>6}")

    # Load into database
    print("\n[6/7] Connecting to PostgreSQL...")
    conninfo = get_connection_string(args)
    load_data(conninfo, customers, merchants, accounts, transactions)

    print("\n[7/7] Verifying counts...")
    with psycopg.connect(conninfo) as conn:
        with conn.cursor() as cur:
            for table in ["dim_customer", "dim_merchant", "dim_account", "fact_transaction"]:
                cur.execute(f"SELECT count(*) FROM {table}")  # noqa: S608 — table names are hardcoded
                count = cur.fetchone()[0]
                print(f"    {table}: {count}")
            cur.execute("SELECT count(*) FROM fact_transaction WHERE is_flagged = true")
            flagged = cur.fetchone()[0]
            print(f"    Flagged transactions: {flagged}")
            cur.execute(
                "SELECT flag_reason, count(*) FROM fact_transaction "
                "WHERE is_flagged = true GROUP BY flag_reason ORDER BY count(*) DESC"
            )
            print("    Fraud breakdown:")
            for reason, cnt in cur.fetchall():
                print(f"      {reason}: {cnt}")

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
