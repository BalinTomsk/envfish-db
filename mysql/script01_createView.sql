-- Views backing docapi's news read procedures (script02_Proc.sql: sp_news_default, and the shared
-- row-source for sp_news_list_json). Extracted into views (rather than inline temp-table logic) so
-- mysql/UNIT_TESTS/unit_test@NewsMySQL.sql can assert on the SAME query the live procedures use
-- with plain SQL -- MySQL has no way to capture a stored procedure's result set from calling SQL
-- (`INSERT INTO t CALL proc()` is a syntax error; there is no cursor-over-CALL support either), so
-- without this a procedure returning a result set is untestable via a plain PASS/FAIL SELECT.
--
-- NOTE: **a MySQL view cannot reference a session variable** (`ERROR 1351: View's SELECT contains a
-- variable or parameter`), so genuinely parameterized queries -- sp_news_doc_get's single-article
-- lookup and sp_news_list_json's per-country CA-padding -- CANNOT be views and stay inline in
-- script02_Proc.sql. What lives here is everything unparameterized: the whole sp_news_default
-- pipeline, plus v_news_list_rows (the per-row projection sp_news_list_json's country/padding logic
-- selects from), so the field mapping is still defined in exactly one place and directly testable.
--
-- All views here use `has_photo0` (the maintained flag), never `news_photo0`/`news_photo1`
-- directly, for anything beyond a handful of rows -- see CLAUDE.md's "⚠️ news_photo0/.../ are
-- dangerous at scale on live Winhost" and "Cached flags on news" sections. Views composing UNION
-- ALL / GROUP BY / window functions / LIMIT are processed by MySQL's TEMPTABLE algorithm (an
-- internal materialization, functionally the same category of operation as an explicit
-- CREATE TEMPORARY TABLE) -- safe here specifically because none of them touch the BLOB columns
-- at that scale; only the tiny final per-item join in v_news_default_doc (at most 5 rows) reads
-- news_photo0 directly, matching the proven-safe single/few-row case.

DROP VIEW IF EXISTS v_news_list_rows;
DROP VIEW IF EXISTS v_news_default_doc;
DROP VIEW IF EXISTS v_news_default_ranked;
DROP VIEW IF EXISTS v_news_default_top;
DROP VIEW IF EXISTS v_news_default_grp5;
DROP VIEW IF EXISTS v_news_default_grp4;
DROP VIEW IF EXISTS v_news_default_grp3;
DROP VIEW IF EXISTS v_news_default_grp2;
DROP VIEW IF EXISTS v_news_default_grp1;

-- ============================================================================================
-- sp_news_list_json's per-row projection: every published row with its display fields, in the
-- exact shape/column names dbo.fn_news_list returns (docapi's MySqlNewsQueryRepository.list maps
-- these names directly). Deliberately does NOT filter by country or apply the CA padding --
-- those need the caller's parameter, which a view cannot take, so they stay in the procedure.
-- `block_ord`/`rn`/`total` are likewise computed there, per requested country.
-- ============================================================================================
CREATE VIEW v_news_list_rows AS
SELECT
    id,
    news_id,
    news_title AS title,
    news_source AS source,
    news_stamp,
    DATE_FORMAT(news_stamp, '%Y-%m-%d') AS stamp,
    country AS flag,
    country,
    has_photo0 AS has_photo
FROM news
WHERE news_publish = 1;

-- ============================================================================================
-- sp_news_default backing: the assembled home page. Selection algorithm matches dbo.vDefaultNews
-- (mssql/script01_createView.sql) -- see script02_Proc.sql's sp_news_default for the full
-- rationale, incl. the rn<=2 "final display rank, not raw dedup group" lead-selection fix
-- (2026-08-31 regression: the original temp-table version used the raw group number and wrongly
-- marked 4 items as leads instead of 2).
--
-- Unlike the original temp-table chain (which needed 5 SEPARATE temp tables specifically because
-- MySQL forbids "insert into X select ... from (subquery on X)"), views have no such restriction --
-- each group view can reference the ones before it directly.
-- ============================================================================================
CREATE VIEW v_news_default_grp1 AS
SELECT news_id FROM news
WHERE news_publish = 1 AND country = 'CA' AND has_photo0 = 1
ORDER BY news_stamp DESC LIMIT 2;

CREATE VIEW v_news_default_grp2 AS
SELECT news_id FROM news
WHERE news_publish = 1 AND has_photo0 = 1
  AND news_id NOT IN (SELECT news_id FROM v_news_default_grp1)
ORDER BY news_stamp DESC LIMIT 2;

CREATE VIEW v_news_default_grp3 AS
SELECT news_id FROM news
WHERE news_publish = 1 AND country = 'CA'
  AND news_id NOT IN (SELECT news_id FROM v_news_default_grp1 UNION SELECT news_id FROM v_news_default_grp2)
ORDER BY news_stamp DESC LIMIT 3;

CREATE VIEW v_news_default_grp4 AS
SELECT news_id FROM news
WHERE news_publish = 1 AND country = 'US'
  AND news_id NOT IN (
      SELECT news_id FROM v_news_default_grp1 UNION SELECT news_id FROM v_news_default_grp2
      UNION SELECT news_id FROM v_news_default_grp3)
ORDER BY news_stamp DESC LIMIT 3;

CREATE VIEW v_news_default_grp5 AS
SELECT news_id FROM news
WHERE news_publish = 1 AND country NOT IN ('US', 'CA')
  AND news_id NOT IN (
      SELECT news_id FROM v_news_default_grp1 UNION SELECT news_id FROM v_news_default_grp2
      UNION SELECT news_id FROM v_news_default_grp3 UNION SELECT news_id FROM v_news_default_grp4)
ORDER BY news_stamp DESC LIMIT 3;

CREATE VIEW v_news_default_top AS
SELECT news_id, MIN(nn) AS ord FROM (
    SELECT news_id, 1 AS nn FROM v_news_default_grp1
    UNION ALL SELECT news_id, 2 FROM v_news_default_grp2
    UNION ALL SELECT news_id, 3 FROM v_news_default_grp3
    UNION ALL SELECT news_id, 4 FROM v_news_default_grp4
    UNION ALL SELECT news_id, 5 FROM v_news_default_grp5
) all_groups
GROUP BY news_id;

CREATE VIEW v_news_default_ranked AS
SELECT d.news_id, d.ord,
       ROW_NUMBER() OVER (ORDER BY d.ord ASC, n.news_stamp DESC) AS rn
FROM v_news_default_top d
JOIN news n ON n.news_id = d.news_id;

CREATE VIEW v_news_default_doc AS
SELECT
    r.rn,
    JSON_OBJECT(
        'news_id', n.news_id,
        'date', DATE_FORMAT(n.news_stamp, '%Y-%m-%d'),
        'country', n.country,
        'flag', IF(n.country IS NULL OR n.country = '', 'empty.gif', CONCAT(n.country, '.png')),
        'title', n.news_title,
        'author', n.news_author,
        'author_link', n.news_author_link,
        'source', n.news_source,
        'source_link', n.news_source_link,
        'credit', n.news_photo_author0,
        'photo_alt', n.news_photo_alt0,
        'paragraph0', n.news_paragraph0,
        'paragraph1', n.news_paragraph1,
        'lake_id', n.lake_id,
        'fish1_id', n.fish1_id,
        'fish2_id', n.fish2_id,
        'fish3_id', n.fish3_id,
        -- The right column renders a one-line teaser, not the whole paragraph: the first line of
        -- news_paragraph0, falling back to news_paragraph1 when paragraph0 is blank. Mirrors
        -- dbo.fn_default_news_json's @with_photo = 0 shape (and _Default.LoadSmallNews, which does
        -- the same split in C#). CR is stripped first so a CRLF article does not leave a trailing
        -- \r on the snippet; a body with no newline at all yields the whole (trimmed) text.
        -- Emitted for EVERY item, not just the right column, because this is one shared shape --
        -- a lead simply ignores it in favour of paragraph0/paragraph1.
        'snippet', TRIM(SUBSTRING_INDEX(
            REPLACE(COALESCE(NULLIF(n.news_paragraph0, ''), n.news_paragraph1, ''), '\r', ''),
            '\n', 1)),
        'photo', IF(r.rn <= 2 AND LENGTH(n.news_photo0) > 100, TO_BASE64(n.news_photo0), NULL),
        'with_photo', IF(r.rn <= 2, TRUE, FALSE)
    ) AS doc
FROM v_news_default_ranked r
JOIN news n ON n.news_id = r.news_id;
