-- Stored procedures for the `news` table (mysql/script01_createTable.sql).
-- Called by FishTracker.MySqlNewsHelper (fishfind-frontend/aspnet/Models/MySqlNewsHelper.cs)
-- for News.aspx - see envfish-db/CLAUDE.md "Important": app code must never hit a table
-- directly, only via a view/function/procedure.
-- Idempotent (DROP PROCEDURE IF EXISTS + CREATE), mirroring the mssql/ convention.

DELIMITER //

-- Paginated news list for the "More news" grid. Deliberately excludes the photo BLOB
-- columns - gvNews never displays them, see News.aspx's GridView markup.
DROP PROCEDURE IF EXISTS sp_news_list_for_grid //
CREATE PROCEDURE sp_news_list_for_grid(
    IN p_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_search VARCHAR(255) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_offset INT,
    IN p_page_size INT
)
BEGIN
    DECLARE v_offset INT DEFAULT IF(p_offset < 0, 0, p_offset);
    DECLARE v_page_size INT DEFAULT IF(p_page_size < 1, 1, IF(p_page_size > 500, 500, p_page_size));
    DECLARE v_like VARCHAR(257) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT CONCAT('%', p_search, '%');

    SELECT news_id, news_title AS title, news_source AS source, stamp
    FROM news
    WHERE news_publish = 1
      AND (p_country IS NULL OR country = p_country OR country IS NULL)
      AND (p_search IS NULL
           OR news_title LIKE v_like
           OR news_paragraph0 LIKE v_like
           OR news_paragraph1 LIKE v_like
           OR news_paragraph2 LIKE v_like)
    ORDER BY stamp DESC, news_id DESC
    LIMIT v_offset, v_page_size;
END //

-- Existence-only lookup for the initial lead article: the newest published article that
-- has a photo, without transferring the photo bytes just to check they exist. Kept as the
-- same two-step shape as the original C# workaround (candidate ids ordered by stamp with
-- no reference to news_photo0, then a per-row point lookup) because combining an ORDER BY
-- with a news_photo0 reference in one query has been observed to abort the connection on
-- this server - see MySqlNewsHelper.cs's GetLatestNewsIdWithPhoto comment for the history.
DROP PROCEDURE IF EXISTS sp_news_latest_id_with_photo //
CREATE PROCEDURE sp_news_latest_id_with_photo(
    IN p_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_candidate_limit INT
)
BEGIN
    DECLARE v_limit INT DEFAULT IF(p_candidate_limit < 1, 1, IF(p_candidate_limit > 200, 200, p_candidate_limit));
    DECLARE v_done INT DEFAULT 0;
    DECLARE v_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci;
    DECLARE v_has_photo TINYINT(1);
    DECLARE v_result CHAR(36) DEFAULT NULL;
    DECLARE cur CURSOR FOR
        SELECT news_id FROM news
        WHERE news_publish = 1
          AND (p_country IS NULL OR country = p_country OR country IS NULL)
        ORDER BY news_stamp DESC
        LIMIT v_limit;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_id;
        IF v_done THEN
            LEAVE read_loop;
        END IF;

        SELECT (news_photo0 IS NOT NULL) INTO v_has_photo FROM news WHERE news_id = v_id;
        IF v_has_photo THEN
            SET v_result = v_id;
            LEAVE read_loop;
        END IF;
    END LOOP;
    CLOSE cur;

    SELECT v_result AS news_id;
END //

-- Single news article's display fields, including its lead photo (news_photo0 only -
-- News.aspx never displays news_photo1/news_photo2).
DROP PROCEDURE IF EXISTS sp_news_get_by_id //
CREATE PROCEDURE sp_news_get_by_id(
    IN p_news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    SELECT news_id, news_title, news_author, news_author_link,
           news_source, news_source_link, news_stamp,
           news_paragraph0, news_paragraph1,
           news_photo0, news_photo_author0,
           country, fish1_id, fish2_id, fish3_id
    FROM news
    WHERE news_id = p_news_id AND news_publish = 1
    LIMIT 1;
END //

-- Total count of published news articles matching the grid's filters, for pagination.
DROP PROCEDURE IF EXISTS sp_news_count //
CREATE PROCEDURE sp_news_count(
    IN p_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_search VARCHAR(255) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    DECLARE v_like VARCHAR(257) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT CONCAT('%', p_search, '%');

    SELECT COUNT(*) AS total
    FROM news
    WHERE news_publish = 1
      AND (p_country IS NULL OR country = p_country OR country IS NULL)
      AND (p_search IS NULL
           OR news_title LIKE v_like
           OR news_paragraph0 LIKE v_like
           OR news_paragraph1 LIKE v_like
           OR news_paragraph2 LIKE v_like);
END //

-- ============================================================================================
-- docapi read endpoints (com.fishfind.docapi.repo.MySqlNewsDocumentRepository /
-- MySqlNewsQueryRepository, "jdbc" profile) -- GET /api/v1/news/{id}, /news/list, /news/default.
-- Only these three moved to MySQL; /news/search, /news/export/{id}, /news/import and the news
-- CRUD writes (POST/PUT) stay on the SQL Server objects (dbo.fn_news_doc / dbo.fn_news_list /
-- dbo.fn_default_news_json / dbo.fn_news_search / dbo.fn_news_json / dbo.sp_news_doc_add /
-- dbo.sp_news_doc_update / dbo.sp_news_import in envfish-db/mssql), since this MySQL database
-- has no `lake`/`fish` tables to resolve lake_name / fish names against, and no interchange or
-- full-text-search objects yet. All three return one JSON string per row (JSON_OBJECT), the same
-- convention as the SQL Server fn_news_doc / fn_default_news_json functions, so the Java layer
-- (which just parses whatever comes back) needs no per-backend special-casing. fish1_id/fish2_id/
-- fish3_id/lake_id are echoed as raw GUID strings (unresolved) for the same single-table-DB reason.
-- ============================================================================================

-- The unparameterized parts of these three procedures live in views (mysql/script01_createView.sql:
-- v_news_list_rows, the v_news_default_* chain) so mysql/UNIT_TESTS/unit_test@NewsMySQL.sql can
-- assert on the SAME query the procedures run using plain SQL -- MySQL has no way to capture a
-- stored procedure's result set from calling SQL (INSERT INTO t CALL proc() is a syntax error, and
-- there is no cursor-over-CALL support), so a result-set-returning procedure is otherwise
-- untestable via a PASS/FAIL SELECT. **A view cannot reference a session variable** (ERROR 1351),
-- so the genuinely parameterized logic -- sp_news_doc_get's id lookup and sp_news_list_json's
-- per-country CA padding -- necessarily stays inline below. See script01_createView.sql's header.

-- sp_news_doc_get : one published article as a JSON document, addressed by news_id.
-- Mirrors dbo.fn_news_doc's shape (mssql/script02_Funct.sql) minus lake_name/fishes (no lake/fish
-- tables here). NULL/absent 'doc' column ⇒ the caller (MySqlNewsDocumentRepository) reports 404,
-- same contract as fn_news_doc. Only PUBLISHED news is returned -- a public endpoint must never
-- leak a draft. Single-row lookup by primary key, so reading news_photo0 here is safe (see the
-- at-scale warning on sp_news_list_json below).
DROP PROCEDURE IF EXISTS sp_news_doc_get //
CREATE PROCEDURE sp_news_doc_get(
    IN p_news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    SELECT JSON_OBJECT(
        'news_id', news_id,
        'date', DATE_FORMAT(news_stamp, '%Y-%m-%d'),
        'country', country,
        'flag', IF(country IS NULL OR country = '', 'empty.gif', CONCAT(country, '.png')),
        'title', news_title,
        'author', news_author,
        'author_link', news_author_link,
        'source', news_source,
        'source_link', news_source_link,
        'video_link', news_video_link,
        'credit', news_photo_author0,
        'photo_alt', news_photo_alt0,
        'paragraph0', news_paragraph0,
        'paragraph1', news_paragraph1,
        'paragraph2', news_paragraph2,
        'lake_id', lake_id,
        'fish1_id', fish1_id,
        'fish2_id', fish2_id,
        'fish3_id', fish3_id,
        'photo', IF(LENGTH(news_photo0) > 100, TO_BASE64(news_photo0), NULL)
    ) AS doc
    FROM news
    WHERE news_id = p_news_id AND news_publish = 1
    LIMIT 1;
END //

-- sp_news_list_json : the paged "latest news" list, mirroring dbo.fn_news_list's contract exactly
-- (same column names/shape docapi's JdbcNewsQueryRepository/MySqlNewsQueryRepository already map),
-- including the non-CA-country-padded-with-CA-news-to-100 behaviour.
--   p_country : NULL/'' -> all countries; ISO-2 code -> that country, padded with the latest CA
--               news (block_ord = 1) when it has fewer than 100 published items of its own.
--   p_offset  : rows to skip (clamped >= 0).  p_limit : page size (clamped 1..200).
-- has_photo reads the maintained `news.has_photo0` flag column (script01_createTable.sql), NEVER
-- `news_photo0` (the LONGBLOB) or `LENGTH(news_photo0)` directly -- this is the one query here that
-- scans every published row, and on the live Winhost host ANY reference to news_photo0/1/2 in a
-- query whose plan must materialize multiple rows (a temp table, a window function) hangs
-- indefinitely, even a bare `IS NOT NULL` with no LENGTH computation (confirmed live 2026-08-31:
-- reproduced identically across an INSERT-INTO-temp-table rewrite AND a temp-table-free window-
-- function rewrite; isolated column-by-column via SHOW FULL PROCESSLIST, State=executing, no lock
-- wait -- ruling out a lock/contention explanation). A single-row lookup by primary key is
-- unaffected, which is why sp_news_doc_get and sp_news_default's final per-item join can still read
-- news_photo0 directly. See envfish-db/CLAUDE.md "Cached flags on news" for the full writeup --
-- same rationale as dbo.lake.isFish. Trade-off: has_photo0 tracks `news_photo0 IS NOT NULL`, not
-- fn_news_list's stricter ">100 byte real image" rule, so a 1-byte placeholder blob (if one exists)
-- would show has_photo=true here -- acceptable for a list view's photo *indicator* icon.
DROP PROCEDURE IF EXISTS sp_news_list_json //
CREATE PROCEDURE sp_news_list_json(
    IN p_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
    IN p_offset INT,
    IN p_limit INT
)
BEGIN
    DECLARE v_offset INT DEFAULT IF(p_offset < 0, 0, p_offset);
    DECLARE v_limit INT DEFAULT IF(p_limit < 1, 25, IF(p_limit > 200, 200, p_limit));
    DECLARE v_country VARCHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci DEFAULT NULLIF(p_country, '');
    DECLARE v_own_count INT DEFAULT 0;
    DECLARE v_pad_limit INT DEFAULT 0;

    IF v_country IS NOT NULL AND v_country <> 'CA' THEN
        SELECT COUNT(*) INTO v_own_count FROM v_news_list_rows WHERE country = v_country;
        SET v_pad_limit = GREATEST(100 - v_own_count, 0);
    END IF;

    -- Row source is v_news_list_rows (the shared per-row projection); the country filter, the CA
    -- padding block, and the rn/total window functions are applied here because they depend on the
    -- caller's parameters, which a view cannot take.
    SELECT rn, news_id, title, source, stamp, flag, has_photo, block_ord, total
    FROM (
        SELECT
            ROW_NUMBER() OVER (ORDER BY block_ord ASC, news_stamp DESC, id DESC) AS rn,
            COUNT(*) OVER () AS total,
            news_id, title, source, stamp, flag, has_photo, block_ord
        FROM (
            -- PRIMARY block: the requested country, or every country when blank.
            SELECT id, news_id, title, source, news_stamp, stamp, flag, has_photo, 0 AS block_ord
            FROM v_news_list_rows
            WHERE v_country IS NULL OR country = v_country
            UNION ALL
            -- PADDING block: latest CA news topping the list up to 100, only for a non-CA country
            -- short of 100 of its own.
            SELECT id, news_id, title, source, news_stamp, stamp, flag, has_photo, 1 AS block_ord
            FROM (
                SELECT id, news_id, title, source, news_stamp, stamp, flag, has_photo,
                       ROW_NUMBER() OVER (ORDER BY news_stamp DESC, id DESC) AS pad_rn
                FROM v_news_list_rows
                WHERE v_country IS NOT NULL AND v_country <> 'CA' AND country = 'CA'
            ) pad
            WHERE pad.pad_rn <= v_pad_limit
        ) combined
    ) ranked
    ORDER BY rn
    LIMIT v_offset, v_limit;
END //

-- sp_news_default : the assembled home page (mirrors dbo.fn_default_news_ids + dbo.fn_default_news_json
-- together, since MySQL procedures return result sets directly rather than composing via a second
-- function call). Selection algorithm matches dbo.vDefaultNews (mssql/script01_createView.sql):
--   nn=1 top 2 CA articles with a photo, nn=2 top 2 overall articles with a photo (excluding nn=1),
--   nn=3 top 3 CA (excluding above), nn=4 top 3 US (excluding above), nn=5 top 3 other countries
--   (excluding above); dedup by MIN(nn), top 5 by that order. Each group is its own VIEW (not a temp
--   table -- views have no "insert into X select ... from (subquery on X)" restriction, so unlike
--   the original implementation each group view can reference the ones before it directly).
-- Unlike fn_default_news_json's two distinct shapes (full lead doc vs compact right-column doc),
-- every item here uses ONE shape (same fields as sp_news_doc_get, no lake/fish name resolution --
-- same single-table-DB reason as sp_news_doc_get) with 'with_photo' marking the top 2 by FINAL
-- DISPLAY RANK (rn <= 2, a ROW_NUMBER() OVER (ORDER BY ord ASC, news_stamp DESC) computed after
-- dedup, in v_news_default_ranked) -- not the raw dedup group number, since groups 1 and 2 can each
-- contribute 2 rows and "group number <= 2" would wrongly mark all 4 of those as leads. Only the
-- leads carry the base64 'photo'. docapi's MySqlNewsQueryRepository.defaultNews() just parses each
-- row into the "items" array, so it doesn't care which shape a given item uses.
DROP PROCEDURE IF EXISTS sp_news_default //
CREATE PROCEDURE sp_news_default()
BEGIN
    SELECT doc FROM v_news_default_doc ORDER BY rn LIMIT 5;
END //

DELIMITER ;
