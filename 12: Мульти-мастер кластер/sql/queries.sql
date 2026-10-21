\timing on
\echo Q1: точечное чтение по первичному ключу
SELECT id, city, driver_id, started_at, fare FROM trips WHERE id = 31415926;
\echo Q2: диапазон по первичному ключу (100 тыс. строк)
SELECT city, count(*), sum(fare) FROM trips WHERE id BETWEEN 20000001 AND 20100000 GROUP BY city ORDER BY city;
\echo Q3: агрегация по всей таблице
SELECT city, count(*), sum(fare), avg(distance_m)::NUMERIC(10,1) FROM trips GROUP BY city ORDER BY city;
\echo Q4: группировка по 100 тыс. водителей и топ-5
SELECT driver_id, count(*), sum(fare) FROM trips GROUP BY driver_id ORDER BY sum(fare) DESC, driver_id LIMIT 5;
