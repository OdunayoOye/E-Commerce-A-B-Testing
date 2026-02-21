-- ============================================================
--  A/B TEST RESULTS ANALYSIS
--  Dataset : E-Commerce A/B Testing Dataset — via Kaggle
--  Author  : Odunayo Oyeboade
--  Tools   : MS SQL Server (T-SQL) — SQL Server 2016+
--
--  Dataset link:
--  https://www.kaggle.com/datasets/zhangluyuan/ab-testing
--
--  Business Context:
--  A product team ran an A/B test on a new landing page design
--  to determine if it converts more visitors into customers
--  than the existing page. The data team must rigorously
--  validate the results before recommending a ship decision.
--
--  ── SETUP 
--
--  CREATE TABLE ab_test (
--      user_id         INT,
--      timestamp       DATETIME,
--      group_name      VARCHAR(10),   -- 'control' or 'treatment'
--      landing_page    VARCHAR(20),   -- 'old_page' or 'new_page'
--      converted       INT            -- 1 = converted, 0 = not
--  );
--
--  BULK INSERT ab_test
--  FROM 'C:\data\ab_data.csv'
--  WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',',
--        ROWTERMINATOR='\n', TABLOCK);
-- ============================================================


-- ============================================================
-- QUERY 1 — DATA QUALITY & SAMPLE VALIDATION
--
--  Business Question:
--  "Before we analyze results, is the data clean?
--   Are users correctly assigned — no cross-contamination
--   where a user appears in both groups?"
--
--  This is non-negotiable before any A/B conclusion.
--  Uses: GROUP BY + HAVING to detect misassignments
-- ============================================================

-- 1A: Overall group size and balance check
SELECT
    group_name,
    landing_page,
    COUNT(*)                                            AS total_users,
    SUM(converted)                                      AS total_conversions,
    ROUND(
        CAST(SUM(converted) AS DECIMAL(10,4))
        / NULLIF(COUNT(*), 0) * 100, 4
    )                                                   AS conversion_rate_pct
FROM  ab_test
GROUP BY group_name, landing_page
ORDER BY group_name;


-- 1B: Detect mismatched assignments (control on new_page or vice versa)
SELECT
    group_name,
    landing_page,
    COUNT(*)                                            AS mismatched_count
FROM  ab_test
WHERE (group_name = 'control'   AND landing_page = 'new_page')
   OR (group_name = 'treatment' AND landing_page = 'old_page')
GROUP BY group_name, landing_page;


-- 1C: Detect users who appear in BOTH groups (contamination)
SELECT
    user_id,
    COUNT(DISTINCT group_name)                          AS group_count,
    STRING_AGG(CAST(group_name AS NVARCHAR(MAX)), ', ') AS groups_seen
FROM  ab_test
GROUP BY user_id
HAVING COUNT(DISTINCT group_name) > 1;


-- 1D: Duplicate user detection within a single group
SELECT
    user_id,
    group_name,
    COUNT(*)                                            AS appearances
FROM  ab_test
GROUP BY user_id, group_name
HAVING COUNT(*) > 1
ORDER BY appearances DESC;


-- ============================================================
-- QUERY 2 — CLEAN DATASET CTE (USED IN ALL SUBSEQUENT QUERIES)
--
--  Remove mismatched assignments and keep only the
--  first valid record per user per group.
-- ============================================================

-- This CTE is the foundation. Inline it at the top of
-- any query below that references "clean_ab":

-- WITH clean_ab AS (
--     SELECT user_id, group_name, landing_page, converted, timestamp
--     FROM (
--         SELECT *,
--                ROW_NUMBER() OVER (
--                    PARTITION BY user_id
--                    ORDER BY timestamp ASC
--                ) AS rn
--         FROM ab_test
--         WHERE NOT (
--             (group_name = 'control'   AND landing_page = 'new_page')
--             OR
--             (group_name = 'treatment' AND landing_page = 'old_page')
--         )
--     ) deduped
--     WHERE rn = 1
-- )


-- ============================================================
-- QUERY 3 — PRIMARY METRIC: CONVERSION RATE BY GROUP
--
--  Business Question:
--  "What is the conversion rate for control vs. treatment?
--   How large is the absolute and relative lift?"
--
--  Uses: Conditional aggregation, cross-join for lift calc
-- ============================================================
WITH clean_ab AS (
    SELECT user_id, group_name, landing_page, converted, timestamp
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY user_id ORDER BY timestamp ASC
               ) AS rn
        FROM ab_test
        WHERE NOT (
            (group_name = 'control'   AND landing_page = 'new_page')
            OR
            (group_name = 'treatment' AND landing_page = 'old_page')
        )
    ) deduped
    WHERE rn = 1
),

group_metrics AS (
    SELECT
        group_name,
        COUNT(*)                                        AS sample_size,
        SUM(converted)                                  AS conversions,
        CAST(SUM(converted) AS DECIMAL(10,6))
            / NULLIF(COUNT(*), 0)                       AS conversion_rate
    FROM  clean_ab
    GROUP BY group_name
),

pivot_metrics AS (
    SELECT
        MAX(CASE WHEN group_name = 'control'
                 THEN conversion_rate END)              AS control_rate,
        MAX(CASE WHEN group_name = 'treatment'
                 THEN conversion_rate END)              AS treatment_rate,
        MAX(CASE WHEN group_name = 'control'
                 THEN sample_size END)                  AS control_n,
        MAX(CASE WHEN group_name = 'treatment'
                 THEN sample_size END)                  AS treatment_n,
        MAX(CASE WHEN group_name = 'control'
                 THEN conversions END)                  AS control_conversions,
        MAX(CASE WHEN group_name = 'treatment'
                 THEN conversions END)                  AS treatment_conversions
    FROM  group_metrics
)

SELECT
    ROUND(control_rate   * 100, 4)                      AS control_conversion_pct,
    ROUND(treatment_rate * 100, 4)                      AS treatment_conversion_pct,
    control_n,
    treatment_n,
    control_conversions,
    treatment_conversions,

    -- Absolute lift: treatment minus control
    ROUND((treatment_rate - control_rate) * 100, 4)     AS absolute_lift_pct,

    -- Relative lift: % improvement over control
    ROUND(
        (treatment_rate - control_rate)
        / NULLIF(control_rate, 0) * 100, 4
    )                                                   AS relative_lift_pct,

    -- Directional signal: is treatment beating control?
    CASE
        WHEN treatment_rate > control_rate THEN 'Treatment Winning'
        WHEN treatment_rate < control_rate THEN 'Control Winning'
        ELSE                                    'No Difference'
    END                                                 AS directional_result
FROM  pivot_metrics;


-- ============================================================
-- QUERY 4 — STATISTICAL SIGNIFICANCE: Z-TEST PROXY
--
--  Business Question:
--  "Is the conversion rate difference statistically
--   significant, or could it be due to random chance?"
--
--  Two-proportion Z-test implemented in SQL:
--  Z = (p1 - p2) / sqrt(p_pool * (1 - p_pool) * (1/n1 + 1/n2))
--  p-value approximated from Z-score buckets (95% CI = |Z| > 1.96)
--
--  Note: For production, validate with Python/R statsmodels.
--        This SQL approach provides an in-database proxy
--        for quick exploration and stakeholder communication.
-- ============================================================
WITH clean_ab AS (
    SELECT user_id, group_name, converted
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY user_id ORDER BY timestamp ASC
               ) AS rn
        FROM ab_test
        WHERE NOT (
            (group_name = 'control'   AND landing_page = 'new_page')
            OR
            (group_name = 'treatment' AND landing_page = 'old_page')
        )
    ) deduped
    WHERE rn = 1
),

group_stats AS (
    SELECT
        group_name,
        COUNT(*)                                AS n,
        SUM(converted)                          AS x,
        CAST(SUM(converted) AS DECIMAL(10,8))
            / COUNT(*)                          AS p
    FROM  clean_ab
    GROUP BY group_name
),

pivot_stats AS (
    SELECT
        MAX(CASE WHEN group_name = 'control'   THEN n END)  AS n_ctrl,
        MAX(CASE WHEN group_name = 'treatment' THEN n END)  AS n_trt,
        MAX(CASE WHEN group_name = 'control'   THEN x END)  AS x_ctrl,
        MAX(CASE WHEN group_name = 'treatment' THEN x END)  AS x_trt,
        MAX(CASE WHEN group_name = 'control'   THEN p END)  AS p_ctrl,
        MAX(CASE WHEN group_name = 'treatment' THEN p END)  AS p_trt
    FROM  group_stats
),

z_calc AS (
    SELECT
        n_ctrl, n_trt, x_ctrl, x_trt,
        p_ctrl, p_trt,

        -- Pooled proportion
        CAST(x_ctrl + x_trt AS DECIMAL(10,8))
            / (n_ctrl + n_trt)                  AS p_pool,

        -- Standard error
        SQRT(
            CAST(x_ctrl + x_trt AS DECIMAL(10,8))
            / (n_ctrl + n_trt)
            * (1.0 - CAST(x_ctrl + x_trt AS DECIMAL(10,8)) / (n_ctrl + n_trt))
            * (1.0 / n_ctrl + 1.0 / n_trt)
        )                                       AS std_error
    FROM  pivot_stats
)

SELECT
    ROUND(p_ctrl  * 100, 4)                             AS control_conversion_pct,
    ROUND(p_trt   * 100, 4)                             AS treatment_conversion_pct,
    ROUND(p_pool  * 100, 4)                             AS pooled_conversion_pct,
    ROUND(std_error, 8)                                 AS std_error,

    -- Z-score
    ROUND((p_trt - p_ctrl) / NULLIF(std_error, 0), 4)  AS z_score,

    -- Significance interpretation (|Z| vs critical values)
    CASE
        WHEN ABS((p_trt - p_ctrl) / NULLIF(std_error, 0)) >= 2.576
             THEN 'Significant at 99% confidence (p < 0.01)'
        WHEN ABS((p_trt - p_ctrl) / NULLIF(std_error, 0)) >= 1.960
             THEN 'Significant at 95% confidence (p < 0.05)'
        WHEN ABS((p_trt - p_ctrl) / NULLIF(std_error, 0)) >= 1.645
             THEN 'Significant at 90% confidence (p < 0.10)'
        ELSE      'Not statistically significant — do not ship'
    END                                                 AS significance_verdict,

    -- Minimum sample size check (rule of thumb: n * p >= 5)
    CASE
        WHEN n_ctrl * p_ctrl >= 5
         AND n_ctrl * (1 - p_ctrl) >= 5
         AND n_trt  * p_trt  >= 5
         AND n_trt  * (1 - p_trt)  >= 5
         THEN 'Sample size conditions met for Z-test'
        ELSE  'WARNING: Sample size too small for Z-test'
    END                                                 AS sample_size_check
FROM  z_calc;


-- ============================================================
-- QUERY 5 — DAILY CONVERSION TREND (NOVELTY EFFECT CHECK)
--
--  Business Question:
--  "Is the treatment effect consistent over time, or is
--   there a novelty effect where users respond more on day 1
--   and the effect fades? We should not call a winner early."
--
--  Uses: Daily aggregation, LAG() for day-over-day change
-- ============================================================
WITH clean_ab AS (
    SELECT user_id, group_name, converted,
           CAST(timestamp AS DATE) AS test_date
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY user_id ORDER BY timestamp ASC
               ) AS rn
        FROM ab_test
        WHERE NOT (
            (group_name = 'control'   AND landing_page = 'new_page')
            OR
            (group_name = 'treatment' AND landing_page = 'old_page')
        )
    ) deduped
    WHERE rn = 1
),

daily_metrics AS (
    SELECT
        test_date,
        group_name,
        COUNT(*)                                        AS daily_users,
        SUM(converted)                                  AS daily_conversions,
        ROUND(
            CAST(SUM(converted) AS DECIMAL(10,6))
            / NULLIF(COUNT(*), 0) * 100, 4
        )                                               AS daily_conversion_pct
    FROM  clean_ab
    GROUP BY test_date, group_name
)

SELECT
    test_date,
    group_name,
    daily_users,
    daily_conversions,
    daily_conversion_pct,

    -- Cumulative conversion rate up to each day (per group)
    ROUND(
        CAST(
            SUM(daily_conversions) OVER (
                PARTITION BY group_name
                ORDER BY test_date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS DECIMAL(10,6)
        )
        / NULLIF(
            SUM(daily_users) OVER (
                PARTITION BY group_name
                ORDER BY test_date
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ), 0
        ) * 100, 4
    )                                                   AS cumulative_conversion_pct,

    -- Day-over-day change in conversion rate per group
    ROUND(
        daily_conversion_pct
        - LAG(daily_conversion_pct) OVER (
            PARTITION BY group_name ORDER BY test_date
          ), 4
    )                                                   AS dod_conversion_change
FROM  daily_metrics
ORDER BY test_date, group_name;


-- ============================================================
-- QUERY 6 — SUBGROUP ANALYSIS: DO RESULTS HOLD ACROSS DAYS?
--
--  Business Question:
--  "Break the test into weekly buckets. Is the treatment
--   consistently better in every week, or only in some?
--   Inconsistency = unreliable result."
--
--  Uses: DATEPART(WEEK), conditional aggregation for pivot
-- ============================================================
WITH clean_ab AS (
    SELECT user_id, group_name, converted,
           DATEPART(WEEK, timestamp) AS test_week
           -- [MySQL]: WEEK(timestamp)
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY user_id ORDER BY timestamp ASC
               ) AS rn
        FROM ab_test
        WHERE NOT (
            (group_name = 'control'   AND landing_page = 'new_page')
            OR
            (group_name = 'treatment' AND landing_page = 'old_page')
        )
    ) deduped
    WHERE rn = 1
)

SELECT
    test_week,

    -- Control metrics
    SUM(CASE WHEN group_name = 'control'   THEN 1 ELSE 0 END)   AS control_users,
    SUM(CASE WHEN group_name = 'control'   THEN converted ELSE 0 END) AS control_conv,
    ROUND(
        CAST(SUM(CASE WHEN group_name = 'control' THEN converted ELSE 0 END)
        AS DECIMAL(10,6))
        / NULLIF(SUM(CASE WHEN group_name = 'control' THEN 1 ELSE 0 END), 0)
        * 100, 4
    )                                                           AS control_conv_pct,

    -- Treatment metrics
    SUM(CASE WHEN group_name = 'treatment' THEN 1 ELSE 0 END)   AS treatment_users,
    SUM(CASE WHEN group_name = 'treatment' THEN converted ELSE 0 END) AS treatment_conv,
    ROUND(
        CAST(SUM(CASE WHEN group_name = 'treatment' THEN converted ELSE 0 END)
        AS DECIMAL(10,6))
        / NULLIF(SUM(CASE WHEN group_name = 'treatment' THEN 1 ELSE 0 END), 0)
        * 100, 4
    )                                                           AS treatment_conv_pct,

    -- Weekly lift: is treatment winning this week?
    ROUND(
        CAST(SUM(CASE WHEN group_name = 'treatment' THEN converted ELSE 0 END)
        AS DECIMAL(10,6))
        / NULLIF(SUM(CASE WHEN group_name = 'treatment' THEN 1 ELSE 0 END), 0)
        -
        CAST(SUM(CASE WHEN group_name = 'control' THEN converted ELSE 0 END)
        AS DECIMAL(10,6))
        / NULLIF(SUM(CASE WHEN group_name = 'control' THEN 1 ELSE 0 END), 0)
        , 6
    )                                                           AS weekly_lift,

    CASE
        WHEN
            CAST(SUM(CASE WHEN group_name = 'treatment' THEN converted ELSE 0 END)
            AS DECIMAL(10,6))
            / NULLIF(SUM(CASE WHEN group_name = 'treatment' THEN 1 ELSE 0 END), 0)
            >
            CAST(SUM(CASE WHEN group_name = 'control' THEN converted ELSE 0 END)
            AS DECIMAL(10,6))
            / NULLIF(SUM(CASE WHEN group_name = 'control' THEN 1 ELSE 0 END), 0)
        THEN 'Treatment Winning'
        ELSE 'Control Winning'
    END                                                         AS weekly_winner
FROM  clean_ab
GROUP BY test_week
ORDER BY test_week;


-- ============================================================
-- QUERY 7 — PRACTICAL SIGNIFICANCE & BUSINESS IMPACT
--
--  Business Question:
--  "Even if the result is statistically significant, is
--   the lift large enough to matter? Estimate the annual
--   revenue impact of shipping the new page."
--
--  Assumptions (edit to match your business context):
--    Monthly visitors  : 1,000,000
--    Revenue per conversion: $50
-- ============================================================
WITH clean_ab AS (
    SELECT user_id, group_name, converted
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY user_id ORDER BY timestamp ASC
               ) AS rn
        FROM ab_test
        WHERE NOT (
            (group_name = 'control'   AND landing_page = 'new_page')
            OR
            (group_name = 'treatment' AND landing_page = 'old_page')
        )
    ) deduped
    WHERE rn = 1
),

group_rates AS (
    SELECT
        MAX(CASE WHEN group_name = 'control'
                 THEN CAST(SUM(converted) AS DECIMAL(10,8)) / COUNT(*) END) AS p_ctrl,
        MAX(CASE WHEN group_name = 'treatment'
                 THEN CAST(SUM(converted) AS DECIMAL(10,8)) / COUNT(*) END) AS p_trt
    FROM  clean_ab
    GROUP BY group_name
),

-- Collapse to single row
rates AS (
    SELECT
        MAX(p_ctrl) AS p_ctrl,
        MAX(p_trt)  AS p_trt
    FROM group_rates
)

SELECT
    ROUND(p_ctrl * 100, 4)                              AS control_conversion_pct,
    ROUND(p_trt  * 100, 4)                              AS treatment_conversion_pct,
    ROUND((p_trt - p_ctrl) * 100, 4)                    AS absolute_lift_pct,

    -- Business impact assumptions — edit as needed
    1000000                                             AS monthly_visitors_assumed,
    50                                                  AS revenue_per_conversion_usd,

    -- Incremental monthly conversions if treatment is shipped
    ROUND((p_trt - p_ctrl) * 1000000, 0)                AS incremental_monthly_conversions,

    -- Incremental monthly revenue
    ROUND((p_trt - p_ctrl) * 1000000 * 50, 2)           AS incremental_monthly_revenue_usd,

    -- Annualised
    ROUND((p_trt - p_ctrl) * 1000000 * 50 * 12, 2)      AS incremental_annual_revenue_usd,

    -- Ship recommendation
    CASE
        WHEN (p_trt - p_ctrl) > 0.005   THEN 'Recommend Ship — Meaningful Lift'
        WHEN (p_trt - p_ctrl) > 0.001   THEN 'Borderline — Weigh Cost vs. Benefit'
        WHEN (p_trt - p_ctrl) > 0       THEN 'Do Not Ship — Lift Too Small'
        ELSE                                  'Do Not Ship — Treatment Underperforms'
    END                                                 AS ship_recommendation
FROM  rates;


-- ============================================================
-- QUERY 8 — EXECUTIVE A/B TEST SUMMARY REPORT
--
--  One clean output for leadership / stakeholders
--  covering all key metrics in a single result set.
-- ============================================================
WITH clean_ab AS (
    SELECT user_id, group_name, converted,
           CAST(timestamp AS DATE)                  AS test_date
    FROM (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY user_id ORDER BY timestamp ASC
               ) AS rn
        FROM ab_test
        WHERE NOT (
            (group_name = 'control'   AND landing_page = 'new_page')
            OR
            (group_name = 'treatment' AND landing_page = 'old_page')
        )
    ) deduped
    WHERE rn = 1
),

summary AS (
    SELECT
        MIN(test_date)                                          AS test_start,
        MAX(test_date)                                          AS test_end,
        DATEDIFF(DAY, MIN(test_date), MAX(test_date)) + 1       AS test_duration_days,
        -- [MySQL]: DATEDIFF(MAX(test_date), MIN(test_date)) + 1

        COUNT(DISTINCT CASE WHEN group_name = 'control'
                            THEN user_id END)                   AS control_users,
        COUNT(DISTINCT CASE WHEN group_name = 'treatment'
                            THEN user_id END)                   AS treatment_users,
        SUM(CASE WHEN group_name = 'control'
                 THEN converted ELSE 0 END)                     AS control_conversions,
        SUM(CASE WHEN group_name = 'treatment'
                 THEN converted ELSE 0 END)                     AS treatment_conversions,

        CAST(SUM(CASE WHEN group_name = 'control'   THEN converted ELSE 0 END)
        AS DECIMAL(10,8))
        / NULLIF(COUNT(DISTINCT CASE WHEN group_name = 'control'
                                     THEN user_id END), 0)      AS ctrl_rate,
        CAST(SUM(CASE WHEN group_name = 'treatment' THEN converted ELSE 0 END)
        AS DECIMAL(10,8))
        / NULLIF(COUNT(DISTINCT CASE WHEN group_name = 'treatment'
                                     THEN user_id END), 0)      AS trt_rate
    FROM  clean_ab
)

SELECT
    test_start,
    test_end,
    test_duration_days,
    control_users,
    treatment_users,
    control_conversions,
    treatment_conversions,
    ROUND(ctrl_rate * 100, 4)                                   AS control_conversion_pct,
    ROUND(trt_rate  * 100, 4)                                   AS treatment_conversion_pct,
    ROUND((trt_rate - ctrl_rate) * 100, 4)                      AS absolute_lift_pct,
    ROUND((trt_rate - ctrl_rate) / NULLIF(ctrl_rate, 0) * 100, 2) AS relative_lift_pct,
    CASE
        WHEN trt_rate > ctrl_rate THEN 'Treatment page converts better'
        WHEN trt_rate < ctrl_rate THEN 'Control page converts better'
        ELSE 'No measurable difference'
    END                                                         AS summary_finding,
    'Run Query 4 for full statistical significance test'        AS next_step
FROM  summary;
