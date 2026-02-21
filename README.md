# A/B Test Results Analysis

---

## 📌 Project Overview

This project performs a rigorous end-to-end A/B test analysis entirely in SQL — from data quality validation to statistical significance testing to business impact quantification. It demonstrates the ability to answer the most common product analytics question: *"Should we ship the new version?"*

---

## 🗂️ Dataset

| Field | Description |
|---|---|
| `user_id` | Unique visitor ID |
| `timestamp` | Time of visit |
| `group_name` | `control` (old page) or `treatment` (new page) |
| `landing_page` | `old_page` or `new_page` |
| `converted` | 1 = converted, 0 = did not convert |

---

## 📊 Analyses & Business Questions Answered

| Query | Business Question |
|---|---|
| **Q1 — Data Quality Validation** | Is the data clean? Any cross-contamination or misassignments? |
| **Q2 — Clean Dataset CTE** | Remove mismatched records, deduplicate to one row per user |
| **Q3 — Primary Conversion Metrics** | What is the conversion rate for control vs. treatment? What is the lift? |
| **Q4 — Z-Test Statistical Significance** | Is the difference statistically significant at 95% confidence? |
| **Q5 — Daily Conversion Trend** | Is there a novelty effect? Does the lift hold consistently day over day? |
| **Q6 — Weekly Subgroup Analysis** | Is treatment winning in every week of the test, or only some? |
| **Q7 — Practical Significance & Revenue Impact** | Even if significant, how much incremental annual revenue does this generate? |
| **Q8 — Executive Summary Report** | One clean table with all key metrics and a ship recommendation |

---

## 🧠 Advanced SQL Techniques Demonstrated

- **ROW_NUMBER()** for deduplication and keeping the first valid record per user
- **Two-proportion Z-test** implemented entirely in SQL using pooled proportions and standard error
- **SQRT() and ABS()** for statistical formula computation in SQL
- **Conditional aggregation** (CASE inside SUM/COUNT) for group-level pivoting
- **Cumulative window functions** for running conversion rates per group per day
- **LAG()** for day-over-day and week-over-week conversion change
- **HAVING** to filter contaminated or low-quality group assignments
- **CROSS-GROUP pivoting** using MAX(CASE WHEN ...) pattern to consolidate two groups into one row
- **STRING_AGG()** for diagnostic flagging of multi-group users

---

## 💡 Key Statistical Concepts Demonstrated

| Concept | Where Applied |
|---|---|
| Statistical significance | Query 4 — Z-score vs. 1.645 / 1.960 / 2.576 thresholds |
| Practical significance | Query 7 — Minimum detectable effect and revenue impact |
| Sample size validation | Query 4 — n × p ≥ 5 condition check |
| Novelty effect detection | Query 5 — Daily cumulative conversion trend |
| Consistency check | Query 6 — Weekly subgroup winners |
| Data contamination | Query 1C — Users appearing in both groups |

---

## ⚠️ Important Note on the SQL Z-Test

The Z-test in Query 4 is a **SQL-native approximation** — it provides correct directional results and is suitable for:
- Exploratory analysis and stakeholder communication
- Portfolio demonstration of statistical thinking

For production ship decisions, always validate with **Python (scipy.stats.proportions_ztest)** or **R (prop.test)**. The README's companion note explains this context, demonstrating analytical maturity.
