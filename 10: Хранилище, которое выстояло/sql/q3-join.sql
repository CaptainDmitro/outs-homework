SELECT l_orderkey,
       sum(l_extendedprice * (1 - l_discount)) AS revenue,
       o_orderdate,
       o_shippriority
FROM lineitem
JOIN orders ON l_orderkey = o_orderkey
JOIN customer ON c_custkey = o_custkey
WHERE c_mktsegment = 'BUILDING'
  AND o_orderdate < '1995-03-15'
  AND l_shipdate > '1995-03-15'
GROUP BY l_orderkey, o_orderdate, o_shippriority
ORDER BY revenue DESC, o_orderdate
LIMIT 10;
