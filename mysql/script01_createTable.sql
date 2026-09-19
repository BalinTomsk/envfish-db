CREATE TABLE news (
    news_id CHAR(36) NOT NULL,

    news_title VARCHAR(128) NOT NULL,
    news_author VARCHAR(500) NULL,
    news_author_link VARCHAR(1024) NULL,
    news_source VARCHAR(255) NULL,
    news_source_link VARCHAR(1024) NULL,

    news_publish BOOLEAN NOT NULL DEFAULT FALSE,

    news_photo0 LONGBLOB NULL,
    news_photo_author0 VARCHAR(64) NULL,
    news_video_link VARCHAR(255) NULL,

    news_paragraph1 LONGTEXT NULL,
    news_photo1 LONGBLOB NULL,
    news_photo_author1 VARCHAR(64) NULL,

    news_paragraph2 LONGTEXT NULL,
    news_photo2 LONGBLOB NULL,
    news_photo_author2 VARCHAR(64) NULL,

    news_stamp DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    news_paragraph0 LONGTEXT NULL,

    id BIGINT NOT NULL AUTO_INCREMENT,

    stamp DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),

    lake_id CHAR(36) NULL,
    country CHAR(2) NULL,

    fish1_id CHAR(36) NULL,
    fish2_id CHAR(36) NULL,
    fish3_id CHAR(36) NULL,

    news_photo_alt0 VARCHAR(128) NULL,
    news_photo_alt1 VARCHAR(128) NULL,
    news_photo_alt2 VARCHAR(128) NULL,

    -- Derived cache of `news_photo0 IS NOT NULL`. Written ONLY by the triggers TR_news_has_photo0_ins /
    -- TR_news_has_photo0_upd below -- never by a procedure or application code. The list and home-page
    -- queries look at every row, and reading the LONGBLOB column there is prohibitively slow on the
    -- Winhost host, so they read this flag instead; a single-row read by primary key is unaffected.
    -- Same idea as dbo.lake.isFish (see envfish-db/CLAUDE.md, "Cached flags on news").
    has_photo0 TINYINT(1) NOT NULL DEFAULT 0,

    -- When an editor last changed this article; NULL = never edited, and readers use
    -- COALESCE(edit_stamp, stamp) (v_news_list_rows.last_edit). An admin's /news/list is ordered by it;
    -- everyone else's by news_stamp, the article's own date. Written explicitly by the write procedures
    -- (sp_news_admin_draft_create / _publish / _photo_update, sp_news_doc_insert / _update) -- not by a
    -- trigger and not ON UPDATE CURRENT_TIMESTAMP, so a maintenance UPDATE is never an edit. Distinct
    -- from `stamp`, which is when the row was created.
    edit_stamp DATETIME(6) NULL,

    PRIMARY KEY (news_id),
    UNIQUE KEY id (id),
    -- news_publish is heavily skewed (nearly every row is published), and
    -- sp_news_admin_draft_create's `DELETE FROM news WHERE news_publish <> 1` has to seek straight to the
    -- rare unpublished rows: without this index it is a full scan of a BLOB-heavy table.
    KEY idx_news_publish (news_publish)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Maintenance triggers: keep has_photo0 correct on every INSERT/UPDATE, one row at a time (a
-- single-row write is the case that is safe on the host; only multi-row work over news_photo0 is not).
DELIMITER //

DROP TRIGGER IF EXISTS TR_news_has_photo0_ins //
CREATE TRIGGER TR_news_has_photo0_ins BEFORE INSERT ON news
FOR EACH ROW
BEGIN
    SET NEW.has_photo0 = (NEW.news_photo0 IS NOT NULL);
END //

DROP TRIGGER IF EXISTS TR_news_has_photo0_upd //
CREATE TRIGGER TR_news_has_photo0_upd BEFORE UPDATE ON news
FOR EACH ROW
BEGIN
    SET NEW.has_photo0 = (NEW.news_photo0 IS NOT NULL);
END //

DELIMITER ;
