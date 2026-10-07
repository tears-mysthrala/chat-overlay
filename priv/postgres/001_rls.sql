-- Offline migration, executed by the dedicated database owner, never at startup.
-- Provision these LOGIN identities/passwords separately; no owner membership.
BEGIN;
CREATE SCHEMA overlay;
REVOKE ALL ON SCHEMA overlay FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA overlay TO overlay_runtime, overlay_bootstrap;
CREATE TABLE overlay.profiles (
  handle text PRIMARY KEY CHECK (handle ~ '^[a-z0-9][a-z0-9_-]{0,39}$'),
  body text NOT NULL CHECK (octet_length(body) <= 65536),
  accounts_present boolean NOT NULL
);
CREATE TABLE overlay.accounts (
  handle text NOT NULL REFERENCES overlay.profiles(handle) ON DELETE CASCADE,
  provider text NOT NULL CHECK (provider IN ('twitch','youtube')),
  body text NOT NULL CHECK (octet_length(body) <= 65536),
  PRIMARY KEY(handle, provider)
);
-- Retired objects must survive profile deletion until confirmed remote cleanup.
CREATE TABLE overlay.objects (
  handle text NOT NULL CHECK (handle ~ '^[a-z0-9][a-z0-9_-]{0,39}$'),
  key text PRIMARY KEY,
  body text NOT NULL CHECK (octet_length(body) <= 65536)
);
ALTER TABLE overlay.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE overlay.profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE overlay.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE overlay.accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE overlay.objects ENABLE ROW LEVEL SECURITY;
ALTER TABLE overlay.objects FORCE ROW LEVEL SECURITY;
CREATE POLICY profile_scope ON overlay.profiles TO overlay_runtime
 USING (handle = nullif(current_setting('overlay.handle', true), ''))
 WITH CHECK (handle = nullif(current_setting('overlay.handle', true), ''));
CREATE POLICY account_scope ON overlay.accounts TO overlay_runtime
 USING (handle = nullif(current_setting('overlay.handle', true), ''))
 WITH CHECK (handle = nullif(current_setting('overlay.handle', true), ''));
CREATE POLICY object_scope ON overlay.objects TO overlay_runtime
 USING (handle = nullif(current_setting('overlay.handle', true), ''))
 WITH CHECK (handle = nullif(current_setting('overlay.handle', true), ''));
-- Internal source bootstrap/export: SELECT only, no mutation/DDL/TRUNCATE/role switch.
CREATE POLICY bootstrap_profiles ON overlay.profiles FOR SELECT TO overlay_bootstrap USING (true);
CREATE POLICY bootstrap_accounts ON overlay.accounts FOR SELECT TO overlay_bootstrap USING (true);
CREATE POLICY bootstrap_objects ON overlay.objects FOR SELECT TO overlay_bootstrap USING (true);
GRANT SELECT, INSERT, UPDATE, DELETE ON overlay.profiles, overlay.accounts, overlay.objects TO overlay_runtime;
GRANT SELECT ON overlay.profiles, overlay.accounts, overlay.objects TO overlay_bootstrap;
COMMIT;
