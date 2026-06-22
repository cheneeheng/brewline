-- Inventory table (owned by the inventory service) + seed SKUs.
-- Idempotent so the inventory-migrate one-shot can re-run safely.

CREATE TABLE IF NOT EXISTS inventory_items (
    sku           TEXT PRIMARY KEY,
    name          TEXT        NOT NULL,
    available_qty INTEGER     NOT NULL,
    reserved_qty  INTEGER     NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO inventory_items (sku, name, available_qty) VALUES
    ('ESP-001', 'Espresso',        1000),
    ('LAT-001', 'Latte',            800),
    ('CAP-001', 'Cappuccino',       800),
    ('AME-001', 'Americano',        900),
    ('MOC-001', 'Mocha',            600),
    ('FLW-001', 'Flat White',       500),
    ('COL-001', 'Cold Brew',        400),
    ('CHA-001', 'Chai Latte',       300)
ON CONFLICT (sku) DO NOTHING;
