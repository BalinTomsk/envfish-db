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

DELIMITER ;
