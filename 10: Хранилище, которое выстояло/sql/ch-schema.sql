CREATE DATABASE IF NOT EXISTS tpch;

CREATE TABLE tpch.region (
    r_regionkey Int32,
    r_name      String,
    r_comment   String
) ENGINE = MergeTree ORDER BY r_regionkey;

CREATE TABLE tpch.nation (
    n_nationkey Int32,
    n_name      String,
    n_regionkey Int32,
    n_comment   String
) ENGINE = MergeTree ORDER BY n_nationkey;

CREATE TABLE tpch.part (
    p_partkey     Int32,
    p_name        String,
    p_mfgr        LowCardinality(String),
    p_brand       LowCardinality(String),
    p_type        LowCardinality(String),
    p_size        Int32,
    p_container   LowCardinality(String),
    p_retailprice Decimal(15,2),
    p_comment     String
) ENGINE = MergeTree ORDER BY p_partkey;

CREATE TABLE tpch.supplier (
    s_suppkey   Int32,
    s_name      String,
    s_address   String,
    s_nationkey Int32,
    s_phone     String,
    s_acctbal   Decimal(15,2),
    s_comment   String
) ENGINE = MergeTree ORDER BY s_suppkey;

CREATE TABLE tpch.partsupp (
    ps_partkey    Int32,
    ps_suppkey    Int32,
    ps_availqty   Int32,
    ps_supplycost Decimal(15,2),
    ps_comment    String
) ENGINE = MergeTree ORDER BY (ps_partkey, ps_suppkey);

CREATE TABLE tpch.customer (
    c_custkey    Int32,
    c_name       String,
    c_address    String,
    c_nationkey  Int32,
    c_phone      String,
    c_acctbal    Decimal(15,2),
    c_mktsegment LowCardinality(String),
    c_comment    String
) ENGINE = MergeTree ORDER BY c_custkey;

CREATE TABLE tpch.orders (
    o_orderkey      Int64,
    o_custkey       Int32,
    o_orderstatus   LowCardinality(String),
    o_totalprice    Decimal(15,2),
    o_orderdate     Date,
    o_orderpriority LowCardinality(String),
    o_clerk         String,
    o_shippriority  Int32,
    o_comment       String
) ENGINE = MergeTree ORDER BY (o_orderdate, o_orderkey);

CREATE TABLE tpch.lineitem (
    l_orderkey      Int64,
    l_partkey       Int32,
    l_suppkey       Int32,
    l_linenumber    Int32,
    l_quantity      Decimal(15,2),
    l_extendedprice Decimal(15,2),
    l_discount      Decimal(15,2),
    l_tax           Decimal(15,2),
    l_returnflag    LowCardinality(String),
    l_linestatus    LowCardinality(String),
    l_shipdate      Date,
    l_commitdate    Date,
    l_receiptdate   Date,
    l_shipinstruct  LowCardinality(String),
    l_shipmode      LowCardinality(String),
    l_comment       String
) ENGINE = MergeTree ORDER BY (l_shipdate, l_orderkey);
