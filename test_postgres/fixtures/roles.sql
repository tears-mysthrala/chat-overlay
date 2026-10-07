-- Synthetic local-only credentials. No real account or deployment configuration.
CREATE ROLE overlay_migrator LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD 'synthetic-migration';
CREATE ROLE overlay_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD 'synthetic-runtime';
CREATE ROLE overlay_bootstrap LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD 'synthetic-bootstrap';
ALTER DATABASE overlay_synthetic OWNER TO overlay_migrator;
GRANT CREATE ON DATABASE overlay_synthetic TO overlay_migrator;
