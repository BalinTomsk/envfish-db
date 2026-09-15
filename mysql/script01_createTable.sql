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

    -- Cached flag: `news_photo0 IS NOT NULL`, maintained by TR_news_has_photo0_ins/upd below.
    -- Same rationale as dbo.lake.isFish (envfish-db/CLAUDE.md "Cached flags on dbo.lake") -- reading
    -- this LONGBLOB column at scale (list/home-page queries scanning every row) is catastrophically
    -- slow on the live Winhost host (confirmed 2026-08-31: a plain `news_photo0 IS NOT NULL` in any
    -- query that materializes multiple rows -- a temp table or a window function -- hangs
    -- indefinitely; a single-row lookup by primary key is unaffected). Never set this from app code
    -- or a proc; only the triggers below write it.
    has_photo0 TINYINT(1) NOT NULL DEFAULT 0,

    PRIMARY KEY (news_id),
    UNIQUE KEY id (id),
    -- news_publish is heavily skewed (the vast majority of ~4,800 rows are published), and
    -- sp_news_admin_draft_create's `DELETE FROM news WHERE news_publish <> 1` needs to seek
    -- straight to the rare unpublished rows -- without this index that DELETE is a full table
    -- scan of a BLOB-heavy table, which hangs on the live Winhost host well past any reasonable
    -- timeout (confirmed 2026-09-15; see the PRODUCTION MIGRATION block below for the guarded
    -- add-to-an-existing-database form, same idempotent pattern as has_photo0 above).
    KEY idx_news_publish (news_publish)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ============================================================================================
-- PRODUCTION MIGRATION -- news: add idx_news_publish (idempotent/guarded, for databases created
-- before this index existed; the CREATE TABLE above already has it for a fresh build). See the
-- comment on the inline KEY definition above for why this index matters.
-- ============================================================================================
SET @idx_news_publish_exists = (
    SELECT COUNT(*) FROM information_schema.statistics
    WHERE table_schema = DATABASE() AND table_name = 'news' AND index_name = 'idx_news_publish'
);
SET @sql = IF(@idx_news_publish_exists = 0,
    'CREATE INDEX idx_news_publish ON news (news_publish)',
    'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- ============================================================================================
-- PRODUCTION MIGRATION -- news: add has_photo0 (idempotent/guarded, for databases created before
-- this column existed; the CREATE TABLE above already has it for a fresh build). ALGORITHM=INSTANT
-- (MySQL 8.0.12+, InnoDB, adding a column at the end with a constant default) is metadata-only --
-- no table rebuild, no per-row blob read -- unlike a GENERATED ALWAYS AS (...) STORED column, which
-- would force ALGORITHM=COPY (a full table rebuild reading every row's blob) for the ALTER itself.
-- ============================================================================================
SET @has_photo0_exists = (
    SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema = DATABASE() AND table_name = 'news' AND column_name = 'has_photo0'
);
SET @sql = IF(@has_photo0_exists = 0,
    'ALTER TABLE news ADD COLUMN has_photo0 TINYINT(1) NOT NULL DEFAULT 0, ALGORITHM=INSTANT',
    'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

-- One-time backfill for any pre-existing rows where news_photo0 IS NOT NULL (rows without a photo
-- are already correct via the DEFAULT 0, so this only ever touches the subset that has one).
-- Deliberately NOT one unbounded UPDATE -- given how fragile this host is around news_photo0 at
-- scale, apply this by hand in small, increasing, monitored batches instead of running the file
-- straight through (see envfish-db/CLAUDE.md "Cached flags on news" for the exact batching steps):
--     UPDATE news SET has_photo0 = 1 WHERE has_photo0 = 0 AND news_photo0 IS NOT NULL LIMIT 100;
-- repeated until it affects 0 rows.

-- Maintenance triggers: keep has_photo0 correct for every future INSERT/UPDATE, one row at a time
-- (the proven-safe case -- only bulk, multi-row materialization of news_photo0 is slow on this host).
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
