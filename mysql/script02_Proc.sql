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

-- sp_news_doc_get : one published article as a JSON document, addressed by news_id.
-- Mirrors dbo.fn_news_doc's shape (mssql/script02_Funct.sql) minus lake_name/fishes (no lake/fish
-- tables here). NULL/absent 'doc' column ⇒ the caller (MySqlNewsDocumentRepository) reports 404,
-- same contract as fn_news_doc. Only PUBLISHED news is returned -- a public endpoint must never
-- leak a draft.
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
    DECLARE v_total INT DEFAULT 0;

    IF v_country IS NOT NULL AND v_country <> 'CA' THEN
        SELECT COUNT(*) INTO v_own_count FROM news WHERE news_publish = 1 AND country = v_country;
        SET v_pad_limit = GREATEST(100 - v_own_count, 0);
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_news_combined;
    CREATE TEMPORARY TABLE tmp_news_combined (
        id BIGINT,
        news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
        news_title VARCHAR(128) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
        news_source VARCHAR(255) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
        news_stamp DATETIME(6),
        country CHAR(2) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci,
        has_photo TINYINT(1),
        block_ord INT
    );

    -- PRIMARY block: the requested country, or every country when blank.
    INSERT INTO tmp_news_combined
    SELECT id, news_id, news_title, news_source, news_stamp, country,
           has_photo0, 0
    FROM news
    WHERE news_publish = 1 AND (v_country IS NULL OR country = v_country);

    -- PADDING block: latest CA news topping the list up to 100, only for a non-CA country short of 100.
    IF v_country IS NOT NULL AND v_country <> 'CA' AND v_pad_limit > 0 THEN
        INSERT INTO tmp_news_combined
        SELECT id, news_id, news_title, news_source, news_stamp, country,
               has_photo0, 1
        FROM news
        WHERE news_publish = 1 AND country = 'CA'
        ORDER BY news_stamp DESC, id DESC
        LIMIT v_pad_limit;
    END IF;

    SELECT COUNT(*) INTO v_total FROM tmp_news_combined;

    SELECT
        ROW_NUMBER() OVER (ORDER BY block_ord ASC, news_stamp DESC, id DESC) AS rn,
        news_id,
        news_title AS title,
        news_source AS source,
        DATE_FORMAT(news_stamp, '%Y-%m-%d') AS stamp,
        country AS flag,
        has_photo,
        block_ord,
        v_total AS total
    FROM tmp_news_combined
    ORDER BY block_ord ASC, news_stamp DESC, id DESC
    LIMIT v_offset, v_limit;

    DROP TEMPORARY TABLE IF EXISTS tmp_news_combined;
END //

-- sp_news_default : the assembled home page (mirrors dbo.fn_default_news_ids + dbo.fn_default_news_json
-- together, since MySQL procedures return result sets directly rather than composing via a second
-- function call). Selection algorithm matches dbo.vDefaultNews (mssql/script01_createView.sql):
--   nn=1 top 2 CA articles with a photo, nn=2 top 2 overall articles with a photo (excluding nn=1),
--   nn=3 top 3 CA (excluding above), nn=4 top 3 US (excluding above), nn=5 top 3 other countries
--   (excluding above); dedup by MIN(nn), top 5 by that order. Each group is its own temp table (never
--   reading the table it's inserting into) because MySQL forbids "insert into X select ... from
--   (subquery on X)" in one statement.
-- Unlike fn_default_news_json's two distinct shapes (full lead doc vs compact right-column doc),
-- every item here uses ONE shape (same fields as sp_news_doc_get, no lake/fish name resolution --
-- same single-table-DB reason as sp_news_doc_get) with 'with_photo' marking the top 2 by FINAL
-- DISPLAY RANK (rn <= 2, a ROW_NUMBER() OVER (ORDER BY ord ASC, news_stamp DESC) computed after
-- dedup) -- not the raw dedup group number, since groups 1 and 2 can each contribute 2 rows and
-- "group number <= 2" would wrongly mark all 4 of those as leads. Only the leads carry the base64
-- 'photo'. docapi's MySqlNewsQueryRepository.defaultNews() just parses each row into the "items"
-- array, so it doesn't care which shape a given item uses.
DROP PROCEDURE IF EXISTS sp_news_default //
CREATE PROCEDURE sp_news_default()
BEGIN
    DROP TEMPORARY TABLE IF EXISTS tmp_grp1;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp2;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp3;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp4;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp5;
    DROP TEMPORARY TABLE IF EXISTS tmp_default_top;

    -- Filters on has_photo0 (the maintained flag), never news_photo0 itself -- see
    -- sp_news_list_json's comment above for why a bulk news_photo0 reference hangs on this host.
    CREATE TEMPORARY TABLE tmp_grp1 (news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci);
    INSERT INTO tmp_grp1
    SELECT news_id FROM news
    WHERE news_publish = 1 AND country = 'CA' AND has_photo0 = 1
    ORDER BY news_stamp DESC LIMIT 2;

    CREATE TEMPORARY TABLE tmp_grp2 (news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci);
    INSERT INTO tmp_grp2
    SELECT news_id FROM news
    WHERE news_publish = 1 AND has_photo0 = 1
      AND news_id NOT IN (SELECT news_id FROM tmp_grp1)
    ORDER BY news_stamp DESC LIMIT 2;

    CREATE TEMPORARY TABLE tmp_grp3 (news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci);
    INSERT INTO tmp_grp3
    SELECT news_id FROM news
    WHERE news_publish = 1 AND country = 'CA'
      AND news_id NOT IN (SELECT news_id FROM tmp_grp1 UNION SELECT news_id FROM tmp_grp2)
    ORDER BY news_stamp DESC LIMIT 3;

    CREATE TEMPORARY TABLE tmp_grp4 (news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci);
    INSERT INTO tmp_grp4
    SELECT news_id FROM news
    WHERE news_publish = 1 AND country = 'US'
      AND news_id NOT IN (
          SELECT news_id FROM tmp_grp1 UNION SELECT news_id FROM tmp_grp2 UNION SELECT news_id FROM tmp_grp3)
    ORDER BY news_stamp DESC LIMIT 3;

    CREATE TEMPORARY TABLE tmp_grp5 (news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci);
    INSERT INTO tmp_grp5
    SELECT news_id FROM news
    WHERE news_publish = 1 AND country NOT IN ('US', 'CA')
      AND news_id NOT IN (
          SELECT news_id FROM tmp_grp1 UNION SELECT news_id FROM tmp_grp2
          UNION SELECT news_id FROM tmp_grp3 UNION SELECT news_id FROM tmp_grp4)
    ORDER BY news_stamp DESC LIMIT 3;

    DROP TEMPORARY TABLE IF EXISTS tmp_default_dedup;
    CREATE TEMPORARY TABLE tmp_default_dedup AS
    SELECT news_id, MIN(nn) AS ord FROM (
        SELECT news_id, 1 AS nn FROM tmp_grp1
        UNION ALL SELECT news_id, 2 FROM tmp_grp2
        UNION ALL SELECT news_id, 3 FROM tmp_grp3
        UNION ALL SELECT news_id, 4 FROM tmp_grp4
        UNION ALL SELECT news_id, 5 FROM tmp_grp5
    ) all_groups
    GROUP BY news_id;

    -- Final display rank: dbo.fn_default_news_ids computes a sequential ROW_NUMBER() OVER (ORDER BY
    -- ORD ASC, news_stamp DESC) here, not the raw dedup group number -- group 1 and group 2 can each
    -- contribute 2 rows, so "ord <= 2" alone would wrongly mark 4 items as leads instead of 2.
    CREATE TEMPORARY TABLE tmp_default_top AS
    SELECT d.news_id, d.ord,
           ROW_NUMBER() OVER (ORDER BY d.ord ASC, n.news_stamp DESC) AS rn
    FROM tmp_default_dedup d
    JOIN news n ON n.news_id = d.news_id
    ORDER BY d.ord ASC, n.news_stamp DESC
    LIMIT 5;

    SELECT JSON_OBJECT(
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
        'photo', IF(t.rn <= 2 AND LENGTH(n.news_photo0) > 100, TO_BASE64(n.news_photo0), NULL),
        'with_photo', IF(t.rn <= 2, TRUE, FALSE)
    ) AS doc
    FROM tmp_default_top t
    JOIN news n ON n.news_id = t.news_id
    ORDER BY t.rn ASC;

    DROP TEMPORARY TABLE IF EXISTS tmp_grp1;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp2;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp3;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp4;
    DROP TEMPORARY TABLE IF EXISTS tmp_grp5;
    DROP TEMPORARY TABLE IF EXISTS tmp_default_dedup;
    DROP TEMPORARY TABLE IF EXISTS tmp_default_top;
END //

DELIMITER ;
