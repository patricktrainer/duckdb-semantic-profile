-- A NULL-heavy table, for the distinction that matters:
--
--   NULL   is absence expressed correctly      -> must NOT be flagged
--   'n/a'  is a value standing in for absence  -> must be flagged
--   -1     is a value standing in for absence  -> must be flagged
--
-- Real warehouse tables are full of NULLs (CDC columns, optional fields), so
-- getting this backwards buries every genuine finding under noise.

CREATE OR REPLACE TABLE sparse AS
SELECT * FROM (VALUES
 (1, 'ada@example.com',   NULL, 'active', 12),
 (2, NULL,                NULL, NULL,     NULL),
 (3, 'n/a',               NULL, NULL,     NULL),
 (4, NULL,                NULL, 'active', NULL),
 (5, 'grace@example.com', NULL, NULL,      7),
 (6, NULL,                NULL, NULL,     -1)
) AS t(id, email, note, status, retry_count);
