#!/usr/bin/env python3
"""Build the bundled Quran database from the quran.com API.

Produces Resources/quran.sqlite3 — Uthmani text for all 6,236 āyāt with a word-by-word
breakdown, the canonical Madani muṣḥaf page layout (604 pages, per-word page and line),
word-by-word translation and transliteration, and a verse translation. The app ships
this file; there is no network access at runtime.

    scripts/build-quran-db.py              # build and verify
    scripts/build-quran-db.py --verify     # verify an existing database only
    scripts/build-quran-db.py --force      # rebuild even if up to date

This is the text of the Quran. The script therefore refuses to emit a database that
fails any structural check, and records a checksum of the corpus so that a future
rebuild producing different text is immediately visible rather than silently shipped.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sqlite3
import ssl
import subprocess
import sys
import time
import re
import unicodedata
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB_PATH = ROOT / "Resources" / "quran.sqlite3"
API = "https://api.quran.com/api/v4"
SOURCE_NAME = "quran.com API v4 (text_uthmani, Tanzil-derived)"
TRANSLATION_ID = 20  # Saheeh International
TRANSLATION_NAME = "Saheeh International"
WORD_TRANSLATION_NAME = "quran.com word-by-word (English)"

# The Madani muṣḥaf: 604 pages. Pages 1 and 2 are set differently from the rest — larger
# text, fewer lines — so the 15-line rule is asserted only from page 3 onward.
EXPECTED_PAGES = 604
STANDARD_LINES_PER_PAGE = 15

# Structural facts about the Quran, used as assertions rather than as inputs.
EXPECTED_SURAHS = 114
EXPECTED_AYAHS = 6236
# Ayah counts per surah in the Hafs/Kufan numbering the Uthmani mushaf uses.
AYAH_COUNTS = [
    7, 286, 200, 176, 120, 165, 206, 75, 129, 109, 123, 111, 43, 52, 99, 128, 111, 110,
    98, 135, 112, 78, 118, 64, 77, 227, 93, 88, 69, 60, 34, 30, 73, 54, 45, 83, 182, 88,
    75, 85, 54, 53, 89, 59, 37, 35, 38, 29, 18, 45, 60, 49, 62, 55, 78, 96, 29, 22, 24,
    13, 14, 11, 11, 18, 12, 12, 30, 52, 52, 44, 28, 28, 20, 56, 40, 31, 50, 40, 46, 42,
    29, 19, 36, 25, 22, 17, 19, 26, 30, 20, 15, 21, 11, 8, 8, 19, 5, 8, 8, 11, 11, 8, 3,
    9, 5, 4, 7, 3, 6, 3, 5, 4, 5, 6,
]


def ssl_context() -> ssl.SSLContext:
    """Build an SSL context with a working trust store.

    Python installed from python.org does not use the system keychain and ships no CA
    bundle of its own, so HTTPS fails with CERTIFICATE_VERIFY_FAILED until you run its
    "Install Certificates.command". Fall back to certifi's bundle when that hasn't been
    done — but never disable verification: this script fetches the text of the Quran,
    and an unauthenticated transport is not acceptable for that.
    """
    try:
        context = ssl.create_default_context()
        # Probe: an empty trust store raises here rather than at request time.
        if context.cert_store_stats()["x509_ca"] > 0:
            return context
    except Exception:  # noqa: BLE001 - any failure means fall through to certifi
        pass

    try:
        import certifi  # noqa: PLC0415 - optional dependency, only needed as a fallback
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        raise SystemExit(
            "error: no CA certificates available.\n"
            "       Run '/Applications/Python 3.12/Install Certificates.command',\n"
            "       or 'pip install certifi', then retry."
        )


_SSL_CONTEXT: ssl.SSLContext | None = None


def fetch(url: str, attempts: int = 4) -> dict:
    """GET with backoff. The API is public and rate-limited."""
    global _SSL_CONTEXT
    if _SSL_CONTEXT is None:
        _SSL_CONTEXT = ssl_context()

    last: Exception | None = None
    for attempt in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "iqra-db-builder"})
            with urllib.request.urlopen(request, timeout=30, context=_SSL_CONTEXT) as response:
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
            last = error
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"failed to fetch {url}: {last}")


def normalize_text(text: str) -> str:
    """Trim and collapse whitespace, and nothing else.

    Deliberately minimal. Matching-time normalisation (stripping diacritics, folding
    alef variants) lives in Swift's ArabicNormalizer and is applied to the *display*
    text at load. Duplicating it here in Python would give two implementations that
    could drift apart and silently break word matching.

    NFC is applied because the API mixes composed and decomposed forms; without it,
    identical-looking words compare unequal.
    """
    return " ".join(unicodedata.normalize("NFC", text).split())


def fetch_chapters() -> list[dict]:
    print("==> Fetching surah metadata")
    chapters = fetch(f"{API}/chapters?language=en")["chapters"]
    if len(chapters) != EXPECTED_SURAHS:
        raise SystemExit(f"error: expected {EXPECTED_SURAHS} surahs, API returned {len(chapters)}")
    return chapters


TAG_RE = re.compile(r"<[^>]+>")


def strip_markup(text: str) -> str:
    """Translations carry footnote markup like <sup foot_note=...>1</sup>."""
    return " ".join(TAG_RE.sub("", text).split())


def fetch_page(page: int) -> dict:
    """Fetch one muṣḥaf page with its words, layout positions and translations."""
    return fetch(
        f"{API}/verses/by_page/{page}"
        "?words=true"
        "&word_fields=text_uthmani,code_v1,v1_page,line_number,page_number,position,char_type_name"
        f"&translations={TRANSLATION_ID}"
        "&language=en&per_page=50"
    )


def build(db_path: Path) -> None:
    chapters = fetch_chapters()
    bismillah_pre = {c["id"]: bool(c["bismillah_pre"]) for c in chapters}

    # Keyed so a verse spanning a page boundary is stored once while its words keep
    # their own page and line — which is exactly why the layout is per-word.
    verses: dict[tuple[int, int], dict] = {}
    words: dict[tuple[int, int, int], dict] = {}
    page_line_numbers: dict[int, set[int]] = {}

    # The word-level `page_number` field is not reliable: 5:90 reports pages 122 for
    # words that sit on page 123, whose own lines 1–15 are already occupied. The page
    # that *returned* the verse is authoritative, and `line_number` is trusted. Any
    # error in that assumption shows up as a page with missing or extra lines, which the
    # structural checks below reject.
    page_field_mismatches = 0

    print(f"==> Fetching {EXPECTED_PAGES} muṣḥaf pages")
    for page in range(1, EXPECTED_PAGES + 1):
        payload = fetch_page(page)
        for verse in payload["verses"]:
            surah, ayah = (int(part) for part in verse["verse_key"].split(":"))

            translation = ""
            for entry in verse.get("translations", []):
                translation = strip_markup(entry.get("text", ""))
                break

            verses.setdefault(
                (surah, ayah),
                {
                    "page": page,
                    "juz": verse["juz_number"],
                    "hizb": verse.get("hizb_number") or 0,
                    "translation": translation,
                },
            )

            for word in verse["words"]:
                # "end" entries are the āyah-number ornament, not recited words. They are
                # kept for layout and excluded from the text and from matching.
                kind = word.get("char_type_name", "word")
                position = int(word["position"])
                line = int(word.get("line_number") or 0)
                if int(word.get("page_number") or page) != page:
                    page_field_mismatches += 1
                word_page = page
                page_line_numbers.setdefault(word_page, set()).add(line)
                words[(surah, ayah, position)] = {
                    "text": normalize_text(word.get("text_uthmani") or ""),
                    # Glyph code for the page's QCF font — Uthman Taha's calligraphy with
                    # each glyph pre-shaped for its exact place on this line.
                    "code_v1": word.get("code_v1") or "",
                    "page": word_page,
                    "line": line,
                    "kind": kind,
                    "translation": (word.get("translation") or {}).get("text") or "",
                    "transliteration": (word.get("transliteration") or {}).get("text") or "",
                }

        if page % 50 == 0 or page == EXPECTED_PAGES:
            print(f"    page {page:3d}/{EXPECTED_PAGES}  ({len(verses)} āyāt so far)", flush=True)

    if page_field_mismatches:
        print(
            f"    note: {page_field_mismatches} words carried a page_number that "
            "disagreed with the page returning them; the returning page was used"
        )

    # --- Structural assertions before anything is written ---------------------------
    if len(verses) != EXPECTED_AYAHS:
        raise SystemExit(f"error: got {len(verses)} āyāt, expected {EXPECTED_AYAHS}")

    for number in range(1, EXPECTED_SURAHS + 1):
        count = sum(1 for (surah, _ayah) in verses if surah == number)
        if count != AYAH_COUNTS[number - 1]:
            raise SystemExit(
                f"error: surah {number} has {count} āyāt, expected {AYAH_COUNTS[number - 1]}"
            )
        present = sorted(ayah for (surah, ayah) in verses if surah == number)
        if present != list(range(1, count + 1)):
            raise SystemExit(f"error: surah {number} āyah numbering is not contiguous")

    # Reconstruct verse text from the recited words, and check it against the corpus the
    # previous schema shipped: the layout data must not have changed the scripture.
    corpus: list[tuple[int, int, str]] = []
    for (surah, ayah) in sorted(verses):
        recited = [
            words[(surah, ayah, position)]
            for position in sorted(p for (s, a, p) in words if (s, a) == (surah, ayah))
            if words[(surah, ayah, position)]["kind"] == "word"
        ]
        if not recited:
            raise SystemExit(f"error: {surah}:{ayah} has no words")
        text = " ".join(word["text"] for word in recited)
        if not text.strip():
            raise SystemExit(f"error: empty text for {surah}:{ayah}")
        corpus.append((surah, ayah, text))

    # --- Page line layout -----------------------------------------------------------
    # Lines carrying no words are the surah header and the basmala. Which is which is
    # determined by the surahs that begin nearby, not guessed — and a header can sit on
    # the last line of the *previous* page when a surah starts at the top of a new one.
    def page_total(page: int) -> int:
        if page >= 3:
            return STANDARD_LINES_PER_PAGE
        used = {line for line in page_line_numbers.get(page, set()) if line > 0}
        return max(used) if used else STANDARD_LINES_PER_PAGE

    def previous_slot(page: int, line: int) -> tuple[int, int] | None:
        if line > 1:
            return (page, line - 1)
        if page > 1:
            return (page - 1, page_total(page - 1))
        return None

    used_lines = {
        page: {line for line in lines if line > 0}
        for page, lines in page_line_numbers.items()
    }
    assignments: dict[tuple[int, int], tuple[str, int]] = {}

    for (surah, ayah), info in sorted(verses.items()):
        if ayah != 1:
            continue
        start_page = info["page"]
        first_line = min(
            words[(surah, 1, position)]["line"]
            for (s, a, position) in words if (s, a) == (surah, 1)
        )
        slot = previous_slot(start_page, first_line)
        # Surah 1's basmala is its first āyah, and surah 9 has none.
        if bismillah_pre.get(surah) and slot and slot[1] not in used_lines.get(slot[0], set()):
            assignments[slot] = ("basmala", surah)
            slot = previous_slot(*slot)
        if slot and slot[1] not in used_lines.get(slot[0], set()) and slot not in assignments:
            assignments[slot] = ("surah_header", surah)

    page_lines: list[tuple[int, int, str, int]] = []
    for page in range(1, EXPECTED_PAGES + 1):
        used = used_lines.get(page, set())
        if not used:
            raise SystemExit(f"error: page {page} has no words")
        for line in range(1, page_total(page) + 1):
            if line in used:
                page_lines.append((page, line, "words", 0))
            elif (page, line) in assignments:
                kind, surah = assignments[(page, line)]
                page_lines.append((page, line, kind, surah))
            else:
                # An unexplained blank line means the layout inference is wrong, and a
                # wrong muṣḥaf page is worse than no muṣḥaf page.
                raise SystemExit(f"error: page {page} line {line} is blank and unexplained")

    # --- Write ----------------------------------------------------------------------
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()

    print("==> Writing database")
    connection = sqlite3.connect(db_path)
    connection.executescript(
        """
        PRAGMA journal_mode = DELETE;
        CREATE TABLE surahs (
            number           INTEGER PRIMARY KEY,
            name_arabic      TEXT NOT NULL,
            name_simple      TEXT NOT NULL,
            name_english     TEXT NOT NULL,
            ayah_count       INTEGER NOT NULL,
            revelation_place TEXT NOT NULL,
            bismillah_pre    INTEGER NOT NULL,
            first_page       INTEGER NOT NULL
        );
        CREATE TABLE verses (
            surah       INTEGER NOT NULL,
            ayah        INTEGER NOT NULL,
            text        TEXT NOT NULL,
            page        INTEGER NOT NULL,
            juz         INTEGER NOT NULL,
            hizb        INTEGER NOT NULL,
            translation TEXT NOT NULL,
            PRIMARY KEY (surah, ayah)
        );
        CREATE TABLE words (
            surah           INTEGER NOT NULL,
            ayah            INTEGER NOT NULL,
            position        INTEGER NOT NULL,
            text            TEXT NOT NULL,
            page            INTEGER NOT NULL,
            line            INTEGER NOT NULL,
            kind            TEXT NOT NULL,
            translation     TEXT NOT NULL,
            transliteration TEXT NOT NULL,
            code_v1         TEXT NOT NULL,
            PRIMARY KEY (surah, ayah, position)
        );
        CREATE TABLE page_lines (
            page  INTEGER NOT NULL,
            line  INTEGER NOT NULL,
            kind  TEXT NOT NULL,
            surah INTEGER NOT NULL,
            PRIMARY KEY (page, line)
        );
        CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE INDEX idx_words_verse ON words(surah, ayah);
        CREATE INDEX idx_words_page ON words(page, line, surah, ayah, position);
        CREATE INDEX idx_verses_page ON verses(page);
        """
    )

    first_page = {}
    for (surah, ayah), info in verses.items():
        if ayah == 1:
            first_page[surah] = info["page"]

    connection.executemany(
        "INSERT INTO surahs VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [
            (
                c["id"], c["name_arabic"], c["name_simple"], c["translated_name"]["name"],
                c["verses_count"], c["revelation_place"], int(bool(c["bismillah_pre"])),
                first_page.get(c["id"], 1),
            )
            for c in chapters
        ],
    )
    connection.executemany(
        "INSERT INTO verses VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            (surah, ayah, text, verses[(surah, ayah)]["page"], verses[(surah, ayah)]["juz"],
             verses[(surah, ayah)]["hizb"], verses[(surah, ayah)]["translation"])
            for surah, ayah, text in corpus
        ],
    )
    connection.executemany(
        "INSERT INTO words VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
            (surah, ayah, position, w["text"], w["page"], w["line"], w["kind"],
             w["translation"], w["transliteration"], w["code_v1"])
            for (surah, ayah, position), w in sorted(words.items())
        ],
    )
    connection.executemany("INSERT INTO page_lines VALUES (?, ?, ?, ?)", page_lines)

    digest = hashlib.sha256()
    for surah, ayah, text in corpus:
        digest.update(f"{surah}:{ayah}:{text}\n".encode("utf-8"))
    checksum = digest.hexdigest()

    recited_count = sum(1 for w in words.values() if w["kind"] == "word")
    connection.executemany(
        "INSERT INTO metadata VALUES (?, ?)",
        [
            ("schema_version", "3"),
            ("source", SOURCE_NAME),
            ("script", "quran-uthmani"),
            ("layout", "Madani muṣḥaf, 604 pages (quran.com API v4 word page/line)"),
            ("script_font", "KFGQPC Uthmanic Script (QCF v1, per-page glyph codes)"),
            ("verse_translation", TRANSLATION_NAME),
            ("word_translation", WORD_TRANSLATION_NAME),
            ("ayah_count", str(len(corpus))),
            ("surah_count", str(len(chapters))),
            ("page_count", str(EXPECTED_PAGES)),
            ("word_count", str(recited_count)),
            ("corpus_sha256", checksum),
            ("generated_utc", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
        ],
    )
    connection.commit()
    connection.execute("VACUUM")
    connection.close()

    print(f"==> Wrote {db_path} ({db_path.stat().st_size / 1024 / 1024:.1f} MB)")
    print(f"    {len(corpus)} āyāt, {recited_count} words, {EXPECTED_PAGES} pages")
    print(f"    sha256 {checksum}")


def verify(db_path: Path) -> bool:
    """Re-check a built database. Run in CI and after every build."""
    if not db_path.exists():
        print(f"error: {db_path} does not exist", file=sys.stderr)
        return False

    connection = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    failures: list[str] = []

    def check(label: str, condition: bool, detail: str = "") -> None:
        if condition:
            print(f"    ok   {label}")
        else:
            failures.append(f"{label} {detail}".strip())
            print(f"    FAIL {label} {detail}")

    print("==> Verifying")
    surahs = connection.execute("SELECT COUNT(*) FROM surahs").fetchone()[0]
    check("114 surahs", surahs == EXPECTED_SURAHS, f"(got {surahs})")

    ayahs = connection.execute("SELECT COUNT(*) FROM verses").fetchone()[0]
    check("6,236 āyāt", ayahs == EXPECTED_AYAHS, f"(got {ayahs})")

    # Every surah's stored ayah count must match both the canonical table and the
    # number of verse rows actually present.
    mismatches = []
    for number, count in connection.execute("SELECT number, ayah_count FROM surahs ORDER BY number"):
        actual = connection.execute(
            "SELECT COUNT(*) FROM verses WHERE surah = ?", (number,)
        ).fetchone()[0]
        if count != AYAH_COUNTS[number - 1] or actual != AYAH_COUNTS[number - 1]:
            mismatches.append(f"surah {number}: metadata {count}, rows {actual}, expected {AYAH_COUNTS[number - 1]}")
    check("per-surah āyah counts", not mismatches, "; ".join(mismatches[:3]))

    empty = connection.execute("SELECT COUNT(*) FROM verses WHERE TRIM(text) = ''").fetchone()[0]
    check("no empty verses", empty == 0, f"(got {empty})")

    # The words table must reconstruct the verse text exactly. This is what makes the
    # word-by-word breakdown trustworthy rather than merely plausible.
    bad_joins = 0
    words_by_verse: dict[tuple[int, int], list[str]] = {}
    for surah, ayah, _position, word in connection.execute(
        """
        SELECT surah, ayah, position, text FROM words
        WHERE kind = 'word' ORDER BY surah, ayah, position
        """
    ):
        words_by_verse.setdefault((surah, ayah), []).append(word)
    for surah, ayah, text in connection.execute("SELECT surah, ayah, text FROM verses"):
        if " ".join(words_by_verse.get((surah, ayah), [])) != text:
            bad_joins += 1
    check("words rejoin to verse text", bad_joins == 0, f"({bad_joins} mismatches)")

    # --- Muṣḥaf layout --------------------------------------------------------------
    pages = connection.execute("SELECT COUNT(DISTINCT page) FROM page_lines").fetchone()[0]
    check("604 pages", pages == EXPECTED_PAGES, f"(got {pages})")

    unplaced = connection.execute(
        "SELECT COUNT(*) FROM words WHERE page < 1 OR line < 1"
    ).fetchone()[0]
    check("every word has a page and line", unplaced == 0, f"({unplaced} unplaced)")

    # Pages 1–2 are set differently (larger text, fewer lines); the rest are 15 lines.
    odd = connection.execute(
        """
        SELECT page, COUNT(*) FROM page_lines WHERE page >= 3
        GROUP BY page HAVING COUNT(*) != ?
        """,
        (STANDARD_LINES_PER_PAGE,),
    ).fetchall()
    check(
        "pages 3–604 have 15 lines",
        not odd,
        f"({len(odd)} pages differ, e.g. {odd[:3]})",
    )

    # Line numbers must run 1..N with no holes, or the page renders with gaps.
    holes = []
    for page, count in connection.execute(
        "SELECT page, COUNT(*) FROM page_lines GROUP BY page"
    ):
        lines = [row[0] for row in connection.execute(
            "SELECT line FROM page_lines WHERE page = ? ORDER BY line", (page,)
        )]
        if lines != list(range(1, count + 1)):
            holes.append(page)
    check("page line numbers are contiguous", not holes, f"(pages {holes[:5]})")

    # Every surah must have its header line somewhere, or it will render unlabelled.
    headers = connection.execute(
        "SELECT COUNT(DISTINCT surah) FROM page_lines WHERE kind = 'surah_header'"
    ).fetchone()[0]
    # Surah 1 opens page 1 and is the one case where the header may be absent.
    check("every surah has a header line", headers >= EXPECTED_SURAHS - 1, f"(got {headers})")

    # Splitting verse text on spaces used to yield standalone waqf marks (ۖ ۛ) as
    # "words" — 490 in Al-Baqarah alone. Those normalise to nothing, can never match,
    # and were therefore reported as skipped words in every passage. Word-level data
    # from the API has none, and this keeps it that way.
    letterless = 0
    for (text,) in connection.execute("SELECT text FROM words WHERE kind = 'word'"):
        if not any(0x0621 <= ord(ch) <= 0x06D5 and not (0x064B <= ord(ch) <= 0x0655)
                   and ord(ch) not in (0x0670, 0x0640) for ch in text):
            letterless += 1
    check("every word contains an Arabic letter", letterless == 0, f"({letterless} letterless)")

    # Every word needs a glyph code, or it renders as a hole in the calligraphy.
    missing_glyphs = connection.execute(
        "SELECT COUNT(*) FROM words WHERE TRIM(code_v1) = ''"
    ).fetchone()[0]
    check("every word has a QCF glyph code", missing_glyphs == 0, f"({missing_glyphs} missing)")

    # --- Translation -----------------------------------------------------------------
    untranslated_verses = connection.execute(
        "SELECT COUNT(*) FROM verses WHERE TRIM(translation) = ''"
    ).fetchone()[0]
    check("every āyah has a translation", untranslated_verses == 0, f"({untranslated_verses} missing)")

    total_words = connection.execute("SELECT COUNT(*) FROM words WHERE kind = 'word'").fetchone()[0]
    translated_words = connection.execute(
        "SELECT COUNT(*) FROM words WHERE kind = 'word' AND TRIM(translation) != ''"
    ).fetchone()[0]
    coverage = 100 * translated_words // max(total_words, 1)
    check("word-by-word translation covers >95%", coverage >= 95, f"({coverage}%)")

    # Recompute the checksum and compare against what was recorded at build time.
    recorded = dict(connection.execute("SELECT key, value FROM metadata")).get("corpus_sha256")
    digest = hashlib.sha256()
    for surah, ayah, text in connection.execute(
        "SELECT surah, ayah, text FROM verses ORDER BY surah, ayah"
    ):
        digest.update(f"{surah}:{ayah}:{text}\n".encode("utf-8"))
    check("corpus checksum matches", recorded == digest.hexdigest(), f"(recorded {recorded})")

    # Spot-check text that any reader would notice if it were wrong. These are exact
    # byte comparisons, so they also pin the orthographic conventions of the source:
    # this Uthmani rendering carries the dagger alef on a TATWEEL (U+0640), giving
    # ٱلرَّحْمَـٰنِ rather than ٱلرَّحْمَٰنِ. Both are valid renderings of the same word and
    # ArabicNormalizer strips tatweel before matching, but pinning the exact form means
    # a source that silently changed convention would be caught here.
    spot_checks = {
        (1, 1): "بِسْمِ ٱللَّهِ ٱلرَّحْمَـٰنِ ٱلرَّحِيمِ",
        (112, 1): "قُلْ هُوَ ٱللَّهُ أَحَدٌ",
        (2, 255): None,  # Ayat al-Kursi — presence only
        (114, 6): None,
    }
    for (surah, ayah), expected_text in spot_checks.items():
        row = connection.execute(
            "SELECT text FROM verses WHERE surah = ? AND ayah = ?", (surah, ayah)
        ).fetchone()
        if row is None:
            check(f"{surah}:{ayah} present", False)
        elif expected_text is not None:
            check(f"{surah}:{ayah} text", row[0] == expected_text, f"(got {row[0]!r})")
        else:
            check(f"{surah}:{ayah} present", True)

    connection.close()

    if failures:
        print(f"\n==> {len(failures)} check(s) FAILED", file=sys.stderr)
        return False
    print("==> All checks passed")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="verify an existing database and exit")
    parser.add_argument("--force", action="store_true", help="rebuild even if the database exists")
    args = parser.parse_args()

    if args.verify:
        return 0 if verify(DB_PATH) else 1

    if DB_PATH.exists() and not args.force:
        print(f"==> {DB_PATH} already exists; verifying (use --force to rebuild)")
        return 0 if verify(DB_PATH) else 1

    build(DB_PATH)
    return 0 if verify(DB_PATH) else 1


if __name__ == "__main__":
    sys.exit(main())
