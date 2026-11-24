"""Reproduce the REES46 stage 1 aggregates and Excel dashboard."""
import argparse
import csv
import gzip
import hashlib
from pathlib import Path
import tempfile

import duckdb

HERE = Path(__file__).resolve().parent
SCHEMA = (
    "event_time", "event_type", "product_id", "category_id", "category_code",
    "brand", "price", "user_id", "user_session",
)
FILES = {
    "2019-Oct": "2019-10-01",
    "2019-Nov": "2019-11-01",
}
EXPORTS = (
    "qa_files", "event_distribution", "coverage", "exclusions", "cohort_info",
    "metrics", "intersections", "categories", "prices",
)
SOURCE = "https://data.rees46.com/datasets/cosmetics/"


def sql_string(value):
    return "'" + str(value).replace("'", "''") + "'"


def inspect_input(path, archive_name):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", newline="") as stream:
        actual = next(csv.reader(stream), None)
    if tuple(actual or ()) != SCHEMA:
        raise ValueError(f"Схема {path.name} не совпадает со схемой магазина косметики: {actual}")
    with path.open("rb") as stream:
        sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
    return path.name, SOURCE + archive_name + ".csv.gz", path.stat().st_size, sha256


def inputs(args):
    paths = [(args.october, "2019-Oct")]
    if args.november:
        paths.append((args.november, "2019-Nov"))
    return {FILES[name]: (path, inspect_input(path, name)) for path, name in paths}


def register_inputs(connection, files):
    columns = ", ".join(f"'{name}': 'VARCHAR'" for name in SCHEMA)
    selects = [
        f"""
        SELECT CAST({sql_string(month)} AS DATE) AS file_month, row_number() OVER () + 1 AS file_row, *
        FROM read_csv({sql_string(path)}, header=true, columns={{{columns}}},
            delim=',', parallel=false, strict_mode=true, auto_detect=false, nullstr='')
        """
        for month, (path, _) in files.items()
    ]
    connection.execute("CREATE TEMP TABLE raw_events AS " + " UNION ALL ".join(selects))


def extract(connection, name):
    result = connection.execute("SELECT * FROM " + name)
    return [column[0] for column in result.description], result.fetchall()


def verify(tables):
    cohort = tables["cohort_info"][1][0][0]
    if cohort == 0:
        raise ValueError("В октябре нет подходящих пар с полным окном наблюдения.")
    metrics = {row[0]: row[1:] for row in tables["metrics"][1]}
    strict, denominator, _ = metrics["purchase_7d"]
    assert denominator == cohort
    assert metrics["purchase_24h"][0] <= strict <= metrics["purchase_7d_including_t0"][0]
    for numerator, total, rate in metrics.values():
        assert 0 <= numerator <= total
        assert rate == (numerator / total if total else None)
    for name, pair_col, purchase_col in (("prices", 1, 3), ("categories", 4, 6)):
        assert sum(row[pair_col] for row in tables[name][1]) == cohort
        assert sum(row[purchase_col] for row in tables[name][1]) == strict
    exclusions = tables["exclusions"][1]
    assert exclusions[0][2] - sum(row[3] for row in exclusions) == cohort
    intersections = {(a, b): count for a, b, count in tables["intersections"][1]}
    assert intersections["purchase_7d", "purchase_same_session"] == metrics["purchase_same_session"][0]
    assert intersections["purchase_7d", "purchase_other_session"] == metrics["purchase_other_session"][0]


def write_csv(directory, tables):
    directory.mkdir(parents=True, exist_ok=True)
    for name, (header, rows) in tables.items():
        with (directory / f"{name}.csv").open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(header)
            writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--october", required=True, type=Path)
    parser.add_argument("--november", type=Path)
    parser.add_argument("--out", default=HERE / "aggregates", type=Path)
    parser.add_argument("--threads", default=2, type=int)
    parser.add_argument("--no-excel", action="store_true")
    args = parser.parse_args()

    files = inputs(args)
    print("Схема и SHA-256 входных файлов проверены.", flush=True)
    with tempfile.TemporaryDirectory(prefix="rees46-duckdb-") as scratch:
        with duckdb.connect() as connection:
            connection.execute("SET TimeZone = 'UTC'")
            connection.execute(f"SET threads = {args.threads:d}")
            connection.execute("SET memory_limit = '3GB'")
            connection.execute("SET preserve_insertion_order = true")
            connection.execute(f"SET temp_directory = {sql_string(scratch)}")
            register_inputs(connection, files)
            print("Исходные строки прочитаны. Выполняется SQL.", flush=True)
            statements = connection.extract_statements((HERE / "analyze.sql").read_text(encoding="utf-8"))
            for statement in statements:
                connection.execute(statement)
                if "CREATE TEMP TABLE" in statement.query:
                    table = statement.query.split("CREATE TEMP TABLE", 1)[1].split()[0]
                    print(f"Рассчитано: {table}", flush=True)
            tables = {name: extract(connection, name) for name in EXPORTS}

    header, rows = tables.pop("qa_files")
    passport_names = ["source_filename", "publisher_archive", "bytes", "sha256"]
    tables["data_passport"] = (header + passport_names, [
        (*row, *files[row[0].isoformat()][1]) for row in rows
    ])
    verify(tables)
    write_csv(args.out, tables)
    if not args.no_excel:
        from dashboard import build
        build(args.out.parent / "rees46_dashboard.xlsx", tables)
    print(f"Проверенные агрегаты сохранены в {args.out}")


if __name__ == "__main__":
    main()
