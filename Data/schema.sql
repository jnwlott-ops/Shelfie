-- Shelfie: sample Postgres schema (pre-design draft, MVP plus phase 2)
-- To be reshaped after the food bank interviews. Targets Supabase (Postgres 15+).
--
-- Design rules (see Requirements/TechStack.txt):
--  1. Every tenant-owned table carries pantry_id. Child tables use composite
--     foreign keys (pantry_id, x_id) so a row can never point at another pantry's data.
--  2. Primary keys are UUIDs, which clients may generate (needed for offline sync later).
--     Mutable tables have updated_at and deleted_at (soft delete).
--  3. Stock changes are events in inventory_transactions (append-only).
--     inventory_batches.quantity_on_hand is a cache that only the ledger trigger may change.
--  4. Every change to a mutable tenant table is written to audit_log.
--
-- Not included yet: row-level security policies, categories/tags tables, donor receipts,
-- visits, wishlists, shifts. In Supabase, also add a foreign key from profiles.id to auth.users(id).


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- Id of the signed-in user. Supabase puts the JWT claims in a session setting.
CREATE FUNCTION current_user_id() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT NULLIF(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
$$;


-- ---------------------------------------------------------------------------
-- Tenants and people
-- ---------------------------------------------------------------------------

CREATE TABLE pantries (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ
);

-- One row per person who can sign in (in Supabase this mirrors auth.users).
CREATE TABLE profiles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email       TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A person can belong to more than one pantry, with a role in each.
CREATE TABLE memberships (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL REFERENCES pantries(id),
  user_id     UUID NOT NULL REFERENCES profiles(id),
  role        TEXT NOT NULL CHECK (role IN ('admin', 'manager', 'volunteer')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  UNIQUE (pantry_id, id),
  UNIQUE (pantry_id, user_id)
);


-- ---------------------------------------------------------------------------
-- Catalog
-- ---------------------------------------------------------------------------

-- Shared cache of barcode lookups (for example Open Food Facts). Not tenant-owned.
-- Pantries copy what they need into products, so edits never touch the cache.
CREATE TABLE product_lookup_cache (
  upc         TEXT PRIMARY KEY,
  source      TEXT NOT NULL,           -- e.g. 'openfoodfacts'
  name        TEXT,
  brand       TEXT,
  category    TEXT,
  payload     JSONB,                   -- raw response, kept for attribution and re-parsing
  fetched_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- A UPC is optional because many donated items have none.
CREATE TABLE products (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id            UUID NOT NULL REFERENCES pantries(id),
  upc                  TEXT,
  name                 TEXT NOT NULL,
  brand                TEXT,
  category             TEXT,                          -- e.g. canned goods, produce, dairy
  unit                 TEXT NOT NULL DEFAULT 'each' CHECK (unit IN ('each', 'lb', 'case')),
  -- Weight of one unit in pounds, for "pounds distributed" reports.
  -- When unit = 'lb' a unit is one pound, so this can stay NULL.
  unit_weight_lb       NUMERIC(10,4) CHECK (unit_weight_lb > 0),
  low_stock_threshold  NUMERIC(12,3) CHECK (low_stock_threshold >= 0),
  source               TEXT NOT NULL DEFAULT 'manual' CHECK (source IN ('lookup', 'manual')),
  photo_path           TEXT,                          -- Supabase Storage path, for items with no barcode
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at           TIMESTAMPTZ,
  UNIQUE (pantry_id, id)
);

-- A soft-deleted product does not block re-adding the same barcode.
CREATE UNIQUE INDEX uq_products_upc ON products (pantry_id, upc)
  WHERE upc IS NOT NULL AND deleted_at IS NULL;

-- Shelf, freezer, back room. Optional but cheap to include.
CREATE TABLE locations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL REFERENCES pantries(id),
  name        TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  UNIQUE (pantry_id, id)
);

CREATE UNIQUE INDEX uq_locations_name ON locations (pantry_id, lower(name)) WHERE deleted_at IS NULL;

-- Minimal donor record so names stay consistent. Receipts and contact details come later.
CREATE TABLE donors (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL REFERENCES pantries(id),
  name        TEXT NOT NULL,
  notes       TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  UNIQUE (pantry_id, id)
);

CREATE UNIQUE INDEX uq_donors_name ON donors (pantry_id, lower(name)) WHERE deleted_at IS NULL;


-- ---------------------------------------------------------------------------
-- Inventory
-- ---------------------------------------------------------------------------

-- A batch = one intake of a product with one best-by date.
-- quantity_on_hand starts at 0 and is changed only by the ledger trigger below.
CREATE TABLE inventory_batches (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id          UUID NOT NULL REFERENCES pantries(id),
  product_id         UUID NOT NULL,
  location_id        UUID,
  donor_id           UUID,
  quantity_received  NUMERIC(12,3) NOT NULL CHECK (quantity_received > 0),
  quantity_on_hand   NUMERIC(12,3) NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
  best_by_date       DATE,
  received_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  received_by        UUID REFERENCES profiles(id),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at         TIMESTAMPTZ,
  UNIQUE (pantry_id, id),
  FOREIGN KEY (pantry_id, product_id)  REFERENCES products  (pantry_id, id),
  FOREIGN KEY (pantry_id, location_id) REFERENCES locations (pantry_id, id),
  FOREIGN KEY (pantry_id, donor_id)    REFERENCES donors    (pantry_id, id)
);

-- Append-only ledger of every stock change. Counts can always be audited and rebuilt.
-- quantity is the signed change: positive adds stock, negative removes it.
CREATE TABLE inventory_transactions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL REFERENCES pantries(id),
  batch_id    UUID NOT NULL,
  type        TEXT NOT NULL CHECK (type IN ('receive', 'distribute', 'discard', 'adjust', 'count')),
  quantity    NUMERIC(12,3) NOT NULL,
  reason      TEXT,
  user_id     UUID REFERENCES profiles(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (pantry_id, batch_id) REFERENCES inventory_batches (pantry_id, id),
  CONSTRAINT txn_sign CHECK (
    (type = 'receive'              AND quantity > 0) OR
    (type IN ('distribute', 'discard') AND quantity < 0) OR
    (type IN ('adjust', 'count')   AND quantity <> 0)
  ),
  -- Waste needs a "why", and so do manual corrections.
  CONSTRAINT txn_reason CHECK (type NOT IN ('discard', 'adjust') OR reason IS NOT NULL)
);

-- Every audited change to a tenant table, including soft and hard deletes.
CREATE TABLE audit_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL,
  user_id     UUID,                    -- NULL for changes made outside a signed-in session
  table_name  TEXT NOT NULL,
  row_id      UUID NOT NULL,
  action      TEXT NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  old_data    JSONB,
  new_data    JSONB,
  changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ---------------------------------------------------------------------------
-- Phase 2: clients and ordering. Keep sensitive data minimal.
-- ---------------------------------------------------------------------------

CREATE TABLE clients (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id       UUID NOT NULL REFERENCES pantries(id),
  display_name    TEXT NOT NULL,
  household_size  INTEGER CHECK (household_size > 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at      TIMESTAMPTZ,
  UNIQUE (pantry_id, id)
);

CREATE TABLE orders (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL REFERENCES pantries(id),
  client_id   UUID NOT NULL,
  status      TEXT NOT NULL DEFAULT 'requested'
              CHECK (status IN ('requested', 'packing', 'ready', 'picked_up', 'cancelled')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ,
  UNIQUE (pantry_id, id),
  FOREIGN KEY (pantry_id, client_id) REFERENCES clients (pantry_id, id)
);

CREATE TABLE order_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pantry_id   UUID NOT NULL REFERENCES pantries(id),
  order_id    UUID NOT NULL,
  product_id  UUID NOT NULL,
  quantity    NUMERIC(12,3) NOT NULL CHECK (quantity > 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  FOREIGN KEY (pantry_id, order_id)   REFERENCES orders   (pantry_id, id) ON DELETE CASCADE,
  FOREIGN KEY (pantry_id, product_id) REFERENCES products (pantry_id, id)
);

-- Links a distribution to the order it fulfilled, so item history shows where stock went.
ALTER TABLE inventory_transactions
  ADD COLUMN order_id UUID,
  ADD FOREIGN KEY (pantry_id, order_id) REFERENCES orders (pantry_id, id);


-- ---------------------------------------------------------------------------
-- Ledger rules
-- ---------------------------------------------------------------------------

-- Receiving a batch writes its 'receive' ledger entry automatically.
CREATE FUNCTION batch_before_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.quantity_on_hand := 0;
  RETURN NEW;
END;
$$;

CREATE FUNCTION batch_after_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO inventory_transactions (pantry_id, batch_id, type, quantity, user_id, created_at)
  VALUES (NEW.pantry_id, NEW.id, 'receive', NEW.quantity_received, NEW.received_by, NEW.received_at);
  RETURN NEW;
END;
$$;

-- Applies each ledger entry to the batch. The batch CHECK rejects taking out more than is on hand.
CREATE FUNCTION txn_apply() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE inventory_batches
     SET quantity_on_hand = quantity_on_hand + NEW.quantity
   WHERE pantry_id = NEW.pantry_id AND id = NEW.batch_id;
  RETURN NEW;
END;
$$;

CREATE FUNCTION txn_block_change() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'inventory_transactions is append-only; add an adjust entry instead';
END;
$$;

-- Direct edits to the cached count are rejected. Only the ledger trigger (nested call) may change it.
CREATE FUNCTION batch_guard_quantity() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.quantity_on_hand IS DISTINCT FROM OLD.quantity_on_hand AND pg_trigger_depth() < 2 THEN
    RAISE EXCEPTION 'quantity_on_hand is derived from inventory_transactions; add a ledger entry instead';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_before_insert BEFORE INSERT ON inventory_batches
  FOR EACH ROW EXECUTE FUNCTION batch_before_insert();
CREATE TRIGGER trg_batch_after_insert AFTER INSERT ON inventory_batches
  FOR EACH ROW EXECUTE FUNCTION batch_after_insert();
CREATE TRIGGER trg_batch_guard_quantity BEFORE UPDATE ON inventory_batches
  FOR EACH ROW EXECUTE FUNCTION batch_guard_quantity();
CREATE TRIGGER trg_txn_apply AFTER INSERT ON inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION txn_apply();
CREATE TRIGGER trg_txn_block_change BEFORE UPDATE OR DELETE ON inventory_transactions
  FOR EACH ROW EXECUTE FUNCTION txn_block_change();


-- ---------------------------------------------------------------------------
-- Audit log and updated_at
-- ---------------------------------------------------------------------------

CREATE FUNCTION audit_row() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  old_row JSONB := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE to_jsonb(OLD) END;
  new_row JSONB := CASE WHEN TG_OP = 'DELETE' THEN NULL ELSE to_jsonb(NEW) END;
  subject JSONB := COALESCE(new_row, old_row);
BEGIN
  -- The ledger already records stock changes, so cache-only updates are not audited again.
  IF TG_OP = 'UPDATE' AND (old_row - 'updated_at' - 'quantity_on_hand') = (new_row - 'updated_at' - 'quantity_on_hand') THEN
    RETURN NULL;
  END IF;

  INSERT INTO audit_log (pantry_id, user_id, table_name, row_id, action, old_data, new_data)
  VALUES (
    CASE WHEN TG_TABLE_NAME = 'pantries' THEN (subject ->> 'id')::uuid
         ELSE (subject ->> 'pantry_id')::uuid END,
    current_user_id(), TG_TABLE_NAME, (subject ->> 'id')::uuid, TG_OP, old_row, new_row
  );
  RETURN NULL;
END;
$$;

DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['pantries', 'profiles', 'memberships', 'products', 'locations', 'donors',
                           'inventory_batches', 'clients', 'orders', 'order_items']
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_updated_at BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION set_updated_at()', t, t);
  END LOOP;

  -- profiles has no pantry_id, so it is not audited here.
  FOREACH t IN ARRAY ARRAY['pantries', 'memberships', 'products', 'locations', 'donors',
                           'inventory_batches', 'clients', 'orders', 'order_items']
  LOOP
    EXECUTE format('CREATE TRIGGER trg_%s_audit AFTER INSERT OR UPDATE OR DELETE ON %I
                    FOR EACH ROW EXECUTE FUNCTION audit_row()', t, t);
  END LOOP;
END;
$$;


-- ---------------------------------------------------------------------------
-- Indexes for the common queries
-- ---------------------------------------------------------------------------

CREATE INDEX idx_memberships_user  ON memberships (user_id);
CREATE INDEX idx_batches_product   ON inventory_batches (pantry_id, product_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_batches_best_by   ON inventory_batches (pantry_id, best_by_date)
  WHERE quantity_on_hand > 0 AND deleted_at IS NULL;
CREATE INDEX idx_txn_batch         ON inventory_transactions (batch_id, created_at);
CREATE INDEX idx_txn_pantry_time   ON inventory_transactions (pantry_id, created_at);
CREATE INDEX idx_audit_row         ON audit_log (pantry_id, table_name, row_id, changed_at);
CREATE INDEX idx_orders_client     ON orders (pantry_id, client_id);
CREATE INDEX idx_order_items_order ON order_items (pantry_id, order_id);


-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Stock per product, with a low-stock flag. security_invoker keeps row-level security in force.
CREATE VIEW product_stock WITH (security_invoker = true) AS
SELECT p.pantry_id,
       p.id AS product_id,
       p.name,
       p.unit,
       p.low_stock_threshold,
       COALESCE(SUM(b.quantity_on_hand), 0) AS quantity_on_hand,
       COALESCE(SUM(b.quantity_on_hand), 0) <= COALESCE(p.low_stock_threshold, -1) AS is_low_stock
FROM products p
LEFT JOIN inventory_batches b
       ON b.pantry_id = p.pantry_id AND b.product_id = p.id AND b.deleted_at IS NULL
WHERE p.deleted_at IS NULL
GROUP BY p.pantry_id, p.id;

-- Example: expiring soon
-- SELECT p.name, b.quantity_on_hand, b.best_by_date
-- FROM inventory_batches b JOIN products p ON p.pantry_id = b.pantry_id AND p.id = b.product_id
-- WHERE b.pantry_id = $1 AND b.quantity_on_hand > 0 AND b.deleted_at IS NULL
--   AND b.best_by_date <= CURRENT_DATE + INTERVAL '30 days'
-- ORDER BY b.best_by_date;

-- Example: pounds distributed this month
-- SELECT SUM(-t.quantity * COALESCE(p.unit_weight_lb, CASE WHEN p.unit = 'lb' THEN 1 END)) AS pounds
-- FROM inventory_transactions t
-- JOIN inventory_batches b ON b.pantry_id = t.pantry_id AND b.id = t.batch_id
-- JOIN products p          ON p.pantry_id = b.pantry_id AND p.id = b.product_id
-- WHERE t.pantry_id = $1 AND t.type = 'distribute' AND t.created_at >= date_trunc('month', now());
