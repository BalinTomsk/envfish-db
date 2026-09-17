-- ============================================================================================
-- PRODUCTION SETUP -- run this in the Winhost MySQL control panel (phpMyAdmin / DB manager)
-- Database: mysql_111487_envfish
--
-- WHY THIS FILE EXISTS
-- --------------------
-- The admin "Save JSON" export on News.aspx (and the "Import from JSON" card on
-- Editor/AddNews.aspx it feeds) was the last piece of the news feature still answered by SQL
-- Server: docapi's GET /api/v1/news/export/{id} called dbo.fn_news_json, which has no MySQL
-- equivalent, so every article written since AddNews.aspx moved to this database on 2026-09-14
-- had nothing to export. sp_news_doc_export (defined in mysql/script02_Proc.sql) is the port.
-- Until it exists HERE, docapi's MySqlNewsQueryRepository.exportNews fails and the Save JSON
-- link stays hidden -- which is exactly what it does today, so applying this file can only
-- improve on the current state.
--
-- THIS FILE CANNOT BE RUN AS `portos` -- SAME BLOCKER AS ADMIN_WRITE_news_procs.sql
-- -------------------------------------------------------------------------------------------
-- The application's MySQL account (`portos`) has no CREATE ROUTINE grant, so `CREATE PROCEDURE`
-- fails with ERROR 1142 from any host. See ADMIN_WRITE_news_procs.sql's header for the full
-- grant list and the two ways out; the same two apply here, and option 1 (run it from the
-- Winhost control panel's own DB tool, which connects as the database owner) is how every
-- existing sp_news_* procedure got there.
--
-- AFTER RUNNING THIS FILE
-- -----------------------
-- `portos` already holds a blanket EXECUTE grant and a routine runs with its DEFINER's
-- privileges, so no further grant is needed -- this one only reads, which portos could do
-- anyway. Verify with a real article id (any published row will do):
--     SELECT news_id FROM news WHERE news_publish = 1 ORDER BY news_stamp DESC LIMIT 1;
--     CALL sp_news_doc_export('<that id>');   -- expect ONE row, one `doc` column, 24 keys
--     CALL sp_news_doc_export(UUID());        -- expect ZERO rows (this is docapi's 404)
-- If the first call errors with a packet-size complaint rather than returning a row, the
-- article's three photos exceed the server's max_allowed_packet -- that is a server setting,
-- not a fault in this procedure (see its comment below).
--
-- This definition is copied verbatim from mysql/script02_Proc.sql -- keep them identical, and
-- re-run this file (it is idempotent, DROP+CREATE) if that source ever changes.
-- ============================================================================================

SET NAMES utf8mb4;

DELIMITER //

-- sp_news_doc_export : one article as the interchange document behind the admin "Save JSON" export
-- (News.aspx) and "Import from JSON" (Editor/AddNews.aspx). A field-for-field port of SQL Server's
-- dbo.fn_news_json (mssql/script02_Funct.sql) -- the same 24 keys under the same camelCase names,
-- every one of them always present, null included: FOR JSON's INCLUDE_NULL_VALUES and JSON_OBJECT
-- already agree on that, so no NULL handling is needed to match. An unknown id returns no row at
-- all, which MySqlNewsQueryRepository maps to the same 404 fn_news_json's NULL scalar produced.
--
-- DELIBERATELY NOT FILTERED BY news_publish, unlike sp_news_doc_get above. fn_news_json has no such
-- filter and this is an admin-only round trip: a draft must be exportable, or the export cannot
-- reproduce the one state AddNews.aspx leaves a row in before Submit. Every other read in this file
-- is a public endpoint and must never leak a draft; this one is not reachable without the portal's
-- admin gate plus the gateway's day-key (cproxy 0.15.0 lists /news/export in CPROXY_DAYKEY_PATHS).
--
-- TO_BASE64 IS WRAPPED IN REPLACE FOR A REASON: MySQL's TO_BASE64 breaks its output with a newline
-- every 76 characters, while SQL Server's FOR JSON emits varbinary as one unbroken base64 run
-- (confirmed on mysql:8.0 2026-09-17 -- a 120-byte blob came back 162 chars with the first newline
-- at position 77, and 160 chars once stripped). Both consumers tolerate the whitespace -- .NET's
-- Convert.FromBase64String skips it and a JSON string escapes it harmlessly as \n -- but the whole
-- point of this procedure is to be indistinguishable from fn_news_json on the wire, and an extra
-- 1.3% on the largest document this database serves is worth nothing. sp_news_doc_get's bare
-- TO_BASE64 is NOT a precedent to copy here: its 'photo' is read only by .NET and is never compared
-- against a SQL Server document.
--
-- KEY ORDER DIFFERS FROM fn_news_json AND CANNOT BE MADE TO MATCH: MySQL stores a JSON object's
-- keys sorted by length then bytes, so 'date' leads and 'photoAuthor2' trails no matter how they
-- are written below. They are nevertheless written in fn_news_json's declared order, because that
-- is the order to diff against when checking this port. Nothing reads the document positionally --
-- AddNews.aspx's importer pulls every field by name (JStr(d, "authorLink") and friends) -- so this
-- is cosmetic in the downloaded .json file and nowhere else.
--
-- Single-row lookup by primary key, so reading all THREE LONGBLOB photo columns here is safe: that
-- is the one access pattern the live Winhost host does not hang on (see sp_news_list_json's warning
-- below for what happens otherwise). This is the only query in this file that touches news_photo1
-- or news_photo2; never widen it past `WHERE news_id = ? LIMIT 1`. The document it assembles is the
-- largest single response this database serves -- three base64 photos inside one JSON value -- so
-- its ceiling is the server's max_allowed_packet, not anything this procedure controls.
DROP PROCEDURE IF EXISTS sp_news_doc_export //
CREATE PROCEDURE sp_news_doc_export(
    IN p_news_id CHAR(36) CHARSET utf8mb4 COLLATE utf8mb4_unicode_ci
)
BEGIN
    SELECT JSON_OBJECT(
        'title',        news_title,
        'author',       news_author,
        'authorLink',   news_author_link,
        'source',       news_source,
        'sourceLink',   news_source_link,
        'videoLink',    news_video_link,
        'paragraph0',   news_paragraph0,
        'paragraph1',   news_paragraph1,
        'paragraph2',   news_paragraph2,
        'country',      country,
        'date',         DATE_FORMAT(news_stamp, '%Y-%m-%d'),
        'lakeId',       lake_id,
        'fish1Id',      fish1_id,
        'fish2Id',      fish2_id,
        'fish3Id',      fish3_id,
        'photo0',       REPLACE(TO_BASE64(news_photo0), '\n', ''),
        'photoAuthor0', news_photo_author0,
        'photoAlt0',    news_photo_alt0,
        'photo1',       REPLACE(TO_BASE64(news_photo1), '\n', ''),
        'photoAuthor1', news_photo_author1,
        'photoAlt1',    news_photo_alt1,
        'photo2',       REPLACE(TO_BASE64(news_photo2), '\n', ''),
        'photoAuthor2', news_photo_author2,
        'photoAlt2',    news_photo_alt2
    ) AS doc
    FROM news
    WHERE news_id = p_news_id
    LIMIT 1;
END //

DELIMITER ;
