-- DuckDB. run.py registers raw_events in physical CSV order and sets UTC.
CREATE TEMP TABLE dedup AS
WITH distinct_events AS (
    SELECT file_month, min(file_row) AS file_row, event_time, event_type, product_id, category_id,
        category_code, brand, price, user_id, user_session, count(*) AS identical_rows
    FROM raw_events
    GROUP BY file_month, event_time, event_type, product_id, category_id, category_code, brand, price, user_id, user_session
)
SELECT *,
    CASE WHEN regexp_full_match(event_time, '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC')
        THEN try_strptime(event_time, '%Y-%m-%d %H:%M:%S UTC') END AS ts,
    CASE WHEN regexp_full_match(user_id, '[0-9]+') AND try_cast(user_id AS BIGINT) > 0
        THEN try_cast(user_id AS BIGINT) END AS uid,
    CASE WHEN regexp_full_match(product_id, '[0-9]+') AND try_cast(product_id AS BIGINT) > 0
        THEN try_cast(product_id AS BIGINT) END AS pid,
    CASE WHEN regexp_full_match(category_id, '[0-9]+') AND try_cast(category_id AS BIGINT) > 0
        THEN try_cast(category_id AS BIGINT) END AS cid,
    nullif(regexp_replace(user_session, '^\s+|\s+$', '', 'g'), '') AS sid,
    nullif(trim(category_code), '') AS code,
    nullif(trim(brand), '') AS brand_clean,
    CASE WHEN regexp_full_match(trim(price), '[+]?[0-9]+(\.[0-9]{1,4})?')
        THEN try_cast(trim(price) AS DECIMAL(18,4)) END AS observed_price
FROM distinct_events;

DROP TABLE raw_events;

CREATE TEMP TABLE qa_files AS
SELECT file_month, sum(identical_rows) AS rows, min(ts) AS first_utc, max(ts) AS last_utc,
    count(DISTINCT CAST(ts AS DATE)) AS dates_with_events,
    coalesce(sum(identical_rows) FILTER (WHERE nullif(trim(event_time), '') IS NULL), 0) AS missing_time,
    coalesce(sum(identical_rows) FILTER (WHERE ts IS NULL AND nullif(trim(event_time), '') IS NOT NULL), 0) AS invalid_time,
    coalesce(sum(identical_rows) FILTER (WHERE date_trunc('month', ts)::DATE <> file_month), 0) AS wrong_month,
    coalesce(sum(identical_rows) FILTER (WHERE nullif(trim(event_type), '') IS NULL), 0) AS missing_event_type,
    coalesce(sum(identical_rows) FILTER (WHERE event_type NOT IN ('cart', 'purchase', 'remove_from_cart', 'view')
        AND nullif(trim(event_type), '') IS NOT NULL), 0) AS other_event_type,
    coalesce(sum(identical_rows) FILTER (WHERE nullif(trim(user_id), '') IS NULL), 0) AS missing_user_id,
    coalesce(sum(identical_rows) FILTER (WHERE uid IS NULL AND nullif(trim(user_id), '') IS NOT NULL), 0) AS invalid_user_id,
    coalesce(sum(identical_rows) FILTER (WHERE nullif(trim(product_id), '') IS NULL), 0) AS missing_product_id,
    coalesce(sum(identical_rows) FILTER (WHERE pid IS NULL AND nullif(trim(product_id), '') IS NOT NULL), 0) AS invalid_product_id,
    coalesce(sum(identical_rows) FILTER (WHERE sid IS NULL), 0) AS missing_user_session,
    coalesce(sum(identical_rows) FILTER (WHERE nullif(trim(category_id), '') IS NULL), 0) AS missing_category_id,
    coalesce(sum(identical_rows) FILTER (WHERE cid IS NULL AND nullif(trim(category_id), '') IS NOT NULL), 0) AS invalid_category_id,
    coalesce(sum(identical_rows) FILTER (WHERE code IS NULL), 0) AS missing_category_code,
    coalesce(sum(identical_rows) FILTER (WHERE brand_clean IS NULL), 0) AS missing_brand,
    coalesce(sum(identical_rows) FILTER (WHERE nullif(trim(price), '') IS NULL), 0) AS missing_price,
    coalesce(sum(identical_rows) FILTER (WHERE observed_price IS NULL AND nullif(trim(price), '') IS NOT NULL), 0) AS invalid_price,
    coalesce(sum(identical_rows) FILTER (WHERE observed_price = 0), 0) AS zero_price,
    count(*) AS deduplicated_rows,
    sum(identical_rows - 1) AS exact_duplicate_rows,
    count_if(identical_rows > 1) AS exact_duplicate_groups
FROM dedup GROUP BY file_month ORDER BY file_month;

CREATE TEMP TABLE event_counts AS
SELECT file_month, coalesce(nullif(trim(event_type), ''), '(missing)') AS event_type,
    count(*) AS rows, sum(identical_rows - 1) AS duplicate_rows,
    count_if(ts IS NOT NULL AND date_trunc('month', ts)::DATE = file_month AND uid IS NOT NULL AND pid IS NOT NULL)
        AS clean_rows,
    count_if(sid IS NULL) AS deduplicated_missing_session
FROM dedup GROUP BY ALL ORDER BY file_month, event_type;

CREATE TEMP VIEW event_distribution AS
SELECT file_month, event_type, rows + duplicate_rows AS raw_rows, duplicate_rows, clean_rows,
    deduplicated_missing_session
FROM event_counts ORDER BY file_month, event_type;

CREATE TEMP TABLE coverage AS
WITH input_dates AS (
    SELECT gs::DATE AS utc_date
    FROM (SELECT DISTINCT file_month FROM dedup) m,
    LATERAL generate_series(m.file_month, m.file_month + INTERVAL 1 MONTH - INTERVAL 1 DAY, INTERVAL 1 DAY) AS g(gs)
),
daily AS (
    SELECT ts::DATE AS utc_date, sum(identical_rows) AS rows, min(ts) AS first_utc, max(ts) AS last_utc
    FROM dedup WHERE date_trunc('month', ts)::DATE = file_month GROUP BY ts::DATE
)
SELECT utc_date, coalesce(rows, 0) AS rows, first_utc, last_utc
FROM input_dates LEFT JOIN daily USING (utc_date) ORDER BY utc_date;

CREATE TEMP VIEW observed_bounds AS
SELECT max(last_utc) AS max_utc
FROM coverage;

CREATE TEMP TABLE eligible_carts AS
SELECT uid, pid, ts AS t0, file_row, sid, cid, code, observed_price
FROM dedup CROSS JOIN observed_bounds
WHERE file_month = DATE '2019-10-01' AND event_type = 'cart'
    AND ts >= TIMESTAMP '2019-10-01' AND ts < TIMESTAMP '2019-11-01'
    AND uid IS NOT NULL AND pid IS NOT NULL
    AND ts + INTERVAL 7 DAY <= max_utc
    AND NOT EXISTS (
        SELECT 1 FROM coverage
        WHERE rows = 0 AND utc_date BETWEEN ts::DATE AND (ts + INTERVAL 7 DAY)::DATE
    );

CREATE TEMP TABLE cohort AS
SELECT *,
    count(*) OVER (PARTITION BY uid, pid) AS eligible_cart_count,
    count(*) OVER (PARTITION BY uid, pid, t0) AS cart_at_same_second
FROM eligible_carts
QUALIFY row_number() OVER (PARTITION BY uid, pid ORDER BY t0, file_row) = 1;

CREATE TEMP TABLE exclusions AS
WITH raw_october_carts AS (
    SELECT
        sum(identical_rows) AS raw_rows,
        coalesce(sum(identical_rows) FILTER (WHERE ts IS NULL OR date_trunc('month', ts)::DATE <> file_month), 0)
            AS invalid_time,
        coalesce(sum(identical_rows) FILTER (
            WHERE date_trunc('month', ts)::DATE = file_month AND (uid IS NULL OR pid IS NULL)), 0) AS invalid_ids
    FROM dedup WHERE file_month = DATE '2019-10-01' AND event_type = 'cart'
), clean_october_carts AS (
    SELECT count(*) AS clean_rows
    FROM dedup WHERE file_month = DATE '2019-10-01' AND event_type = 'cart'
        AND date_trunc('month', ts)::DATE = file_month AND uid IS NOT NULL AND pid IS NOT NULL
), eligible AS (
    SELECT count(*) AS eligible_rows FROM eligible_carts
), included AS (
    SELECT count(*) AS cohort_rows FROM cohort
), steps AS (
    SELECT * FROM raw_october_carts CROSS JOIN clean_october_carts CROSS JOIN eligible CROSS JOIN included
)
SELECT 1 AS step, 'raw_october_cart_rows' AS rule, raw_rows AS row_count, 0 AS excluded FROM steps
UNION ALL SELECT 2, 'valid_utc_in_october', raw_rows - invalid_time, invalid_time FROM steps
UNION ALL SELECT 3, 'valid_positive_user_and_product', raw_rows - invalid_time - invalid_ids, invalid_ids FROM steps
UNION ALL SELECT 4, 'exact_duplicate_rows', clean_rows, raw_rows - invalid_time - invalid_ids - clean_rows FROM steps
UNION ALL SELECT 5, 'full_7_day_window', eligible_rows, clean_rows - eligible_rows FROM steps
UNION ALL SELECT 6, 'first_eligible_cart_per_pair', cohort_rows, eligible_rows - cohort_rows FROM steps
ORDER BY step;

CREATE TEMP TABLE outcomes AS
SELECT uid, pid, ts, sid, event_type
FROM dedup
WHERE event_type IN ('purchase', 'remove_from_cart')
    AND uid IS NOT NULL AND pid IS NOT NULL
    AND date_trunc('month', ts)::DATE = file_month
    AND ts >= TIMESTAMP '2019-10-01' AND ts < TIMESTAMP '2019-11-08';

DROP TABLE dedup;

CREATE TEMP TABLE matching_product AS
SELECT c.uid, c.pid,
    count_if(e.event_type = 'purchase' AND e.ts > c.t0) > 0 AS purchase_7d,
    count_if(e.event_type = 'purchase' AND e.ts > c.t0 AND e.ts <= c.t0 + INTERVAL 24 HOUR) > 0 AS purchase_24h,
    count_if(e.event_type = 'purchase') > 0 AS purchase_including_t0,
    count_if(e.event_type = 'purchase' AND e.ts = c.t0) > 0 AS purchase_equal_t0,
    count_if(e.event_type = 'purchase' AND e.ts > c.t0 AND e.sid = c.sid) > 0 AS purchase_same_session,
    count_if(e.event_type = 'purchase' AND e.ts > c.t0 AND e.sid <> c.sid) > 0 AS purchase_other_session,
    count_if(e.event_type = 'purchase' AND e.ts > c.t0 AND e.sid IS NULL) > 0 AS purchase_unknown_session,
    count_if(e.event_type = 'purchase' AND e.ts >= TIMESTAMP '2019-11-01') > 0 AS purchase_in_november,
    min(e.ts) FILTER (WHERE e.event_type = 'purchase' AND e.ts > c.t0) AS first_purchase_utc,
    count_if(e.event_type = 'remove_from_cart' AND e.ts > c.t0) > 0 AS removed
FROM cohort c LEFT JOIN outcomes e
    ON c.uid = e.uid AND c.pid = e.pid AND e.ts BETWEEN c.t0 AND c.t0 + INTERVAL 7 DAY
GROUP BY c.uid, c.pid;

-- Jump to the first purchase second after t0. If it contains only the original product,
-- the next change of product or mixed-product second gives the earliest other product.
CREATE TEMP TABLE purchase_timeline AS
WITH seconds AS (
    SELECT uid, ts, min(pid) AS min_pid, max(pid) AS max_pid
    FROM outcomes WHERE event_type = 'purchase' GROUP BY uid, ts
), changes AS (
    SELECT *,
        CASE WHEN min_pid <> max_pid OR min_pid <> lag(min_pid) OVER (PARTITION BY uid ORDER BY ts)
            THEN ts END AS change_ts
    FROM seconds
)
SELECT uid, ts, min_pid, max_pid,
    min(change_ts) OVER (
        PARTITION BY uid ORDER BY ts ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING
    ) AS next_change
FROM changes;

CREATE TEMP TABLE other_product AS
SELECT c.uid, c.pid
FROM cohort c ASOF JOIN purchase_timeline b ON c.uid = b.uid AND c.t0 < b.ts
WHERE b.ts <= c.t0 + INTERVAL 7 DAY
    AND (c.pid <> b.min_pid OR c.pid <> b.max_pid OR b.next_change <= c.t0 + INTERVAL 7 DAY);

CREATE TEMP VIEW pair_flags AS
SELECT c.*,
    coalesce(m.purchase_7d, false) AS purchase_7d,
    coalesce(m.purchase_24h, false) AS purchase_24h,
    coalesce(m.purchase_including_t0, false) AS purchase_including_t0,
    coalesce(m.purchase_equal_t0, false) AS purchase_equal_t0,
    coalesce(m.purchase_same_session, false) AS purchase_same_session,
    coalesce(m.purchase_other_session, false) AS purchase_other_session,
    coalesce(m.purchase_unknown_session, false) AS purchase_unknown_session,
    coalesce(m.purchase_in_november, false) AS purchase_in_november,
    m.first_purchase_utc,
    coalesce(m.removed, false) AS removed,
    op.uid IS NOT NULL AS purchase_other_product
FROM cohort c
JOIN matching_product m USING (uid, pid)
LEFT JOIN other_product op USING (uid, pid);

CREATE TEMP VIEW cohort_info AS
SELECT count(*) AS cohort_pairs, min(t0) AS first_t0_utc, max(t0) AS last_t0_utc,
    count(DISTINCT uid) AS users, count(DISTINCT t0::DATE) AS dates_included,
    count_if(eligible_cart_count > 1) AS pairs_with_repeated_cart,
    count_if(cart_at_same_second > 1) AS pairs_with_initial_cart_tie,
    count_if(sid IS NULL) AS pairs_missing_cart_session,
    count_if(cid IS NULL) AS pairs_unknown_category_id,
    count_if(code IS NULL) AS pairs_unknown_category_code,
    count_if(observed_price IS NULL) AS pairs_unknown_price,
    count_if(observed_price = 0) AS pairs_zero_price,
    count_if(t0 + INTERVAL 7 DAY >= TIMESTAMP '2019-11-01') AS pairs_with_november_window,
    count_if(purchase_in_november) AS pairs_with_november_purchase,
    count_if(first_purchase_utc >= TIMESTAMP '2019-11-01') AS pairs_first_purchase_in_november
FROM pair_flags;

CREATE TEMP VIEW metrics AS
WITH counts AS (
    SELECT count(*) AS pairs,
        count_if(purchase_7d) AS purchase_7d,
        count_if(purchase_24h) AS purchase_24h,
        count_if(purchase_including_t0) AS purchase_including_t0,
        count_if(purchase_equal_t0) AS purchase_equal_t0,
        count_if(purchase_same_session) AS purchase_same_session,
        count_if(purchase_other_session) AS purchase_other_session,
        count_if(sid IS NOT NULL AND purchase_unknown_session) AS purchase_unknown_session,
        count_if(purchase_other_product) AS purchase_other_product,
        count_if(removed) AS removed,
        count_if(sid IS NOT NULL) AS known_start_session,
        count_if(sid IS NULL AND purchase_7d) AS purchase_unknown_start_session
    FROM pair_flags
)
SELECT metric, num AS numerator, denom AS denominator, num::DOUBLE / nullif(denom, 0) AS rate
FROM counts,
LATERAL (VALUES
    (1, 'purchase_7d', purchase_7d, pairs),
    (2, 'purchase_24h', purchase_24h, pairs),
    (3, 'purchase_7d_including_t0', purchase_including_t0, pairs),
    (4, 'purchase_equal_t0', purchase_equal_t0, pairs),
    (5, 'purchase_same_session', purchase_same_session, known_start_session),
    (6, 'purchase_other_session', purchase_other_session, known_start_session),
    (7, 'purchase_unknown_event_session', purchase_unknown_session, known_start_session),
    (8, 'purchase_other_product', purchase_other_product, pairs),
    (9, 'remove_same_product', removed, pairs),
    (10, 'purchase_unknown_start_session', purchase_unknown_start_session, pairs - known_start_session)
) AS m(ord, metric, num, denom)
ORDER BY ord;

CREATE TEMP VIEW intersections AS
WITH flags AS (
    SELECT list_value(purchase_7d, purchase_same_session, purchase_other_session,
        purchase_other_product, removed, purchase_unknown_session AND sid IS NOT NULL) AS flags
    FROM pair_flags
), names AS (
    SELECT * FROM (VALUES (1, 'purchase_7d'), (2, 'purchase_same_session'), (3, 'purchase_other_session'),
        (4, 'purchase_other_product'), (5, 'remove_same_product'), (6, 'purchase_unknown_event_session'))
        AS n(id, metric)
)
SELECT a.metric AS metric_a, b.metric AS metric_b,
    count(*) FILTER (WHERE flags[a.id] AND flags[b.id]) AS pairs_both
FROM names a CROSS JOIN names b, flags
WHERE a.id <= b.id
GROUP BY a.id, b.id, a.metric, b.metric ORDER BY a.id, b.id;

CREATE TEMP VIEW categories AS
SELECT coalesce(cid::VARCHAR, '(unknown)') AS category_id,
    count(DISTINCT code) AS distinct_category_codes,
    CASE WHEN count(DISTINCT code) = 1 THEN min(code) END AS observed_category_code,
    count_if(code IS NULL) AS missing_category_code_pairs,
    count(*) AS pairs, count_if(purchase_24h) AS purchased_24h, count_if(purchase_7d) AS purchased_7d,
    count_if(purchase_24h)::DOUBLE / count(*) AS rate_24h,
    count_if(purchase_7d)::DOUBLE / count(*) AS rate_7d
FROM pair_flags GROUP BY cid ORDER BY pairs DESC, category_id;

CREATE TEMP VIEW prices AS
WITH segments AS (
    SELECT purchase_7d, purchase_24h,
        CASE WHEN observed_price IS NULL THEN 6
            WHEN observed_price < 5 THEN 1
            WHEN observed_price < 10 THEN 2
            WHEN observed_price < 20 THEN 3
            WHEN observed_price < 40 THEN 4
            ELSE 5 END AS segment
    FROM pair_flags
), labels AS (
    SELECT * FROM (VALUES (1, '[0; 5)'), (2, '[5; 10)'), (3, '[10; 20)'),
        (4, '[20; 40)'), (5, '40+'), (6, '(unknown)')) AS l(segment, label)
)
SELECT label AS price_segment, count(segments.segment) AS pairs,
    count_if(purchase_24h IS TRUE) AS purchased_24h, count_if(purchase_7d IS TRUE) AS purchased_7d,
    count_if(purchase_24h IS TRUE)::DOUBLE / nullif(count(segments.segment), 0) AS rate_24h,
    count_if(purchase_7d IS TRUE)::DOUBLE / nullif(count(segments.segment), 0) AS rate_7d
FROM labels LEFT JOIN segments USING (segment) GROUP BY segment, label ORDER BY segment;
