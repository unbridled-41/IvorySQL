/***************************************************************
 *
 * DBMS_LOB Package
 *
 * Oracle-compatible LOB manipulation for oracle mode.  IvorySQL models
 * clob/nclob/blob as domains over text/bytea (value semantics, no LOB
 * locators), so the package operates on LOB values directly and the
 * locator-only subprograms (OPEN/CLOSE, CREATETEMPORARY, the FILE*
 * family, CONVERTTOBLOB/CONVERTTOCLOB) have no meaningful equivalent.
 *
 * Semantics verified against Oracle 23ai Free:
 *   - positions are 1-based; SUBSTR: offset < 1 or amount < 1 -> NULL,
 *     offset > length -> NULL, amount clamped to the end of the LOB
 *   - INSTR: offset < 1 or occurrence < 1 -> NULL, no match -> 0,
 *     offset > length -> 0
 *   - COMPARE: 0 when equal over the compared range, NULL when either
 *     LOB is NULL or amount/offsets are invalid; the nonzero result is
 *     unspecified in Oracle, IvorySQL returns the first mismatch position
 *   - ERASE replaces with spaces (CLOB/NCLOB) or zero bytes (BLOB) and
 *     reports the erased amount through its IN OUT argument
 *   - COPY overwrites from dest_offset and preserves the rest of dest
 *   - TRIM raises when newlen exceeds the current length (ORA-22926)
 *
 * The package body calls pg_catalog primitives explicitly (never its own
 * member names) so that unqualified member resolution cannot recurse, and
 * casts its NUMBER position/amount parameters to int at the call sites.
 *
 ***************************************************************
*/

CREATE PACKAGE dbms_lob AS

    lobmaxsize CONSTANT NUMBER := 18446744073709551615;

    FUNCTION getlength(lob CLOB) RETURN NUMBER;
    FUNCTION getlength(lob NCLOB) RETURN NUMBER;
    FUNCTION getlength(lob BLOB) RETURN NUMBER;

    FUNCTION substr(lob CLOB, amount NUMBER DEFAULT 32767, pos NUMBER DEFAULT 1) RETURN VARCHAR2;
    FUNCTION substr(lob BLOB, amount NUMBER DEFAULT 32767, pos NUMBER DEFAULT 1) RETURN sys.raw;

    FUNCTION instr(lob CLOB, pattern CLOB, pos NUMBER DEFAULT 1, occurrence NUMBER DEFAULT 1) RETURN NUMBER;
    FUNCTION instr(lob BLOB, pattern sys.raw, pos NUMBER DEFAULT 1, occurrence NUMBER DEFAULT 1) RETURN NUMBER;

    FUNCTION compare(lob_1 CLOB, lob_2 CLOB, amount NUMBER DEFAULT 18446744073709551615,
                     pos_1 NUMBER DEFAULT 1, pos_2 NUMBER DEFAULT 1) RETURN NUMBER;
    FUNCTION compare(lob_1 BLOB, lob_2 BLOB, amount NUMBER DEFAULT 18446744073709551615,
                     pos_1 NUMBER DEFAULT 1, pos_2 NUMBER DEFAULT 1) RETURN NUMBER;

    PROCEDURE append(dest_lob IN OUT CLOB, src_lob CLOB);
    PROCEDURE append(dest_lob IN OUT BLOB, src_lob BLOB);

    PROCEDURE copy(dest_lob IN OUT CLOB, src_lob CLOB, amount NUMBER DEFAULT 18446744073709551615,
                   dest_pos NUMBER DEFAULT 1, src_pos NUMBER DEFAULT 1);
    PROCEDURE copy(dest_lob IN OUT BLOB, src_lob BLOB, amount NUMBER DEFAULT 18446744073709551615,
                   dest_pos NUMBER DEFAULT 1, src_pos NUMBER DEFAULT 1);

    PROCEDURE trim(dest_lob IN OUT CLOB, newlen NUMBER);
    PROCEDURE trim(dest_lob IN OUT BLOB, newlen NUMBER);

    PROCEDURE erase(dest_lob IN OUT CLOB, amount IN OUT NUMBER, pos NUMBER DEFAULT 1);
    PROCEDURE erase(dest_lob IN OUT BLOB, amount IN OUT NUMBER, pos NUMBER DEFAULT 1);

END;

CREATE PACKAGE BODY dbms_lob AS

    FUNCTION getlength(lob CLOB) RETURN NUMBER IS
    BEGIN
        RETURN pg_catalog.length(lob);
    END;

    FUNCTION getlength(lob NCLOB) RETURN NUMBER IS
    BEGIN
        RETURN pg_catalog.length(lob);
    END;

    FUNCTION getlength(lob BLOB) RETURN NUMBER IS
    BEGIN
        RETURN pg_catalog.octet_length(lob);
    END;

    FUNCTION substr(lob CLOB, amount NUMBER DEFAULT 32767, pos NUMBER DEFAULT 1) RETURN VARCHAR2 IS
    BEGIN
        IF lob IS NULL OR amount IS NULL OR pos IS NULL THEN
            RETURN NULL;
        END IF;
        IF pos < 1 OR amount < 1 OR pos > pg_catalog.length(lob) THEN
            RETURN NULL;
        END IF;
        RETURN pg_catalog.substr(lob, pos::int, amount::int);
    END;

    FUNCTION substr(lob BLOB, amount NUMBER DEFAULT 32767, pos NUMBER DEFAULT 1) RETURN sys.raw IS
    BEGIN
        IF lob IS NULL OR amount IS NULL OR pos IS NULL THEN
            RETURN NULL;
        END IF;
        IF pos < 1 OR amount < 1 OR pos > pg_catalog.octet_length(lob) THEN
            RETURN NULL;
        END IF;
        RETURN pg_catalog.substr(lob, pos::int, amount::int);
    END;

    FUNCTION instr(lob CLOB, pattern CLOB, pos NUMBER DEFAULT 1, occurrence NUMBER DEFAULT 1) RETURN NUMBER IS
    BEGIN
        IF lob IS NULL OR pattern IS NULL OR pos IS NULL OR occurrence IS NULL THEN
            RETURN NULL;
        END IF;
        IF pos < 1 OR occurrence < 1 THEN
            RETURN NULL;
        END IF;
        RETURN sys.instr(lob, pattern, pos::int, occurrence::int);
    END;

    FUNCTION instr(lob BLOB, pattern sys.raw, pos NUMBER DEFAULT 1, occurrence NUMBER DEFAULT 1) RETURN NUMBER IS
        v_pos int;
        v_start int;
        v_found int;
        v_matches int;
    BEGIN
        IF lob IS NULL OR pattern IS NULL OR pos IS NULL OR occurrence IS NULL THEN
            RETURN NULL;
        END IF;
        IF pos < 1 OR occurrence < 1 THEN
            RETURN NULL;
        END IF;
        v_start := pos;
        v_found := 0;
        v_matches := 0;
        FOR i IN 1..occurrence::int LOOP
            v_pos := position(pattern IN pg_catalog.substr(lob, v_start, 2147483647));
            EXIT WHEN v_pos = 0;
            v_found := v_start + v_pos - 1;
            v_start := v_found + pg_catalog.octet_length(pattern);
            v_matches := v_matches + 1;
        END LOOP;
        IF v_matches = occurrence THEN
            RETURN v_found;
        END IF;
        RETURN 0;
    END;

    FUNCTION compare(lob_1 CLOB, lob_2 CLOB, amount NUMBER DEFAULT 18446744073709551615,
                     pos_1 NUMBER DEFAULT 1, pos_2 NUMBER DEFAULT 1) RETURN NUMBER IS
        v_len1 number;
        v_len2 number;
        v_n int;
        v_c1 varchar2;
        v_c2 varchar2;
    BEGIN
        IF lob_1 IS NULL OR lob_2 IS NULL OR amount IS NULL
           OR pos_1 IS NULL OR pos_2 IS NULL THEN
            RETURN NULL;
        END IF;
        IF amount < 1 OR pos_1 < 1 OR pos_2 < 1 THEN
            RETURN NULL;
        END IF;
        v_len1 := pg_catalog.length(lob_1) - pos_1 + 1;
        v_len2 := pg_catalog.length(lob_2) - pos_2 + 1;
        v_n := least(amount, v_len1, v_len2);
        FOR i IN 1..v_n LOOP
            v_c1 := pg_catalog.substr(lob_1, (pos_1 + i - 1)::int, 1);
            v_c2 := pg_catalog.substr(lob_2, (pos_2 + i - 1)::int, 1);
            IF v_c1 IS DISTINCT FROM v_c2 THEN
                RETURN i;
            END IF;
        END LOOP;
        IF amount > v_n AND v_len1 <> v_len2 THEN
            RETURN v_n + 1;
        END IF;
        RETURN 0;
    END;

    FUNCTION compare(lob_1 BLOB, lob_2 BLOB, amount NUMBER DEFAULT 18446744073709551615,
                     pos_1 NUMBER DEFAULT 1, pos_2 NUMBER DEFAULT 1) RETURN NUMBER IS
        v_len1 number;
        v_len2 number;
        v_n int;
        v_c1 sys.raw;
        v_c2 sys.raw;
    BEGIN
        IF lob_1 IS NULL OR lob_2 IS NULL OR amount IS NULL
           OR pos_1 IS NULL OR pos_2 IS NULL THEN
            RETURN NULL;
        END IF;
        IF amount < 1 OR pos_1 < 1 OR pos_2 < 1 THEN
            RETURN NULL;
        END IF;
        v_len1 := pg_catalog.octet_length(lob_1) - pos_1 + 1;
        v_len2 := pg_catalog.octet_length(lob_2) - pos_2 + 1;
        v_n := least(amount, v_len1, v_len2);
        FOR i IN 1..v_n LOOP
            v_c1 := pg_catalog.substr(lob_1, (pos_1 + i - 1)::int, 1);
            v_c2 := pg_catalog.substr(lob_2, (pos_2 + i - 1)::int, 1);
            IF v_c1 IS DISTINCT FROM v_c2 THEN
                RETURN i;
            END IF;
        END LOOP;
        IF amount > v_n AND v_len1 <> v_len2 THEN
            RETURN v_n + 1;
        END IF;
        RETURN 0;
    END;

    PROCEDURE append(dest_lob IN OUT CLOB, src_lob CLOB) IS
    BEGIN
        IF src_lob IS NULL THEN
            RETURN;
        END IF;
        IF dest_lob IS NULL THEN
            dest_lob := src_lob;
        ELSE
            dest_lob := dest_lob || src_lob;
        END IF;
    END;

    PROCEDURE append(dest_lob IN OUT BLOB, src_lob BLOB) IS
    BEGIN
        IF src_lob IS NULL THEN
            RETURN;
        END IF;
        IF dest_lob IS NULL THEN
            dest_lob := src_lob;
        ELSE
            dest_lob := dest_lob || src_lob;
        END IF;
    END;

    PROCEDURE copy(dest_lob IN OUT CLOB, src_lob CLOB, amount NUMBER DEFAULT 18446744073709551615,
                   dest_pos NUMBER DEFAULT 1, src_pos NUMBER DEFAULT 1) IS
        v_amt int;
    BEGIN
        IF src_lob IS NULL OR amount IS NULL OR dest_pos IS NULL OR src_pos IS NULL THEN
            RETURN;
        END IF;
        IF amount < 1 OR dest_pos < 1 OR src_pos < 1 THEN
            RETURN;
        END IF;
        v_amt := least(amount, pg_catalog.length(src_lob) - src_pos + 1);
        IF dest_lob IS NULL THEN
            dest_lob := pg_catalog.substr(src_lob, src_pos::int, v_amt);
        ELSE
            dest_lob := pg_catalog.substr(dest_lob, 1, (dest_pos - 1)::int)
                        || pg_catalog.substr(src_lob, src_pos::int, v_amt)
                        || pg_catalog.substr(dest_lob, (dest_pos + v_amt)::int, 2147483647);
        END IF;
    END;

    PROCEDURE copy(dest_lob IN OUT BLOB, src_lob BLOB, amount NUMBER DEFAULT 18446744073709551615,
                   dest_pos NUMBER DEFAULT 1, src_pos NUMBER DEFAULT 1) IS
        v_amt int;
    BEGIN
        IF src_lob IS NULL OR amount IS NULL OR dest_pos IS NULL OR src_pos IS NULL THEN
            RETURN;
        END IF;
        IF amount < 1 OR dest_pos < 1 OR src_pos < 1 THEN
            RETURN;
        END IF;
        v_amt := least(amount, pg_catalog.octet_length(src_lob) - src_pos + 1);
        IF dest_lob IS NULL THEN
            dest_lob := pg_catalog.substr(src_lob, src_pos::int, v_amt);
        ELSE
            dest_lob := pg_catalog.substr(dest_lob, 1, (dest_pos - 1)::int)
                        || pg_catalog.substr(src_lob, src_pos::int, v_amt)
                        || pg_catalog.substr(dest_lob, (dest_pos + v_amt)::int, 2147483647);
        END IF;
    END;

    PROCEDURE trim(dest_lob IN OUT CLOB, newlen NUMBER) IS
    BEGIN
        IF dest_lob IS NULL OR newlen IS NULL THEN
            RETURN;
        END IF;
        IF newlen > pg_catalog.length(dest_lob) THEN
            RAISE EXCEPTION 'specified trim length is greater than current LOB value''s length';
        END IF;
        dest_lob := pg_catalog.substr(dest_lob, 1, newlen::int);
    END;

    PROCEDURE trim(dest_lob IN OUT BLOB, newlen NUMBER) IS
    BEGIN
        IF dest_lob IS NULL OR newlen IS NULL THEN
            RETURN;
        END IF;
        IF newlen > pg_catalog.octet_length(dest_lob) THEN
            RAISE EXCEPTION 'specified trim length is greater than current LOB value''s length';
        END IF;
        dest_lob := pg_catalog.substr(dest_lob, 1, newlen::int);
    END;

    PROCEDURE erase(dest_lob IN OUT CLOB, amount IN OUT NUMBER, pos NUMBER DEFAULT 1) IS
        v_erase int;
    BEGIN
        IF dest_lob IS NULL OR amount IS NULL OR pos IS NULL OR pos < 1 THEN
            amount := 0;
            RETURN;
        END IF;
        v_erase := least(amount, pg_catalog.length(dest_lob) - pos + 1);
        IF v_erase < 0 THEN
            v_erase := 0;
        END IF;
        IF v_erase > 0 THEN
            dest_lob := pg_catalog.substr(dest_lob, 1, (pos - 1)::int)
                        || pg_catalog.repeat(' ', v_erase)
                        || pg_catalog.substr(dest_lob, (pos + v_erase)::int, 2147483647);
        END IF;
        amount := v_erase;
    END;

    PROCEDURE erase(dest_lob IN OUT BLOB, amount IN OUT NUMBER, pos NUMBER DEFAULT 1) IS
        v_erase int;
    BEGIN
        IF dest_lob IS NULL OR amount IS NULL OR pos IS NULL OR pos < 1 THEN
            amount := 0;
            RETURN;
        END IF;
        v_erase := least(amount, pg_catalog.octet_length(dest_lob) - pos + 1);
        IF v_erase < 0 THEN
            v_erase := 0;
        END IF;
        IF v_erase > 0 THEN
            dest_lob := pg_catalog.substr(dest_lob, 1, (pos - 1)::int)
                        || pg_catalog.decode(pg_catalog.repeat('0', v_erase * 2), 'hex')
                        || pg_catalog.substr(dest_lob, (pos + v_erase)::int, 2147483647);
        END IF;
        amount := v_erase;
    END;

END;
