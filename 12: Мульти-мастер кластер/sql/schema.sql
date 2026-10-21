CREATE TABLE trips (
    id           BIGINT PRIMARY KEY,
    city         TEXT NOT NULL,
    driver_id    BIGINT NOT NULL,
    passenger_id BIGINT NOT NULL,
    started_at   TIMESTAMPTZ NOT NULL,
    duration_s   INT NOT NULL,
    distance_m   INT NOT NULL,
    fare         NUMERIC(10,2) NOT NULL,
    payment      TEXT NOT NULL,
    note         TEXT NOT NULL
);
