-- =============================================================================
-- PRE-MIGRATION SQL SCRIPT
-- Ory Hydra:   v1.11.10  ->  v2.1.2
-- CockroachDB: v25.2.10
-- Topology:    Multi-region cluster
--
-- COMPLETE v1.11.10 TABLE INVENTORY
--
--   +-- GLOBAL -----------------------------------------------------------------+
--   |  hydra_client                                                             |
--   |  hydra_jwk                                                                |
--   |  schema_migration                                                         |
--   +---------------------------------------------------------------------------+
--   +-- REGIONAL BY TABLE IN PRIMARY REGION ------------------------------------+
--   |  pk_sequence tables (CockroachDB sequence objects, GC via zone config)    |
--   +---------------------------------------------------------------------------+
--   +-- REGIONAL BY ROW --------------------------------------------------------+
--   |  hydra_oauth2_access                                                      |
--   |  hydra_oauth2_authentication_request                                      |
--   |  hydra_oauth2_authentication_request_handled                              |
--   |  hydra_oauth2_authentication_session                                      |
--   |  hydra_oauth2_code                                                        |
--   |  hydra_oauth2_consent_request                                             |
--   |  hydra_oauth2_consent_request_handled                                     |
--   |  hydra_oauth2_jti_blacklist                                               |
--   |  hydra_oauth2_logout_request                                              |
--   |  hydra_oauth2_obfuscated_authentication_session                           |
--   |  hydra_oauth2_oidc                                                        |
--   |  hydra_oauth2_pkce                                                        |
--   |  hydra_oauth2_refresh                                                     |
--   |  hydra_oauth2_trusted_jwt_bearer_issuer                                   |
--   +---------------------------------------------------------------------------+
--
-- MIGRATION CHAIN (cockroach-specific files between v1.11.10 and v2.1.2):
--
--   20211004110001000000  ADD COLUMN pk UUID to hydra_client
--   20211004110002000000  Intermediate hydra_client PK preparation work
--   20211004110003000000  <- BREAKS on CRDB v25; pre-fixed in Section 3 below
--   20211019000001000000  CREATE hydra_oauth2_flow; migrate data from the 4
--                          login/consent tables; DROP those 4 tables
--   20220210000001000000  NID backfill (~79 cockroach fragments; safe on CRDB v25
--   ...000078              because each uses a single combined ALTER TABLE)
--   20220513000001000000  string_slice_json UPDATE (full-table, no WHERE)
--   20220513000001000001  string_slice_json UPDATE (full-table, no WHERE)
--   20221104000001000000  hydra_client janitor index + UPDATE
--
-- HOW TO RUN:
--   cockroach sql \
--     --url "cockroach://<MIGRATION_USER>@<HOST>:26257/<DB_NAME>?sslmode=require" \
--     --file hydra_v2_premigration.sql
--
-- REPLACE BEFORE RUNNING:
--   <DB_NAME>        -> your CockroachDB database name  (e.g. hydra_prod)
--   <MIGRATION_USER> -> the DB role used by the hydra-migrate Kubernetes Job
-- =============================================================================


-- =============================================================================
-- PRE-FLIGHT: run this block first in isolation and review output carefully
-- before executing the rest of the script.
-- =============================================================================
/*
-- A. Current PK / UNIQUE constraints on hydra_client:
SELECT c.constraint_name,
       c.constraint_type,
       string_agg(k.column_name, ', ' ORDER BY k.ordinal_position) AS cols
FROM   information_schema.table_constraints c
JOIN   information_schema.key_column_usage  k
         ON c.constraint_name = k.constraint_name
        AND c.table_name      = k.table_name
WHERE  c.table_name      = 'hydra_client'
  AND  c.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
GROUP  BY 1, 2;
-- Check whether current PK is on 'id' (legacy) or already on 'pk' (if a
-- prior partial migration ran).  Also confirms whether the constraint is
-- named "primary" (CRDB <= v21.2) or "hydra_client_pkey" (CRDB >= v22.1).

-- B. Check for the 'pk' column on hydra_client:
SELECT column_name, data_type, column_default, is_nullable
FROM   information_schema.columns
WHERE  table_name  = 'hydra_client'
  AND  column_name IN ('id', 'pk')
ORDER  BY ordinal_position;

-- C. Full table inventory (compare against the 17-table list in the header):
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_type   = 'BASE TABLE'
ORDER  BY table_name;
*/


-- =============================================================================
-- SECTION 1 -- ROLE SETTING
--
-- The NID backfill migration (20220210000001000000, ~79 fragments) and the
-- string_slice_json migrations (20220513000001000000/000001) issue full-table
-- UPDATE statements without a WHERE clause.  CockroachDB's sql_safe_updates
-- guard rejects these.
--
-- Scoped to the migration role only; does not affect the cluster or other roles.
-- =============================================================================

ALTER ROLE <MIGRATION_USER> SET sql_safe_updates = false;


-- =============================================================================
-- SECTION 2 -- PERMISSIONS
-- =============================================================================

GRANT ALL PRIVILEGES ON DATABASE   <DB_NAME>             TO <MIGRATION_USER>;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public   TO <MIGRATION_USER>;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public   TO <MIGRATION_USER>;
GRANT CREATE                          ON DATABASE <DB_NAME> TO <MIGRATION_USER>;
ALTER ROLE <MIGRATION_USER> CREATEDB;


-- =============================================================================
-- SECTION 3 -- GC TTL (gc.ttlseconds = 1200) ON ALL v1.11.10 TABLES
--
-- Applied to all 17 tables that exist on the restored v1.11.10 snapshot.
-- Tables created BY the migration (hydra_oauth2_flow, etc.) must be configured
-- in a post-migration pass (see Section 7).
--
-- NOTE on the 4 login/consent tables:
--   hydra_oauth2_authentication_request, _handled, hydra_oauth2_consent_request,
--   _handled are DROPPED by migration 20211019000001000000 after their data is
--   moved to hydra_oauth2_flow.  Setting gc.ttlseconds on them before migration
--   avoids CRDB GC-window contention during the large data-move + DROP phase
--   on a live multi-region cluster.
-- =============================================================================

-- ---- GLOBAL tables ----------------------------------------------------------

ALTER TABLE hydra_client
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_jwk
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE schema_migration
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

-- ---- REGIONAL BY ROW tables: token stores -----------------------------------

ALTER TABLE hydra_oauth2_access
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_refresh
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_code
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_oidc
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_pkce
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

-- ---- REGIONAL BY ROW tables: login/consent flow (merged and dropped by
--      migration 20211019000001000000) ----------------------------------------

ALTER TABLE hydra_oauth2_authentication_request
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_authentication_request_handled
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_consent_request
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_consent_request_handled
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

-- ---- REGIONAL BY ROW tables: session stores ---------------------------------

ALTER TABLE hydra_oauth2_authentication_session
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_obfuscated_authentication_session
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

-- ---- REGIONAL BY ROW tables: other ------------------------------------------

ALTER TABLE hydra_oauth2_logout_request
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_trusted_jwt_bearer_issuer
  CONFIGURE ZONE USING gc.ttlseconds = 1200;

ALTER TABLE hydra_oauth2_jti_blacklist
  CONFIGURE ZONE USING gc.ttlseconds = 1200;


-- =============================================================================
-- SECTION 4 -- CRITICAL FIX: PRIMARY KEY RENAME ON hydra_client
--
-- ROOT CAUSE:
--   Migration 20211004110003000000_change_client_primary_key.cockroach.up.sql
--   contains two separate ALTER TABLE statements:
--
--       ALTER TABLE hydra_client DROP CONSTRAINT "primary";
--       ALTER TABLE hydra_client ADD CONSTRAINT "hydra_client_pkey" PRIMARY KEY (pk);
--
--   CRDB v25 requires the DROP and ADD to be issued as a SINGLE ALTER TABLE
--   statement; running them separately yields:
--       SQLSTATE 0A000 -- "primary key dropped without subsequent addition
--                          of new primary key in same transaction"
--
--   Additionally, databases restored from a CRDB >= v22.1 source already
--   auto-name the PK "hydra_client_pkey" (not "primary"), so the raw DROP
--   also fails with:
--       SQLSTATE 42704 -- constraint "primary" does not exist
--   (refs: github.com/ory/hydra/issues/3535, issues/3964)
--
-- FIX:
--   1. Ensure 'pk' UUID column exists (IF NOT EXISTS -- idempotent).
--   2. Backfill any zero-UUID pk sentinel values.
--   3. Create a UNIQUE INDEX on 'id' so FK references from all
--      hydra_oauth2_* tables remain valid once 'id' is no longer the PK.
--   4. Execute DROP + ADD as one atomic ALTER TABLE (CRDB v25-safe).
--   5. Record version in schema_migration so hydra migrate sql skips the file.
-- =============================================================================

-- 4.1  Ensure 'pk' UUID column exists.
--      Migration 20211004110001000000 should have added it; IF NOT EXISTS
--      makes this idempotent if this script is run more than once.
ALTER TABLE hydra_client
  ADD COLUMN IF NOT EXISTS pk UUID NOT NULL DEFAULT gen_random_uuid();

-- 4.2  Backfill any rows carrying the zero-UUID sentinel.
--      hydra_client is GLOBAL; no crdb_region predicate is needed.
UPDATE hydra_client
   SET pk = gen_random_uuid()
 WHERE pk = '00000000-0000-0000-0000-000000000000'::UUID;

-- 4.3  Create a UNIQUE backing index on 'id'.
--      Every hydra_oauth2_* table has a FK reference to hydra_client(id).
--      CRDB requires a UNIQUE index on a column that is the target of a FK
--      reference once that column is no longer the PK.
--      IF NOT EXISTS is a no-op if migration 20211004110002000000 already
--      created this index.
CREATE UNIQUE INDEX IF NOT EXISTS hydra_client_id_idx
    ON hydra_client (id);

-- 4.4  Atomically rename the PK in a single ALTER TABLE statement.
--      The IF EXISTS / IF NOT EXISTS guards make this correct regardless of
--      whether the constraint is currently named "primary" or "hydra_client_pkey".
ALTER TABLE hydra_client
  DROP CONSTRAINT IF EXISTS "primary",
  ADD  CONSTRAINT IF NOT EXISTS "hydra_client_pkey" PRIMARY KEY (pk);

-- 4.5  Defensive CREATE of schema_migration (guards against edge-case restores
--      that only contain old per-subsystem migration tables).
CREATE TABLE IF NOT EXISTS schema_migration (
  version    TEXT NOT NULL,
  CONSTRAINT schema_migration_pkey PRIMARY KEY (version)
);

-- 4.6  Mark migration as applied so the hydra migrate runner skips it.
INSERT INTO schema_migration (version)
VALUES ('20211004110003000000')
ON CONFLICT DO NOTHING;


-- =============================================================================
-- SECTION 5 -- FOREIGN KEY INTEGRITY CLEANUP (OPTIONAL, COMMENTED OUT)
--
-- Migration 20211019000001000000 INSERTs rows from the four login/consent
-- tables into the new hydra_oauth2_flow table before dropping them.
-- Orphaned FK references in a source table will cause that INSERT to fail.
--
-- On a consistent production restore these DELETE statements affect 0 rows.
-- Uncomment, verify the DELETE counts are acceptable, then re-run if needed.
-- =============================================================================

-- Consent requests pointing to a non-existent login challenge:
-- DELETE FROM hydra_oauth2_consent_request AS cr
--  WHERE login_challenge IS NOT NULL
--    AND NOT EXISTS (
--      SELECT 1 FROM hydra_oauth2_authentication_request ar
--       WHERE ar.challenge = cr.login_challenge
--    );

-- Handled consent requests whose parent consent request is gone:
-- DELETE FROM hydra_oauth2_consent_request_handled AS crh
--  WHERE NOT EXISTS (
--    SELECT 1 FROM hydra_oauth2_consent_request cr
--     WHERE cr.challenge = crh.challenge
--  );

-- Handled authentication requests whose parent is gone:
-- DELETE FROM hydra_oauth2_authentication_request_handled AS arh
--  WHERE NOT EXISTS (
--    SELECT 1 FROM hydra_oauth2_authentication_request ar
--     WHERE ar.challenge = arh.challenge
--  );

-- Access tokens referencing a non-existent client:
-- DELETE FROM hydra_oauth2_access
--  WHERE NOT EXISTS (
--    SELECT 1 FROM hydra_client c WHERE c.id = hydra_oauth2_access.client_id
--  );

-- Refresh tokens referencing a non-existent client:
-- DELETE FROM hydra_oauth2_refresh
--  WHERE NOT EXISTS (
--    SELECT 1 FROM hydra_client c WHERE c.id = hydra_oauth2_refresh.client_id
--  );

-- Logout requests referencing a non-existent client:
-- DELETE FROM hydra_oauth2_logout_request
--  WHERE client_id IS NOT NULL
--    AND NOT EXISTS (
--      SELECT 1 FROM hydra_client c WHERE c.id = hydra_oauth2_logout_request.client_id
--    );


-- =============================================================================
-- SECTION 6 -- STALE ARTIFACT CLEANUP
-- Only needed if this is a retry after a prior partial migration attempt.
-- Comment everything out on a fresh restore.
-- =============================================================================

-- 6a. Drop the partially-created flow table so the migration can recreate it.
--     WARNING: data loss. Only safe when the four source tables are still intact.
-- DROP TABLE IF EXISTS hydra_oauth2_flow;

-- 6b. Remove partial NID-migration schema_migration entries so those fragments
--     re-run.  Adjust the upper bound to the last successfully-completed fragment.
-- DELETE FROM schema_migration
--  WHERE version LIKE '20220210000001%';

-- 6c. Drop partial NID indexes left by an aborted run:
-- DROP INDEX IF EXISTS hydra_oauth2_access@hydra_oauth2_access_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_refresh@hydra_oauth2_refresh_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_code@hydra_oauth2_code_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_oidc@hydra_oauth2_oidc_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_pkce@hydra_oauth2_pkce_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_authentication_request@hydra_oauth2_authentication_request_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_authentication_request_handled@hydra_oauth2_authentication_request_handled_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_authentication_session@hydra_oauth2_authentication_session_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_consent_request@hydra_oauth2_consent_request_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_consent_request_handled@hydra_oauth2_consent_request_handled_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_logout_request@hydra_oauth2_logout_request_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_obfuscated_authentication_session@hydra_oauth2_obfuscated_authentication_session_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_trusted_jwt_bearer_issuer@hydra_oauth2_trusted_jwt_bearer_issuer_nid_idx;
-- DROP INDEX IF EXISTS hydra_oauth2_jti_blacklist@hydra_oauth2_jti_blacklist_nid_idx;
-- DROP INDEX IF EXISTS hydra_client@hydra_client_nid_idx;
-- DROP INDEX IF EXISTS hydra_jwk@hydra_jwk_nid_idx;


-- =============================================================================
-- SECTION 7 -- VERIFICATION QUERIES
-- Run AFTER this script and BEFORE launching hydra migrate sql.
-- =============================================================================
/*
-- 7a. PK on hydra_client must now be on column 'pk', not 'id':
SELECT c.constraint_name,
       c.constraint_type,
       string_agg(k.column_name, ', ' ORDER BY k.ordinal_position) AS cols
FROM   information_schema.table_constraints c
JOIN   information_schema.key_column_usage  k
         ON c.constraint_name = k.constraint_name
        AND c.table_name      = k.table_name
WHERE  c.table_name      = 'hydra_client'
  AND  c.constraint_type IN ('PRIMARY KEY', 'UNIQUE')
GROUP  BY 1, 2
ORDER  BY 2, 1;
-- Expected:
--   hydra_client_pkey   | PRIMARY KEY | pk
--   hydra_client_id_idx | UNIQUE      | id

-- 7b. Migration 20211004110003000000 must be marked as applied:
SELECT version FROM schema_migration
 WHERE version = '20211004110003000000';
-- Expected: 1 row

-- 7c. All 17 v1.11.10 tables must be present:
SELECT table_name
FROM   information_schema.tables
WHERE  table_schema = 'public'
  AND  table_type   = 'BASE TABLE'
ORDER  BY table_name;
-- Expected (17):
--   hydra_client
--   hydra_jwk
--   hydra_oauth2_access
--   hydra_oauth2_authentication_request
--   hydra_oauth2_authentication_request_handled
--   hydra_oauth2_authentication_session
--   hydra_oauth2_code
--   hydra_oauth2_consent_request
--   hydra_oauth2_consent_request_handled
--   hydra_oauth2_jti_blacklist
--   hydra_oauth2_logout_request
--   hydra_oauth2_obfuscated_authentication_session
--   hydra_oauth2_oidc
--   hydra_oauth2_pkce
--   hydra_oauth2_refresh
--   hydra_oauth2_trusted_jwt_bearer_issuer
--   schema_migration

-- 7d. GC TTL spot-check:
SHOW ZONE CONFIGURATION FOR TABLE hydra_oauth2_jti_blacklist;
SHOW ZONE CONFIGURATION FOR TABLE hydra_oauth2_authentication_request;
SHOW ZONE CONFIGURATION FOR TABLE hydra_oauth2_consent_request_handled;
-- All should show gc.ttlseconds = 1200

-- 7e. Confirm role setting is persisted:
SHOW ALTER ROLE <MIGRATION_USER>;
-- Expect: sql_safe_updates = off
*/


-- =============================================================================
-- SECTION 8 -- POST-MIGRATION CHECKLIST
-- Run AFTER `hydra migrate sql -e --yes` completes successfully.
-- =============================================================================
/*
  WHAT THE MIGRATION CHANGES:
    CREATED:  hydra_oauth2_flow
              (replaces the 4 login/consent tables which are DROPPED)
    DROPPED:  hydra_oauth2_authentication_request
              hydra_oauth2_authentication_request_handled
              hydra_oauth2_consent_request
              hydra_oauth2_consent_request_handled
    ALTERED:  all surviving tables gain an nid UUID column + new composite PK

  POST-MIGRATION SQL (run in order):

  -- 1. Re-apply REGIONAL BY ROW on all surviving + new tables:
  ALTER TABLE hydra_oauth2_flow                              ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_access                            ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_refresh                           ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_code                              ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_oidc                              ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_pkce                              ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_authentication_session            ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_obfuscated_authentication_session ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_logout_request                    ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_trusted_jwt_bearer_issuer         ALTER LOCALITY REGIONAL BY ROW;
  ALTER TABLE hydra_oauth2_jti_blacklist                     ALTER LOCALITY REGIONAL BY ROW;

  -- 2. GC TTL on newly-created tables:
  ALTER TABLE hydra_oauth2_flow CONFIGURE ZONE USING gc.ttlseconds = 1200;

  -- 3. Restore per-index / per-partition zone configurations on all
  --    REGIONAL BY ROW tables to match your original partition layout.
  --    Run your existing partition-restore script here.

  -- 4. Multi-region integrity validation:
  SELECT * FROM crdb_internal.invalid_objects;
  SELECT crdb_internal.validate_multi_region_zone_configs();

  -- 5. Row-count sanity checks:
  SELECT count(*) FROM hydra_oauth2_flow;
  SELECT count(*) FROM hydra_oauth2_access;
  SELECT count(*) FROM hydra_client;

  -- 6. Confirm nid column is present on key tables:
  SELECT column_name FROM information_schema.columns
   WHERE table_name IN ('hydra_oauth2_flow', 'hydra_oauth2_access', 'hydra_client')
     AND column_name = 'nid';
  -- Expected: 3 rows
*/