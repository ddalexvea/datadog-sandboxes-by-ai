-- Create the datadog monitoring user (mirrors customer RDS setup)
CREATE USER datadog WITH PASSWORD 'datadog';

-- Grant connection and schema access
GRANT CONNECT ON DATABASE wallet TO datadog;
GRANT USAGE ON SCHEMA public TO datadog;

-- Enable pg_stat_statements (required for DBM)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Grant pg_monitor role (Postgres 10+, standard for DBM)
GRANT pg_monitor TO datadog;

-- Grant SELECT on stat views (belt-and-suspenders)
GRANT SELECT ON pg_stat_user_indexes TO datadog;
GRANT SELECT ON pg_statio_user_indexes TO datadog;
GRANT SELECT ON pg_stat_user_tables TO datadog;
GRANT SELECT ON pg_statio_user_tables TO datadog;

-- Create datadog schema for explain plans
CREATE SCHEMA IF NOT EXISTS datadog;
GRANT USAGE ON SCHEMA datadog TO datadog;

CREATE OR REPLACE FUNCTION datadog.explain_statement(l_query TEXT, OUT explain JSON)
RETURNS SETOF JSON AS $$
DECLARE
  curs REFCURSOR;
  plan JSON;
BEGIN
  OPEN curs FOR EXECUTE pg_catalog.concat('EXPLAIN (FORMAT JSON) ', l_query);
  FETCH curs INTO plan;
  CLOSE curs;
  RETURN QUERY SELECT plan;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Create some tables with indexes to reproduce the scenario
CREATE TABLE IF NOT EXISTS public.orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    amount DECIMAL(10,2),
    status VARCHAR(50),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON public.orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_created_at ON public.orders(created_at);

CREATE TABLE IF NOT EXISTS public.customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    email VARCHAR(255) UNIQUE,
    region VARCHAR(50)
);

CREATE INDEX IF NOT EXISTS idx_customers_region ON public.customers(region);
CREATE INDEX IF NOT EXISTS idx_customers_email ON public.customers(email);

-- Insert some data to generate index activity
INSERT INTO public.customers (name, email, region)
SELECT
    'Customer ' || i,
    'customer' || i || '@example.com',
    CASE WHEN i % 3 = 0 THEN 'ontario' WHEN i % 3 = 1 THEN 'quebec' ELSE 'bc' END
FROM generate_series(1, 1000) i
ON CONFLICT DO NOTHING;

INSERT INTO public.orders (customer_id, amount, status)
SELECT
    (random() * 999 + 1)::INTEGER,
    (random() * 10000)::DECIMAL(10,2),
    CASE WHEN random() > 0.5 THEN 'completed' ELSE 'pending' END
FROM generate_series(1, 5000);

-- Run some queries to generate index scan stats
SELECT * FROM public.orders WHERE customer_id = 42;
SELECT * FROM public.orders WHERE status = 'completed';
SELECT * FROM public.customers WHERE region = 'ontario';
SELECT * FROM public.customers WHERE email = 'customer100@example.com';
