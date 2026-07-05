DROP TABLE IF EXISTS projects;
CREATE TABLE projects (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL,
    owner TEXT,
    updated_at TEXT NOT NULL
);

INSERT INTO projects (id, name, status, owner, updated_at) VALUES
    (1, 'GlassDB MVP', 'active', 'Masaki', '2026-07-02'),
    (2, 'Driver abstraction', 'planned', NULL, '2026-07-03'),
    (3, 'Read-only grid', 'active', 'Codex', '2026-07-02');
