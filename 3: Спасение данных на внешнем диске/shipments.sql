CREATE TABLE shipments (
    id           serial PRIMARY KEY,
    product_name text        NOT NULL,
    quantity     integer     NOT NULL,
    destination  text        NOT NULL,
    shipped_at   timestamptz NOT NULL DEFAULT now()
);

INSERT INTO shipments (product_name, quantity, destination) VALUES
    ('Bananas', 1000, 'Europe'),
    ('Apples',   500, 'Asia'),
    ('Oranges',  750, 'Africa'),
    ('Mangoes',  300, 'South America'),
    ('Bananas', 1200, 'Europe');
