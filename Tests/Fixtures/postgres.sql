DROP SCHEMA IF EXISTS analytics CASCADE;
DROP VIEW IF EXISTS active_projects;
DROP TABLE IF EXISTS primary_key_collision_other;
DROP TABLE IF EXISTS primary_key_collision_source;
DROP TABLE IF EXISTS projects;
CREATE TABLE projects (
    id BIGINT PRIMARY KEY,
    name VARCHAR(120) NOT NULL,
    status VARCHAR(32) NOT NULL,
    owner VARCHAR(120) NULL,
    updated_at DATE NOT NULL
);

INSERT INTO projects (id, name, status, owner, updated_at) VALUES
    (1, 'GlassDB MVP', 'active', 'Masaki', '2026-07-02'),
    (2, 'Driver abstraction', 'planned', NULL, '2026-07-03'),
    (3, 'Read-only grid', 'active', 'Codex', '2026-07-02');

CREATE VIEW active_projects AS
SELECT id, name, owner
FROM projects
WHERE status = 'active';

CREATE SCHEMA analytics;
CREATE VIEW analytics.project_statuses AS
SELECT status, COUNT(*) AS project_count
FROM public.projects
GROUP BY status;

CREATE TABLE primary_key_collision_source (
    id BIGINT NOT NULL,
    collision_value BIGINT NOT NULL,
    CONSTRAINT shared_pk PRIMARY KEY (id)
);

CREATE TABLE primary_key_collision_other (
    id BIGINT NOT NULL,
    collision_value BIGINT NOT NULL,
    CONSTRAINT shared_pk PRIMARY KEY (collision_value)
);
