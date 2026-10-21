-- Значения считаются из id, поэтому в PostgreSQL и CockroachDB получаются одинаковые данные
INSERT INTO trips
SELECT i,
       (ARRAY['new_york', 'chicago', 'moscow'])[1 + i % 3],
       (i * 31) % 100000,
       (i * 17) % 5000000,
       TIMESTAMPTZ '2025-01-01 00:00:00+00' + ((i * 2654435761) % 31536000) * INTERVAL '1 second',
       60 + (i * 13) % 3600,
       (i * 104729) % 50000,
       ((i * 7919) % 10000 + 300) / 100.0,
       (ARRAY['card', 'cash', 'app'])[1 + (i * 7) % 11 % 3],
       md5(i::TEXT) || md5((i + 1)::TEXT)
FROM generate_series(:lo::BIGINT, :hi) AS i;
