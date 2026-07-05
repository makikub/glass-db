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
